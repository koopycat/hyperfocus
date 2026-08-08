import Cocoa
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarController: MenuBarController?
    private var displayManager: DisplayManager?
    private var activeWindowTracker: ActiveWindowTracker?
    private var blurEngine: BlurEngine?
    private var onboardingWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var mouseTracker: MouseTracker?
    private var isFocusActive = false
    private var isHiddenForExclusion = false
    private var hasAttachedBlurEngine = false
    private var presentationOptionsBeforeFocus: NSApplication.PresentationOptions?
    private var displayReconfigurationGeneration: UInt = 0
    /// Coalesces the display-change rebuild. Both the system notification and
    /// the CGDisplay reconfiguration callback fire for the same physical event
    /// (and macOS may post duplicates during sleep/wake), so without this the
    /// full session teardown + rebuild ran twice per hot-plug.
    private var displayReconfigWorkItem: DispatchWorkItem?

    /// Identity of a display in the reconfiguration diff: ID plus its frame,
    /// so resolution and arrangement changes are not mistaken for no-ops.
    private static func displayTopologyKey(id: CGDirectDisplayID, frame: CGRect) -> String {
        "\(id):\(Int(frame.minX)):\(Int(frame.minY)):\(Int(frame.width)):\(Int(frame.height))"
    }

    /// Coordinates the two halves of a named-filter transition. The token
    /// discards stale fade-out completions when the user changes filters
    /// quickly; the revision comes from BlurEngine's presented frame.
    private var deepFilterTransitionToken: UInt = 0
    private var pendingFilterTransitionRevision: UInt?
    private var pendingFilterTransitionDisplays: Set<CGDirectDisplayID> = []

    private static let hasCompletedOnboardingKey = "hasCompletedOnboarding"
    private static let focusModeKey = "hyperfocusMode"
    private static let perDisplaySettingsKey = "perDisplaySettings"
    private static let deepBlurRadiusKey = DeepSettings.deepBlurRadiusKey
    private static let saturationKey = "saturation"
    private static let deepFilterIDKey = DeepSettings.filterIDKey
    private static let temporalModeKey = DeepSettings.temporalModeKey
    private static let filterOverridesKey = DeepSettings.overridesKey

    private let studioDimOpacity: CGFloat = 0.32

    private var selectedMode: HyperfocusMode {
        let rawValue = UserDefaults.standard.string(forKey: Self.focusModeKey) ?? HyperfocusMode.studio.rawValue
        return HyperfocusMode(rawValue: rawValue) ?? .studio
    }

    private var currentMode: HyperfocusMode {
        return selectedMode
    }

    private func enableFocusPresentationOptions() {
        if presentationOptionsBeforeFocus == nil {
            presentationOptionsBeforeFocus = NSApp.presentationOptions
        }
        guard let previousOptions = presentationOptionsBeforeFocus else { return }
        NSApp.presentationOptions = previousOptions.union([.hideMenuBar, .hideDock])
    }

    private func restorePresentationOptions() {
        guard let previousOptions = presentationOptionsBeforeFocus else { return }
        NSApp.presentationOptions = previousOptions
        presentationOptionsBeforeFocus = nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        menuBarController = MenuBarController()
        activeWindowTracker = ActiveWindowTracker()
        displayManager = DisplayManager()
        blurEngine = BlurEngine()
        blurEngine?.onFramePresented = { [weak self] displayID, revision in
            guard let self else { return }
            let completedTransition = self.finishDeepFilterTransition(
                displayID: displayID,
                revision: revision
            )
            // First Deep frames reveal the initially transparent overlay.
            // Stale frames during a pending filter fade remain hidden.
            if !completedTransition,
               !self.pendingFilterTransitionDisplays.contains(displayID) {
                self.displayManager?.overlay(for: displayID)?.revealDeepFrame()
            }
        }
        DeepSettings.migrateIfNeeded()

        // Window frame changes update the cutout hole on every overlay.
        activeWindowTracker?.onWindowFrameChanged = { [weak self] frame in
            guard let self, self.isFocusActive, !self.isHiddenForExclusion,
                  !self.isFrontmostApplicationExcluded else { return }
            self.mouseTracker?.windowFrame = frame
            self.applyCutout(frame)
        }
        activeWindowTracker?.onFrontmostApplicationChanged = { [weak self] _ in
            self?.updatePresentationForFrontmostApplication()
        }
        activeWindowTracker?.onWindowDragStarted = { [weak self] in
            guard let self, self.isFocusActive else { return }
            self.updateRenderingPause()
            self.cancelDeepFilterTransition(applyCurrentSettings: true)
            for overlay in self.displayManager?.allOverlays() ?? [] { overlay.hide() }
        }
        activeWindowTracker?.onWindowDragEnded = { [weak self] in
            guard let self, self.isFocusActive else { return }
            // A focus change can happen through the keyboard or while the
            // pointer is outside the window. Presentation follows focus, not
            // pointer location, so always restore the overlay after settling.
            self.updateRenderingPause()
            self.showFocusPresentation()
        }

        mouseTracker = MouseTracker()
        mouseTracker?.onMouseExitedWindow = { [weak self] in
            guard let self, self.isFocusActive else { return }
            self.updateRenderingPause()
            self.cancelDeepFilterTransition(applyCurrentSettings: true)
            for overlay in self.displayManager?.allOverlays() ?? [] { overlay.hide() }
        }
        mouseTracker?.onMouseEnteredWindow = { [weak self] in
            guard let self, self.isFocusActive, !(self.activeWindowTracker?.isDragging ?? false) else { return }
            self.updateRenderingPause()
            self.showFocusPresentation()
        }
        activeWindowTracker?.start()

        NotificationCenter.default.addObserver(
            self, selector: #selector(handleFocusToggle(_:)),
            name: .hyperfocusToggle, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleThermalThrottlingChanged(_:)),
            name: BlurEngine.thermalThrottlingChanged, object: nil
        )

        NotificationCenter.default.addObserver(
            self, selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )

        NotificationCenter.default.addObserver(
            self, selector: #selector(handleOpenSettingsNotification(_:)),
            name: .hyperfocusOpenSettings, object: nil
        )

        UserDefaults.standard.addObserver(
            self, forKeyPath: "launchAtLogin", options: .new, context: nil
        )
        UserDefaults.standard.addObserver(
            self, forKeyPath: Self.focusModeKey, options: .new, context: nil
        )
        UserDefaults.standard.addObserver(
            self, forKeyPath: "blurFPS", options: .new, context: nil
        )
        UserDefaults.standard.addObserver(
            self, forKeyPath: Self.perDisplaySettingsKey, options: .new, context: nil
        )
        UserDefaults.standard.addObserver(
            self, forKeyPath: Self.deepBlurRadiusKey, options: .new, context: nil
        )
        UserDefaults.standard.addObserver(
            self, forKeyPath: Self.saturationKey, options: .new, context: nil
        )
        UserDefaults.standard.addObserver(
            self, forKeyPath: Self.deepFilterIDKey, options: .new, context: nil
        )
        UserDefaults.standard.addObserver(
            self, forKeyPath: Self.temporalModeKey, options: .new, context: nil
        )
        UserDefaults.standard.addObserver(
            self, forKeyPath: Self.filterOverridesKey, options: .new, context: nil
        )
        updateLaunchAtLogin()

        if !UserDefaults.standard.bool(forKey: Self.hasCompletedOnboardingKey) {
            showOnboardingWindow()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        displayManager?.removeAllOverlays()
        mouseTracker?.stop()
        activeWindowTracker?.stop()
        blurEngine?.detachAll()
        restorePresentationOptions()

        NotificationCenter.default.removeObserver(self)
        UserDefaults.standard.removeObserver(self, forKeyPath: "launchAtLogin")
        UserDefaults.standard.removeObserver(self, forKeyPath: Self.focusModeKey)
        UserDefaults.standard.removeObserver(self, forKeyPath: "blurFPS")
        UserDefaults.standard.removeObserver(self, forKeyPath: Self.perDisplaySettingsKey)
        UserDefaults.standard.removeObserver(self, forKeyPath: Self.deepBlurRadiusKey)
        UserDefaults.standard.removeObserver(self, forKeyPath: Self.saturationKey)
        UserDefaults.standard.removeObserver(self, forKeyPath: Self.deepFilterIDKey)
        UserDefaults.standard.removeObserver(self, forKeyPath: Self.temporalModeKey)
        UserDefaults.standard.removeObserver(self, forKeyPath: Self.filterOverridesKey)
    }

    // MARK: - Focus Toggle

    @objc private func handleFocusToggle(_ notification: Notification) {
        guard let active = notification.userInfo?["active"] as? Bool else { return }
        // Block focus toggle until onboarding is complete
        guard UserDefaults.standard.bool(forKey: Self.hasCompletedOnboardingKey) else {
            menuBarController?.setFocusActive(false)
            return
        }
        displayReconfigurationGeneration &+= 1
        if active { activateFocus() } else { deactivateFocus() }
    }

    private func activateFocus() {
        enableFocusPresentationOptions()
        isFocusActive = true
        isHiddenForExclusion = false
        displayManager?.configureForAllScreens()
        activeWindowTracker?.startFrameTracking()
        activeWindowTracker?.refreshFrontmostWindow()

        guard !isFrontmostApplicationExcluded else {
            isHiddenForExclusion = true
            menuBarController?.setFocusActive(true)
            return
        }

        mouseTracker?.start()
        showFocusPresentation()
    }

    private func deactivateFocus() {
        cancelDeepFilterTransition()
        mouseTracker?.stop()
        isFocusActive = false
        isHiddenForExclusion = false
        activeWindowTracker?.stopFrameTracking()
        // Stop capture and rendering. Without this, Deep-mode streams keep
        // capturing and rendering into hidden windows indefinitely after the
        // user turns Hyperfocus off -- a pure GPU/energy drain.
        blurEngine?.detachAll()
        blurEngine?.setRenderingPaused(false)
        hasAttachedBlurEngine = false
        for overlay in displayManager?.allOverlays() ?? [] { overlay.hide() }
        restorePresentationOptions()
        menuBarController?.setFocusActive(false)
    }

    /// Pauses Deep-mode GPU rendering whenever no overlay is visible (window
    /// drag, pointer outside the focused window, excluded app frontmost).
    /// Derived from a single place so mismatched pause/resume pairs cannot
    /// leave rendering stuck on or off. Capture streams keep running -- they
    /// are cheap and make resume instant -- only render/present is skipped.
    private func updateRenderingPause() {
        let dragging = activeWindowTracker?.isDragging ?? false
        let mouseOutside: Bool = {
            guard let tracker = mouseTracker, tracker.windowFrame != nil else { return false }
            return !tracker.isMouseInsideWindow
        }()
        let paused = isHiddenForExclusion || dragging || mouseOutside
        blurEngine?.setRenderingPaused(paused)
    }

    private func applyCutout(_ frame: CGRect?) {
        for overlay in displayManager?.allOverlays() ?? [] { overlay.setCutout(frame) }
    }

    @objc private func screenParametersChanged() {
        // Debounce: identical rebuilds from the notification and the CG
        // callback must collapse into one. The generation guard below already
        // coalesces the rebuild, but the teardown would still run twice.
        displayReconfigWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.performDisplayReconfiguration()
        }
        displayReconfigWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    private func performDisplayReconfiguration() {
        // Full teardown + rebuild so hot-plugged displays get their own overlay
        // and stream, and removed displays stop capturing.
        guard isFocusActive else { return }

        // Only rebuild when the display topology actually changed (hot-plug,
        // resolution, arrangement). Toggling focus hides the menu bar and
        // dock, which re-fires the screen-parameters notification with an
        // unchanged display set; rebuilding the whole capture session for that
        // performed a redundant full teardown on every focus activation.
        let current = Set(NSScreen.screens.map { Self.displayTopologyKey(id: $0.displayID, frame: $0.frame) })
        let existing = Set((displayManager?.allOverlays() ?? []).map {
            Self.displayTopologyKey(id: $0.displayID, frame: $0.configuredFrame)
        })
        guard current != existing else { return }

        cancelDeepFilterTransition()
        isFocusActive = false
        hasAttachedBlurEngine = false
        activeWindowTracker?.stopFrameTracking()
        blurEngine?.detachAll()
        displayManager?.removeAllOverlays()
        displayReconfigurationGeneration &+= 1
        let generation = displayReconfigurationGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, self.displayReconfigurationGeneration == generation else { return }
            self.activateFocus()
        }
    }

    @objc private func handleThermalThrottlingChanged(_ notification: Notification) {
        guard isFocusActive, currentMode == .deep else { return }
        // Reconfigure the running streams in place; a full session restart
        // flashed the overlays and re-ran TCC checks for a one-line rate cap.
        if #available(macOS 13.0, *) {
            blurEngine?.reconfigureStreamFrameRate()
        } else {
            // macOS 12 has no in-place SCStream rate update; rebuild.
            blurEngine?.detachAll()
            hasAttachedBlurEngine = false
            deactivateFocus()
            activateFocus()
        }
    }

    // MARK: - Settings

    @discardableResult
    private func pushSettingsToEngine() -> UInt? {
        guard currentMode == .deep else { return nil }
        let settings = DeepSettings.resolve()
        return blurEngine?.updateFilter(
            filterID: settings.filterID,
            blurRadius: CGFloat(settings.blurRadius),
            parameters: settings.parameters,
            temporalMode: settings.temporalMode
        )
    }

    /// Named preset changes have a deliberate fade-through. The new renderer
    /// settings are applied only after every visible overlay reaches alpha 0;
    /// each overlay then fades in only after BlurEngine reports a presented
    /// frame carrying that exact settings revision.
    private func transitionToUpdatedDeepFilter() {
        guard hasAttachedBlurEngine else {
            _ = pushSettingsToEngine()
            return
        }

        // During a rapid second selection, the first transition has already
        // made its windows alpha 0. Reuse those target displays instead of
        // treating them as invisible and allowing the old revision to reveal.
        let targetOverlays: [(displayID: CGDirectDisplayID, overlay: OverlayWindowController)]
        if pendingFilterTransitionDisplays.isEmpty {
            targetOverlays = displayManager?.visibleOverlays() ?? []
        } else {
            targetOverlays = pendingFilterTransitionDisplays.compactMap { displayID in
                guard let overlay = displayManager?.overlay(for: displayID) else { return nil }
                return (displayID, overlay)
            }
        }

        guard !targetOverlays.isEmpty else {
            pendingFilterTransitionRevision = nil
            pendingFilterTransitionDisplays.removeAll()
            _ = pushSettingsToEngine()
            return
        }

        deepFilterTransitionToken &+= 1
        let transitionGeneration = deepFilterTransitionToken
        let displayIDs = Set(targetOverlays.map(\.displayID))
        // Register targets before fade-out starts so an old frame completion
        // cannot bring an alpha-0 overlay back while a new selection is busy.
        pendingFilterTransitionRevision = nil
        pendingFilterTransitionDisplays = displayIDs

        let fadeOutGroup = DispatchGroup()
        for (_, overlay) in targetOverlays {
            fadeOutGroup.enter()
            overlay.fadeOutForDeepFilterChange {
                fadeOutGroup.leave()
            }
        }

        fadeOutGroup.notify(queue: .main) { [weak self] in
            guard let self,
                  self.deepFilterTransitionToken == transitionGeneration,
                  self.isFocusActive,
                  self.currentMode == .deep
            else { return }

            guard let revision = self.pushSettingsToEngine() else {
                for (_, overlay) in targetOverlays {
                    overlay.fadeInAfterDeepFilterChange()
                }
                self.pendingFilterTransitionDisplays.removeAll()
                return
            }

            self.pendingFilterTransitionRevision = revision
            // A stream failure after fade-out should not leave the desktop
            // permanently transparent. This is a failsafe only; normal paths
            // fade in from `finishDeepFilterTransition` after a present.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.finishDeepFilterTransitionFailsafe(revision: revision)
            }
        }
    }

    @discardableResult
    private func finishDeepFilterTransition(displayID: CGDirectDisplayID, revision: UInt) -> Bool {
        guard pendingFilterTransitionRevision == revision,
              pendingFilterTransitionDisplays.remove(displayID) != nil
        else { return false }

        displayManager?.overlay(for: displayID)?.fadeInAfterDeepFilterChange()
        if pendingFilterTransitionDisplays.isEmpty {
            pendingFilterTransitionRevision = nil
        }
        return true
    }

    private func finishDeepFilterTransitionFailsafe(revision: UInt) {
        guard pendingFilterTransitionRevision == revision else { return }
        let unresolvedDisplays = pendingFilterTransitionDisplays
        pendingFilterTransitionDisplays.removeAll()
        pendingFilterTransitionRevision = nil
        for displayID in unresolvedDisplays {
            displayManager?.overlay(for: displayID)?.fadeInAfterDeepFilterChange()
        }
    }

    private func cancelDeepFilterTransition(applyCurrentSettings: Bool = false) {
        deepFilterTransitionToken &+= 1
        pendingFilterTransitionRevision = nil
        pendingFilterTransitionDisplays.removeAll()
        // A named selection defers its engine update until fade-out completes.
        // If focus is hidden before that point, still apply the stored choice
        // now so the next visible frame on resume uses the new filter.
        if applyCurrentSettings, isFocusActive, currentMode == .deep {
            _ = pushSettingsToEngine()
        }
    }

    private var studioDimColor: NSColor {
        guard let data = UserDefaults.standard.data(forKey: "tintColorData"),
              let color = try? NSKeyedUnarchiver.unarchivedObject(
                  ofClass: NSColor.self,
                  from: data
              )
        else {
            return NSColor.black.withAlphaComponent(studioDimOpacity)
        }
        return color.withAlphaComponent(studioDimOpacity)
    }

    private func isDisplayEffectEnabled(_ displayID: CGDirectDisplayID) -> Bool {
        let data = UserDefaults.standard.data(forKey: "perDisplaySettings") ?? Data()
        let settings = (try? JSONDecoder().decode([DisplaySetting].self, from: data)) ?? []
        return settings.first(where: { $0.id == String(displayID) })?.enabled ?? true
    }

    private var isFrontmostApplicationExcluded: Bool {
        guard let bundleIdentifier = activeWindowTracker?.currentFrontmostApp?.bundleIdentifier else {
            return false
        }
        let data = UserDefaults.standard.data(forKey: "excludedApps") ?? Data()
        let excluded = (try? JSONDecoder().decode([String].self, from: data)) ?? []
        return excluded.contains(bundleIdentifier)
    }

    private func updatePresentationForFrontmostApplication() {
        guard isFocusActive else { return }

        if isFrontmostApplicationExcluded {
            guard !isHiddenForExclusion else { return }
            isHiddenForExclusion = true
            updateRenderingPause()
            cancelDeepFilterTransition(applyCurrentSettings: true)
            for overlay in displayManager?.allOverlays() ?? [] { overlay.hide() }
            return
        }

        isHiddenForExclusion = false
        updateRenderingPause()
        // `setFrontmostWindowFrame` only emits when the rect changes. Two
        // focused windows can share the same frame, so app activation itself
        // must also restore the presentation.
        showFocusPresentation()
    }

    private func showFocusPresentation() {
        let frame = activeWindowTracker?.currentFrontmostWindowFrame
        let studioDim = studioDimColor
        let studioSaturation = DeepSettings.sanitizedSaturation(
            UserDefaults.standard.object(forKey: "saturation") as? Double ?? 0.0
        )

        let shouldAttachBlurEngine = currentMode == .deep && !hasAttachedBlurEngine
        var attachedBlurEngine = false
        if shouldAttachBlurEngine {
            pushSettingsToEngine()
        }

        for screen in NSScreen.screens {
            let displayID = screen.displayID
            guard isDisplayEffectEnabled(displayID) else {
                displayManager?.overlay(for: displayID)?.hide()
                continue
            }

            if currentMode == .deep {
                guard let overlay = displayManager?.overlay(for: displayID) else { continue }
                overlay.setCutout(frame)

                if shouldAttachBlurEngine {
                    overlay.prepareForDeep()
                    overlay.showAwaitingDeepFrame()
                    blurEngine?.attach(to: overlay, displayID: displayID)
                    attachedBlurEngine = blurEngine != nil
                } else {
                    overlay.show()
                }
            } else {
                guard let overlay = displayManager?.overlay(for: displayID) else { continue }
                overlay.setCutout(frame)
                overlay.applyDim(studioDim, saturation: CGFloat(studioSaturation))
                overlay.show()
            }
        }

        if shouldAttachBlurEngine {
            hasAttachedBlurEngine = attachedBlurEngine
        }
        menuBarController?.setFocusActive(true)
    }

    // MARK: - Settings and onboarding

    @objc private func handleOpenSettingsNotification(_ notification: Notification) {
        showSettingsWindow()
    }

    private func showSettingsWindow() {
        let window: NSWindow
        if let existingWindow = settingsWindow {
            window = existingWindow
        } else {
            let host = NSHostingController(rootView: SettingsView())
            let newWindow = NSWindow(contentViewController: host)
            newWindow.title = "Hyperfocus Settings"
            newWindow.styleMask = [.titled, .closable, .miniaturizable]
            newWindow.isReleasedWhenClosed = false
            newWindow.setFrameAutosaveName("HyperfocusSettingsWindow")
            settingsWindow = newWindow
            window = newWindow
        }

        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    private func showOnboardingWindow() {
        let onboardingView = OnboardingView { [weak self] mode in
            self?.handleOnboardingFinished(mode)
        }

        let host = NSHostingController(rootView: onboardingView)
        let window = NSWindow(contentViewController: host)
        window.title = "Welcome to Hyperfocus"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("HyperfocusOnboardingWindow")

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        self.onboardingWindow = window
    }

    private func handleOnboardingFinished(_ mode: HyperfocusMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: Self.focusModeKey)
        UserDefaults.standard.set(true, forKey: Self.hasCompletedOnboardingKey)
        if let window = onboardingWindow {
            window.orderOut(nil)
            self.onboardingWindow = nil
        }
    }

    // MARK: - Launch at Login

    private func updateLaunchAtLogin() {
        guard #available(macOS 13.0, *) else { return }

        let enabled = UserDefaults.standard.bool(forKey: "launchAtLogin")
        let service = SMAppService.mainApp

        do {
            if enabled {
                if service.status != .enabled { try service.register() }
            } else {
                if service.status == .enabled { try service.unregister() }
            }
        } catch {
            print("[Hyperfocus] Launch at login registration failed: \(error)")
        }
    }

    override func observeValue(
        forKeyPath keyPath: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        switch keyPath {
        case "launchAtLogin":
            updateLaunchAtLogin()
        case Self.focusModeKey:
            guard isFocusActive else { return }
            blurEngine?.detachAll()
            hasAttachedBlurEngine = false
            deactivateFocus()
            activateFocus()
        case "blurFPS":
            guard isFocusActive, currentMode == .deep else { return }
            if #available(macOS 13.0, *) {
                blurEngine?.reconfigureStreamFrameRate()
            } else {
                // macOS 12 has no in-place SCStream rate update; rebuild.
                blurEngine?.detachAll()
                hasAttachedBlurEngine = false
                deactivateFocus()
                activateFocus()
            }
        case Self.perDisplaySettingsKey:
            guard isFocusActive else { return }
            // Stream filters are display-specific. Rebuild the active session
            // so an enabled display gets its capture stream immediately and a
            // disabled display stops contributing frames.
            blurEngine?.detachAll()
            hasAttachedBlurEngine = false
            deactivateFocus()
            activateFocus()
        case Self.deepBlurRadiusKey:
            guard isFocusActive, currentMode == .deep else { return }
            _ = pushSettingsToEngine()
        case Self.filterOverridesKey:
            guard isFocusActive,
                  currentMode == .deep,
                  UserDefaults.standard.string(forKey: Self.deepFilterIDKey) == DeepFilter.customID
            else { return }
            _ = pushSettingsToEngine()
        case Self.saturationKey:
            guard isFocusActive, currentMode == .studio else { return }
            // Studio previously applied saturation only on the next focus
            // presentation update. Reflect its retained slider immediately.
            showFocusPresentation()
        case Self.deepFilterIDKey:
            guard isFocusActive, currentMode == .deep else { return }
            if UserDefaults.standard.string(forKey: Self.deepFilterIDKey) == DeepFilter.customID {
                _ = pushSettingsToEngine()
            } else {
                transitionToUpdatedDeepFilter()
            }
        case Self.temporalModeKey:
            guard isFocusActive, currentMode == .deep else { return }
            _ = pushSettingsToEngine()
        default:
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
        }
    }
}
