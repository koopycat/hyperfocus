import Cocoa

/// Tracks the frontmost application and its active window frame
final class ActiveWindowTracker {
    private var frontmostApp: NSRunningApplication?
    /// Always stored in AppKit's global, bottom-left-origin screen coordinates.
    private var frontmostWindowFrame: CGRect?

    /// Invoked on the main thread after the focused-window frame changes.
    var onWindowFrameChanged: ((CGRect?) -> Void)?

    /// Invoked when the user starts dragging or resizing the frontmost window.
    var onWindowDragStarted: (() -> Void)?

    /// Invoked after the window has been stationary for the settle duration.
    var onWindowDragEnded: (() -> Void)?

    /// Invoked after the frontmost application and its window frame have been
    /// refreshed, even when the frame itself did not change.
    var onFrontmostApplicationChanged: ((NSRunningApplication?) -> Void)?

    /// Guards against multiple start() calls per lifecycle.
    private var hasStarted = false
    /// Cached result from the one-off silent AX probe. nil if not probed yet,
    /// true if trusted, false if not. Once known, avoid subsequent TCC IPC.
    private var axTrusted: Bool?

    /// When Accessibility is unavailable, WindowServer exposes no movement
    /// notifications for another app's windows. This timer is the public,
    /// permission-free fallback. It runs only while focus mode is active and
    /// is registered in common modes so it continues to fire during drags.
    private var fallbackFrameTimer: Timer?

    /// Drag detection. Every frame change while focus is active triggers
    /// an immediate overlay hide. A 500ms settle timer resets on each
    /// subsequent change; when it finally fires, the overlays return.
    private let dragSettleInterval: TimeInterval = 0.50
    private var dragSettleTimer: Timer?
    private(set) var isDragging = false

    /// Adaptive polling for the permission-free fallback. `CGWindowListCopy-
    /// WindowInfo` is full WindowServer IPC over every on-screen window, so
    /// the fallback only polls fast while a change is plausibly in progress
    /// (a drag) and idles down otherwise.
    private static let fallbackFastInterval: TimeInterval = 1.0 / 30.0
    private static let fallbackSlowInterval: TimeInterval = 1.0 / 4.0
    /// How long after the last detected frame change fast polling continues.
    private static let fallbackFastHold: TimeInterval = 1.5
    private var lastFrameChangeAt: CFAbsoluteTime = 0

    private struct Observation {
        var observer: AXObserver
        var pid: pid_t
        var focusedWindow: AXUIElement?
    }
    private var observations: [pid_t: Observation] = [:]

    private struct CGWindowCandidate {
        let topLeftFrame: CGRect
        let layer: Int
    }

    // MARK: - Start / Stop

