import Cocoa
import ServiceManagement
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarController: MenuBarController?
    private var displayManager: DisplayManager?
    private var activeWindowTracker: ActiveWindowTracker?
    private var blurEngine: BlurEngine?
    private var shakeDetector: ShakeDetector?
    private let licenseManager = LicenseManager.shared
    private var onboardingWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var isFocusActive = false
    private var isHiddenForExclusion = false
    private var hasAttachedBlurEngine = false
    private var isSynchronizingFocusMode = false

    private static let hasCompletedOnboardingKey = "hasCompletedOnboarding"
    private static let focusModeKey = "hyperfocusMode"
    private static let shakeEnabledKey = "shakeEnabled"
    private static let shakeSensitivityKey = "shakeSensitivity"

    /// A restrained dim keeps the background available as context without
    /// letting saturated app colors turn the workspace into a blue wash.
    private let studioDimOpacity: CGFloat = 0.32

    private var selectedMode: HyperfocusMode {
        let rawValue = UserDefaults.standard.string(forKey: Self.focusModeKey) ?? HyperfocusMode.studio.rawValue
        return HyperfocusMode(rawValue: rawValue) ?? .studio
    }

    private var currentMode: HyperfocusMode {
        guard selectedMode == .deep, licenseManager.isProFeatureAvailable else {
            return .studio
        }
        return .deep
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        menuBarController = MenuBarController()
        activeWindowTracker = ActiveWindowTracker()
        displayManager = DisplayManager()
        blurEngine = BlurEngine()

        // Window frame changes update the cutout hole on every overlay.
        activeWindowTracker?.onWindowFrameChanged = { [weak self] frame in
            guard let self, self.isFocusActive, !self.isHiddenForExclusion else { return }
            self.applyCutout(frame)
        }
        activeWindowTracker?.onFrontmostApplicationChanged = { [weak self] _ in
            self?.updatePresentationForFrontmostApplication()
        }
        activeWindowTracker?.start()

        // Shake-to-toggle is opt-in. The CGEvent tap needs Input Monitoring
        // permission and would prompt on every fresh ad-hoc build, so we never
        // start it automatically. The user enables it from Settings, where the
        // prompt is expected and actionable.
        shakeDetector = ShakeDetector()
        shakeDetector?.sensitivity = CGFloat(
            UserDefaults.standard.object(forKey: Self.shakeSensitivityKey) as? Double ?? 3000
        )
        shakeDetector?.onShakeDetected = { [weak self] in
            self?.menuBarController?.requestToggle()
        }
        if UserDefaults.standard.bool(forKey: Self.shakeEnabledKey) {
            shakeDetector?.start()
        }

        NotificationCenter.default.addObserver(
            self, selector: #selector(handleFocusToggle(_:)),
            name: .hyperfocusToggle, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(userDefaultsDidChange(_:)),
            name: UserDefaults.didChangeNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleOpenSettingsNotification(_:)),
            name: .hyperfocusOpenSettings, object: nil
        )

        UserDefaults.standard.addObserver(
            self, forKeyPath: "launchAtLogin", options: .new, context: nil
        )
        UserDefaults.standard.addObserver(
            self, forKeyPath: Self.shakeEnabledKey, options: .new, context: nil
        )
        UserDefaults.standard.addObserver(
            self, forKeyPath: Self.shakeSensitivityKey, options: .new, context: nil
        )
        UserDefaults.standard.addObserver(
            self, forKeyPath: Self.focusModeKey, options: .new, context: nil
        )
        UserDefaults.standard.addObserver(
            self, forKeyPath: "blurFPS", options: .new, context: nil
        )
        updateLaunchAtLogin()

        if !UserDefaults.standard.bool(forKey: Self.hasCompletedOnboardingKey) {
            showOnboardingWindow()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        displayManager?.removeAllOverlays()
        activeWindowTracker?.stop()
        shakeDetector?.stop()
        blurEngine?.detachAll()

        NotificationCenter.default.removeObserver(self)
        UserDefaults.standard.removeObserver(self, forKeyPath: "launchAtLogin")
        UserDefaults.standard.removeObserver(self, forKeyPath: Self.shakeEnabledKey)
        UserDefaults.standard.removeObserver(self, forKeyPath: Self.shakeSensitivityKey)
        UserDefaults.standard.removeObserver(self, forKeyPath: Self.focusModeKey)
        UserDefaults.standard.removeObserver(self, forKeyPath: "blurFPS")
    }

    // MARK: - Focus Toggle

    @objc private func handleFocusToggle(_ notification: Notification) {
        guard let active = notification.userInfo?["active"] as? Bool else { return }
        if active { activateFocus() } else { deactivateFocus() }
    }

    private func activateFocus() {
        isFocusActive = true
        isHiddenForExclusion = false
        displayManager?.configureForAllScreens()
        activeWindowTracker?.startFrameTracking()
        if selectedMode == .deep && currentMode != .deep {
            isSynchronizingFocusMode = true
            UserDefaults.standard.set(HyperfocusMode.studio.rawValue, forKey: Self.focusModeKey)
            isSynchronizingFocusMode = false
            presentDeepModeUnavailableAlert()
        }
        activeWindowTracker?.refreshFrontmostWindow()

        guard !isFrontmostApplicationExcluded else {
            isHiddenForExclusion = true
            menuBarController?.setFocusActive(true)
            return
        }

        showFocusPresentation()
    }

    private func deactivateFocus() {
        isFocusActive = false
        isHiddenForExclusion = false
        hasAttachedBlurEngine = false
        activeWindowTracker?.stopFrameTracking()
        blurEngine?.detachAll()
        for overlay in displayManager?.allOverlays() ?? [] {
            overlay.hide()
        }
        menuBarController?.setFocusActive(false)
    }

    private func applyCutout(_ frame: CGRect?) {
        for overlay in displayManager?.allOverlays() ?? [] {
            overlay.setCutout(frame)
        }
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

    // MARK: - Settings

    @objc private func userDefaultsDidChange(_ notification: Notification) {
        guard isFocusActive else { return }
        if isFrontmostApplicationExcluded || isHiddenForExclusion {
            updatePresentationForFrontmostApplication()
            return
        }
        if currentMode == .deep {
            pushSettingsToEngine()
        }
        showFocusPresentation()
    }

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
            for overlay in displayManager?.allOverlays() ?? [] {
                overlay.hide()
            }
            return
        }

        guard isHiddenForExclusion else { return }
        isHiddenForExclusion = false
        showFocusPresentation()
    }

    private func presentDeepModeUnavailableAlert() {
        let alert = NSAlert()
        alert.messageText = "Deep Mode Requires Pro"
        alert.informativeText = "Start the seven-day trial or activate Pro in Settings to use live blur. Studio mode is active instead."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Continue with Studio")
        if alert.runModal() == .alertFirstButtonReturn {
            showSettingsWindow()
        }
    }

    private func showFocusPresentation() {
        let frame = activeWindowTracker?.currentFrontmostWindowFrame
        let studioDim = studioDimColor

        let shouldAttachBlurEngine = currentMode == .deep && !hasAttachedBlurEngine
        if shouldAttachBlurEngine {
            pushSettingsToEngine()
        }

        for screen in NSScreen.screens {
            let displayID = screen.displayID
            guard let overlay = displayManager?.overlay(for: displayID) else { continue }
            overlay.setCutout(frame)

            if currentMode == .deep, shouldAttachBlurEngine {
                blurEngine?.attach(to: overlay, displayID: displayID)
            }

            guard isDisplayEffectEnabled(displayID) else {
                overlay.hide()
                continue
            }

            if currentMode == .studio {
                overlay.applyDim(studioDim)
            }

            overlay.show()
        }

        if shouldAttachBlurEngine {
            hasAttachedBlurEngine = true
        }
        menuBarController?.setFocusActive(true)
    }

    /// Called from Settings when the user toggles shake-to-toggle.
    /// Starting the CGEvent tap triggers the Input Monitoring permission
    // prompt, which is expected here because the user just opted in.
    func setShakeDetection(enabled: Bool) {
        if enabled {
            shakeDetector?.start()
        } else {
            shakeDetector?.stop()
        }
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
        if mode == .deep {
            _ = licenseManager.startTrial()
        }
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
        case Self.shakeEnabledKey:
            setShakeDetection(enabled: UserDefaults.standard.bool(forKey: Self.shakeEnabledKey))
        case Self.shakeSensitivityKey:
            shakeDetector?.sensitivity = CGFloat(
                UserDefaults.standard.object(forKey: Self.shakeSensitivityKey) as? Double ?? 3000
            )
        case Self.focusModeKey:
            guard isFocusActive, !isSynchronizingFocusMode else { return }
            deactivateFocus()
            activateFocus()
        case "blurFPS":
            guard isFocusActive, currentMode == .deep else { return }
            deactivateFocus()
            activateFocus()
        default:
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
        }
    }
}
