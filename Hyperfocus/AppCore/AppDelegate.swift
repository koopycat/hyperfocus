import Cocoa
import ServiceManagement
import SwiftUI

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

    private static let hasCompletedOnboardingKey = "hasCompletedOnboarding"
    private static let focusModeKey = "hyperfocusMode"
    private static let perDisplaySettingsKey = "perDisplaySettings"
    private static let blurRadiusKey = "blurRadius"
    private static let saturationKey = "saturation"

    private let studioDimOpacity: CGFloat = 0.32

    private var selectedMode: HyperfocusMode {
        let rawValue = UserDefaults.standard.string(forKey: Self.focusModeKey) ?? HyperfocusMode.studio.rawValue
        return HyperfocusMode(rawValue: rawValue) ?? .studio
    }

    private var currentMode: HyperfocusMode {
        return selectedMode
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        menuBarController = MenuBarController()
        activeWindowTracker = ActiveWindowTracker()
        displayManager = DisplayManager()
        blurEngine = BlurEngine()

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
            self, forKeyPath: Self.blurRadiusKey, options: .new, context: nil
        )
        UserDefaults.standard.addObserver(
            self, forKeyPath: Self.saturationKey, options: .new, context: nil
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

        NotificationCenter.default.removeObserver(self)
        UserDefaults.standard.removeObserver(self, forKeyPath: "launchAtLogin")
        UserDefaults.standard.removeObserver(self, forKeyPath: Self.focusModeKey)
        UserDefaults.standard.removeObserver(self, forKeyPath: "blurFPS")
        UserDefaults.standard.removeObserver(self, forKeyPath: Self.perDisplaySettingsKey)
        UserDefaults.standard.removeObserver(self, forKeyPath: Self.blurRadiusKey)
        UserDefaults.standard.removeObserver(self, forKeyPath: Self.saturationKey)
    }

    // MARK: - Focus Toggle

    @objc private func handleFocusToggle(_ notification: Notification) {
        guard let active = notification.userInfo?["active"] as? Bool else { return }
        // Block focus toggle until onboarding is complete
        guard UserDefaults.standard.bool(forKey: Self.hasCompletedOnboardingKey) else {
            menuBarController?.setFocusActive(false)
            return
        }
        if active { activateFocus() } else { deactivateFocus() }
    }

    private func activateFocus() {
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
        // Full teardown + rebuild so hot-plugged displays get their own overlay
        // and stream, and removed displays stop capturing.
        guard isFocusActive else { return }
        isFocusActive = false
        hasAttachedBlurEngine = false
        activeWindowTracker?.stopFrameTracking()
        blurEngine?.detachAll()
        displayManager?.removeAllOverlays()
        DispatchQueue.main.async { [weak self] in
            self?.activateFocus()
        }
    }

    @objc private func handleThermalThrottlingChanged(_ notification: Notification) {
        guard isFocusActive, currentMode == .deep else { return }
        // Restart the Deep-mode session so each stream starts with the new
        // effective frame rate. Mirrors the blurFPS KVO path.
        blurEngine?.detachAll()
        hasAttachedBlurEngine = false
        deactivateFocus()
        activateFocus()
    }

    // MARK: - Settings

    private func pushSettingsToEngine() {
        guard currentMode == .deep else { return }
        let blurRadius = UserDefaults.standard.object(forKey: "blurRadius") as? Double ?? 20
        let saturation = UserDefaults.standard.object(forKey: "saturation") as? Double ?? 0.0
        blurEngine?.updateSettings(blurRadius: CGFloat(blurRadius), saturation: CGFloat(saturation))
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
        let studioSaturation = UserDefaults.standard.object(forKey: "saturation") as? Double ?? 0.0

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
                    overlay.show()
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
            // SCStream has no public configuration property for in-place
            // frame-interval updates. Teardown + rebuild is the safe path.
            blurEngine?.detachAll()
            hasAttachedBlurEngine = false
            deactivateFocus()
            activateFocus()
        case Self.perDisplaySettingsKey:
            guard isFocusActive else { return }
            // Stream filters are display-specific. Rebuild the active session
            // so an enabled display gets its capture stream immediately and a
            // disabled display stops contributing frames.
            blurEngine?.detachAll()
            hasAttachedBlurEngine = false
            deactivateFocus()
            activateFocus()
        case Self.blurRadiusKey, Self.saturationKey:
            guard isFocusActive, currentMode == .deep else { return }
            pushSettingsToEngine()
        default:
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
        }
    }
}