    func start() {
        guard !hasStarted else { return }
        hasStarted = true

        // Probe Accessibility silently exactly once.  We never auto-fire the
        // system prompt here; if permission is missing we fall back to the
        // CGWindowList path (no permission required) and the user can grant
        // AX later from System Settings for sub-frame window-change latency.
        if axTrusted == nil {
            let probe = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: false] as CFDictionary
            axTrusted = AXIsProcessTrustedWithOptions(probe)
        }

        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(
            self,
            selector: #selector(activeAppChanged(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        nc.addObserver(
            self,
            selector: #selector(appLaunched(_:)),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )
        nc.addObserver(
            self,
            selector: #selector(appTerminated(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )

        // Track the app that was already frontmost when Hyperfocus launched.
        // Apps only emit AX events after an observer is registered, so this
        // registration must not be limited to future launch notifications.
        if let front = NSWorkspace.shared.frontmostApplication {
            frontmostApp = front
            registerAXObserver(for: front)
        }
        refreshFrontmostWindow()
    }

    func stop() {
        // Remove all AX observations synchronously before clearing any
        // other state. This prevents a callback from arriving with a
        // dangling Unmanaged raw pointer after the tracker is gone.
        removeAllObservations()
        dragSettleTimer?.invalidate()
        dragSettleTimer = nil
        isDragging = false
        stopFrameTracking()
        hasStarted = false
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    // MARK: - Active frame tracking

    /// Starts motion tracking for an active focus session.
    /// AXObserver supplies immediate events when Accessibility is granted.
    /// Otherwise poll WindowServer at 30 Hz so the cutout follows a drag
    /// without requesting any permission.
    func startFrameTracking() {
        guard axTrusted != true, fallbackFrameTimer == nil else { return }
        lastFrameChangeAt = CFAbsoluteTimeGetCurrent()
        let timer = Timer(
            timeInterval: Self.fallbackFastInterval,
            target: self,
            selector: #selector(fallbackPollTick),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .common)
        fallbackFrameTimer = timer
    }

    /// Timer callback for the permission-free fallback. Polls fast right
    /// after a detected change, then decays to the slow steady-state rate
    /// until something changes again (which reschedules to fast).
    @objc private func fallbackPollTick() {
        if fallbackFrameTimer?.timeInterval == Self.fallbackFastInterval,
           CFAbsoluteTimeGetCurrent() - lastFrameChangeAt > Self.fallbackFastHold {
            rescheduleFallbackPolling(interval: Self.fallbackSlowInterval)
        }
        refreshFrontmostWindow()
    }

    private func rescheduleFallbackPolling(interval: TimeInterval) {
        fallbackFrameTimer?.invalidate()
        let timer = Timer(
            timeInterval: interval,
            target: self,
            selector: #selector(fallbackPollTick),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .common)
        fallbackFrameTimer = timer
    }

    /// Stops the permission-free fallback immediately when focus mode ends.
    func stopFrameTracking() {
        fallbackFrameTimer?.invalidate()
        fallbackFrameTimer = nil
    }

    // MARK: - Frontmost Query

    var currentFrontmostApp: NSRunningApplication? { frontmostApp }

    var currentFrontmostWindowFrame: CGRect? { frontmostWindowFrame }

    /// Called when the display manager needs to update the cutout position.
    @objc func refreshFrontmostWindow() {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            let didChange = frontmostApp != nil
            frontmostApp = nil
            setFrontmostWindowFrame(nil)
            if didChange { onFrontmostApplicationChanged?(nil) }
            return
        }

        let didChange = frontmostApp?.processIdentifier != app.processIdentifier
        frontmostApp = app
        registerAXObserver(for: app)

        // Both APIs report a top-left-origin rectangle. Normalize it before
        // publishing so every caller can use AppKit/NSScreen coordinates.
        let frame = windowFrameViaAX(for: app) ?? windowFrameViaCGWindowList(for: app)
        setFrontmostWindowFrame(frame)
        if didChange { onFrontmostApplicationChanged?(app) }
    }

    // MARK: - CGWindowList Fallback (No Permission Required)

    private func windowFrameViaCGWindowList(for app: NSRunningApplication) -> CGRect? {
        let pid = app.processIdentifier

        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        // CGWindowList is ordered front-to-back. The first regular window is
        // the best public approximation of the selected window when AX is not
        // available. Do not prefer a titled background window over an untitled
        // selected one, which is a common cause of a wrong cutout in browsers.
        let candidates = windowList.compactMap { info -> CGWindowCandidate? in
            guard let ownerPID = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  ownerPID == pid,
                  (info[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? true,
                  ((info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0
            else {
                return nil
            }

            guard let bounds = info[kCGWindowBounds as String] as? NSDictionary else {
                return nil
            }

            var topLeftFrame = CGRect.zero
            guard CGRectMakeWithDictionaryRepresentation(bounds, &topLeftFrame),
                  !topLeftFrame.isEmpty,
                  topLeftFrame.width.isFinite,
                  topLeftFrame.height.isFinite
            else {
                return nil
            }

            return CGWindowCandidate(
                topLeftFrame: topLeftFrame,
                layer: (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            )
        }

        let normalWindows = candidates.filter { $0.layer == 0 }
        let selected = normalWindows.first ?? candidates.first

        guard let selected else { return nil }
        return appKitFrame(fromTopLeftScreenRect: selected.topLeftFrame)
    }

    // MARK: - AX Window Frame

    private func windowFrameViaAX(for app: NSRunningApplication) -> CGRect? {
        // Avoid all AX API calls (each of which triggers TCC IPC with
        // prompt_type=1 on macOS 26) when we already know the permission
        // is not granted.
        guard axTrusted == true else { return nil }

        let pid = app.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)

        var focusedWindow: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedWindow)

        guard result == .success,
              let focusedWindow,
              CFGetTypeID(focusedWindow) == AXUIElementGetTypeID()
        else {
            updateFocusedWindowObservation(nil, for: pid)
            return nil
        }
        let window = focusedWindow as! AXUIElement
        updateFocusedWindowObservation(window, for: pid)

        var position: CFTypeRef?
        var size: CFTypeRef?

        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &size) == .success,
              let position,
              let size,
              CFGetTypeID(position) == AXValueGetTypeID(),
              CFGetTypeID(size) == AXValueGetTypeID()
        else {
            return nil
        }

        var point = CGPoint.zero
        var cgSize = CGSize.zero
        let positionValue = position as! AXValue
        let sizeValue = size as! AXValue
        guard AXValueGetType(positionValue) == .cgPoint,
              AXValueGetType(sizeValue) == .cgSize,
              AXValueGetValue(positionValue, .cgPoint, &point),
              AXValueGetValue(sizeValue, .cgSize, &cgSize)
        else {
            return nil
        }

        return appKitFrame(fromTopLeftScreenRect: CGRect(origin: point, size: cgSize))
    }

    /// AX and CGWindowList use global screen coordinates whose origin is the
    /// upper-left of the primary (menu-bar) display. AppKit uses the lower-left
    /// of that same display, so flip around the primary display's top edge.
    private func appKitFrame(fromTopLeftScreenRect frame: CGRect) -> CGRect? {
        guard !frame.isNull, !frame.isInfinite,
              frame.origin.x.isFinite, frame.origin.y.isFinite,
              frame.width.isFinite, frame.height.isFinite,
              frame.width > 0, frame.height > 0
        else { return nil }

        // AX uses top-left origin coords. Convert to Quartz bottom-left.
        // Use maxY of ALL screens, not just primary (fixes multi-display).
        let totalHeight = NSScreen.screens.map(\.frame.maxY).max() ?? 0

        return CGRect(
            x: frame.minX,
            y: totalHeight - frame.maxY,
            width: frame.width,
            height: frame.height
        )
    }

    private func setFrontmostWindowFrame(_ frame: CGRect?) {
        guard frontmostWindowFrame != frame else { return }
        frontmostWindowFrame = frame
        lastFrameChangeAt = CFAbsoluteTimeGetCurrent()
        // A real change means a drag may be starting: return the fallback to
        // fast polling so the cutout keeps up (if it had decayed to slow).
        if let timer = fallbackFrameTimer, timer.timeInterval != Self.fallbackFastInterval {
            rescheduleFallbackPolling(interval: Self.fallbackFastInterval)
        }
        onWindowFrameChanged?(frame)

        // Every frame change restarts the settle timer. The first change
        // triggers the drag-started callback to hide overlays immediately.
        if !isDragging {
            isDragging = true
            onWindowDragStarted?()
        }
        dragSettleTimer?.invalidate()
        let settle = Timer(timeInterval: dragSettleInterval, repeats: false) { [weak self] _ in
            self?.finishDrag()
        }
        RunLoop.main.add(settle, forMode: .common)
        dragSettleTimer = settle
    }

    private func finishDrag() {
        isDragging = false
        dragSettleTimer?.invalidate()
        dragSettleTimer = nil
        onWindowDragEnded?()
    }

    // MARK: - Observers

    @objc private func activeAppChanged(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        registerAXObserver(for: app)
        refreshFrontmostWindow()
    }

    @objc private func appLaunched(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        registerAXObserver(for: app)
    }

    @objc private func appTerminated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        removeObservation(for: app.processIdentifier)

        if frontmostApp?.processIdentifier == app.processIdentifier {
            // Workspace may not have selected the replacement app yet when it
            // posts termination. Refresh on the next main-loop turn instead
            // of leaving a cutout around the departed window.
            DispatchQueue.main.async { [weak self] in
                self?.refreshFrontmostWindow()
            }
        }
    }

    // MARK: - AXObserver (Window Change Detection)

    private func registerAXObserver(for app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard observations[pid] == nil else { return }

        // When we know accessibility is not granted, skip all AX API calls
        // entirely.  They still do TCC IPC even without a prompt, so avoiding
        // them on every app-switch reduces noise in TCC logs.
        guard axTrusted != false else { return }

        var observer: AXObserver?
        let result = AXObserverCreate(pid, axWindowChangeCallback, &observer)

        guard result == .success, let obs = observer else {
            return
        }

        let appElement = AXUIElementCreateApplication(pid)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        // Application-level notifications tell us when the focused window
        // changes or appears/disappears. Move and resize are registered on
        // the actual focused window below; several apps do not reliably
        // forward those notifications through their application element.
        let notifications: [String] = [
            kAXWindowCreatedNotification,
            kAXUIElementDestroyedNotification,
            kAXFocusedWindowChangedNotification,
        ]

        var receivedAtLeastOneNotification = false
        for notif in notifications {
            let registration = AXObserverAddNotification(obs, appElement, notif as CFString, selfPtr)
            if registration == .success || registration == .notificationAlreadyRegistered {
                receivedAtLeastOneNotification = true
            }
        }

        // Do not cache a failed registration. In particular, AX can be
        // disabled while its permission prompt is open; leaving this PID out
        // of observations lets a later refresh retry after access is granted.
        guard receivedAtLeastOneNotification else { return }

        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(obs),
            .commonModes
        )

        observations[pid] = Observation(observer: obs, pid: pid, focusedWindow: nil)
    }

    private func updateFocusedWindowObservation(_ window: AXUIElement?, for pid: pid_t) {
        guard var observation = observations[pid] else { return }

        if let current = observation.focusedWindow,
           let window,
           CFEqual(current, window) {
            return
        }

        let notifications: [String] = [
            kAXWindowMovedNotification,
            kAXWindowResizedNotification,
        ]

        if let current = observation.focusedWindow {
            for notification in notifications {
                AXObserverRemoveNotification(observation.observer, current, notification as CFString)
            }
            observation.focusedWindow = nil
        }

        guard let window else {
            observations[pid] = observation
            return
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        var receivedAtLeastOneNotification = false
        for notification in notifications {
            let registration = AXObserverAddNotification(
                observation.observer,
                window,
                notification as CFString,
                selfPtr
            )
            if registration == .success || registration == .notificationAlreadyRegistered {
                receivedAtLeastOneNotification = true
            }
        }

        if receivedAtLeastOneNotification {
            observation.focusedWindow = window
        }
        observations[pid] = observation
    }

    private func removeObservation(for pid: pid_t) {
        if let obs = observations[pid] {
            if let focusedWindow = obs.focusedWindow {
                AXObserverRemoveNotification(obs.observer, focusedWindow, kAXWindowMovedNotification as CFString)
                AXObserverRemoveNotification(obs.observer, focusedWindow, kAXWindowResizedNotification as CFString)
            }
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(obs.observer),
                .commonModes
            )
        }
        observations.removeValue(forKey: pid)
    }

    private func removeAllObservations() {
        for pid in observations.keys {
            removeObservation(for: pid)
        }
    }
}

// MARK: - AX Callback

private func axWindowChangeCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon = refcon else { return }
    let tracker = Unmanaged<ActiveWindowTracker>.fromOpaque(refcon).takeUnretainedValue()
    // The observer source is already installed in the main run loop's common
    // modes. Calling directly keeps updates live while the user drags.
    tracker.refreshFrontmostWindow()
}
