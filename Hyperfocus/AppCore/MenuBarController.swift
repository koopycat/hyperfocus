import Cocoa

/// Manages the menu bar status item, its menu, and the global keyboard shortcut
/// that toggles focus mode on / off.
///
/// The shortcut uses `NSEvent.addGlobalMonitorForEvents(matching: .keyDown)`
/// instead of the Carbon `RegisterEventHotKey` API.  Carbon's event target
/// registration (`InstallEventHandler(GetApplicationEventTarget(),...)`) triggers
/// a `kTCCServiceListenEvent` prompt on modern macOS even when called at
/// framework-init time with *no* hotkey configured.  Consolidating under the
/// `kTCCServiceAccessibility` permission (already needed for the AX window
/// observer) gives the user one clear prompt instead of two obscure ones.
@MainActor
final class MenuBarController: NSObject {
    private var statusItem: NSStatusItem!
    private var statusMenu: NSMenu!
    private var toggleMenuItem: NSMenuItem!
    private var isFocusActive = false

    /// Tokens returned by `addGlobalMonitorForEvents`.  Either both nil (no
    /// shortcut active) or both non-nil.
    private var keyDownMonitor: Any?
    private var flagsMonitor: Any?

    /// Cached shortcut definition so we can compare and avoid redundant
    /// re-registration when UserDefaults fires.
    private var activeKeyCode: UInt32 = 0
    private var activeModifiers: UInt32 = 0

    /// Current modifier flags captured by the flagsChanged monitor.
    /// Used only for tracking — the keyDown check inspects the event's own
    /// modifier flags which include the held keys.
    nonisolated(unsafe) private static var currentModifiers: UInt = 0

    // MARK: - UserDefaults keys

    private let shortcutKeyCodeKey = "shortcutKeyCode"
    private let shortcutModifiersKey = "shortcutModifiers"

    // MARK: - Init

    override init() {
        super.init()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = "◉"
            button.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        }

        statusMenu = NSMenu(title: "Hyperfocus")

        let toggleItem = NSMenuItem(
            title: "Turn On Focus",
            action: #selector(toggleFocus),
            keyEquivalent: ""
        )
        toggleItem.target = self
        statusMenu.addItem(toggleItem)
        toggleMenuItem = toggleItem

        statusMenu.addItem(NSMenuItem.separator())

        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        statusMenu.addItem(settingsItem)

        statusMenu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(
            title: "Quit Hyperfocus",
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quitItem.target = self
        statusMenu.addItem(quitItem)

        statusItem.menu = statusMenu

        updateIcon()

        // Register the saved shortcut if one is configured.  This is the only
        // code path that installs a global event monitor — if no shortcut is
        // saved (keyCode == 0) *nothing* TCC-relevant happens.
        registerSavedShortcut()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(shortcutDidChange),
            name: .hyperfocusShortcutChanged,
            object: nil
        )
    }

    deinit {
        let keyDownMonitor = keyDownMonitor
        let flagsMonitor = flagsMonitor
        Task { @MainActor in
            if let keyDownMonitor { NSEvent.removeMonitor(keyDownMonitor) }
            if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        }
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Public API

    /// Called from `AppDelegate` when the user toggles focus (menu item or
    /// global shortcut).  Updates the status-item icon and posts the toggle
    /// notification that the rest of the app responds to.
    func requestToggle() {
        setFocusActive(!isFocusActive)
        NotificationCenter.default.post(
            name: .hyperfocusToggle,
            object: nil,
            userInfo: ["active": isFocusActive]
        )
    }

    /// Synchronizes the menu state when focus mode is changed by a path other
    /// than the status menu, such as a keyboard shortcut or exclusion rule.
    func setFocusActive(_ active: Bool) {
        isFocusActive = active
        toggleMenuItem.title = active ? "Turn Off Focus" : "Turn On Focus"
        updateIcon()
    }

    // MARK: - Shortcut Management

    @objc private func shortcutDidChange() {
        registerSavedShortcut()
    }

    /// Reads the shortcut from UserDefaults.  If `keyCode == 0` (no shortcut
    /// saved) all global monitors are torn down.  Otherwise a fresh pair of
    /// event monitors is installed.
    private func registerSavedShortcut() {
        let storedKeyCode = UserDefaults.standard.integer(forKey: shortcutKeyCodeKey)
        let storedModifiers = UserDefaults.standard.integer(forKey: shortcutModifiersKey)
        guard let keyCode = UInt32(exactly: storedKeyCode),
              let modifiers = UInt32(exactly: storedModifiers)
        else {
            // Imported or manually edited preferences must never turn into a
            // trapping integer conversion at launch. Clear the invalid pair
            // rather than registering a shortcut with unrelated bit patterns.
            UserDefaults.standard.removeObject(forKey: shortcutKeyCodeKey)
            UserDefaults.standard.removeObject(forKey: shortcutModifiersKey)
            removeAllMonitors()
            activeKeyCode = 0
            activeModifiers = 0
            return
        }

        // Skip if nothing changed (avoids churn from didChangeNotification).
        guard keyCode != activeKeyCode || modifiers != activeModifiers else { return }

        removeAllMonitors()

        guard keyCode > 0 else {
            activeKeyCode = 0
            activeModifiers = 0
            return
        }

        activeKeyCode = keyCode
        activeModifiers = modifiers

        // We track modifier state so the keyDown handler knows what's held.
        flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { event in
            Self.currentModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue
        }

        keyDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let effective = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard effective.rawValue == modifiers else { return }
            guard UInt32(event.keyCode) == keyCode else { return }
            Task { @MainActor [weak self] in
                self?.requestToggle()
            }
        }
    }

    private func removeAllMonitors() {
        if let m = keyDownMonitor { NSEvent.removeMonitor(m); keyDownMonitor = nil }
        if let m = flagsMonitor  { NSEvent.removeMonitor(m); flagsMonitor = nil }
    }

    // MARK: - Menu Actions

    @objc private func toggleFocus() {
        requestToggle()
    }

    @objc private func openSettings() {
        NotificationCenter.default.post(name: .hyperfocusOpenSettings, object: nil)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: - Icon

    func updateIcon() {
        let button = statusItem.button
        button?.title = isFocusActive ? "●" : "◉"
        button?.setAccessibilityLabel(
            isFocusActive ? "Hyperfocus is on" : "Hyperfocus is off"
        )
    }
}

// MARK: - Notification names

extension Notification.Name {
    static let hyperfocusToggle = Notification.Name("hyperfocusToggle")
    static let hyperfocusShortcutTriggered = Notification.Name("hyperfocusShortcutTriggered")
    static let hyperfocusShortcutChanged = Notification.Name("hyperfocusShortcutChanged")
    static let hyperfocusOpenSettings = Notification.Name("hyperfocusOpenSettings")
}
