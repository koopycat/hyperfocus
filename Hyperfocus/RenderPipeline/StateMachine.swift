import Cocoa

/// Four-state machine controlling the overlay lifecycle.
///
/// off             → No windows, no capture, 0% GPU/CPU
/// idle            → Overlay visible, cached frame displayed, 0% GPU
/// processing      → Metal compute in flight (capture → blur → composite)
/// systemAnimation → Mission Control / Stage Manager transition; defer processing
enum OverlayState: Equatable {
    case off
    case idle
    case processing
    case systemAnimation

    var label: String {
        switch self {
        case .off:              return "Off"
        case .idle:             return "Idle"
        case .processing:       return "Processing"
        case .systemAnimation:  return "System Animation"
        }
    }
}

/// Manages state transitions and resource lifecycle
final class StateMachine {
    private(set) var state: OverlayState = .off
    private var animationDebounce: DispatchWorkItem?

    /// Bundle identifier of the macOS Dock process. When Dock.app becomes
    /// the frontmost app, Mission Control / Launchpad / Stage Manager is
    /// very likely active and we should defer processing to avoid capturing
    /// an animation mid-flight.
    private let dockBundleID = "com.apple.dock"

    private var appActivationObserver: NSObjectProtocol?

    // Callbacks
    var onEnterOff: (() -> Void)?
    var onEnterIdle: (() -> Void)?
    var onEnterProcessing: (() -> Void)?
    var onEnterSystemAnimation: (() -> Void)?

    deinit {
        if let observer = appActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    // MARK: - App activation observation (Mission Control detection)

    /// Start listening for `NSWorkspace.didActivateApplicationNotification`
    /// and auto-transition to `.systemAnimation` when the Dock becomes
    /// frontmost. Call once after the state machine is owned by a long-lived
    /// object (AppDelegate, etc.).
    func startAppActivationObservation() {
        guard appActivationObserver == nil else { return }
        let center = NSWorkspace.shared.notificationCenter
        appActivationObserver = center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self else { return }
            self.handleAppActivation(notification)
        }
    }

    private func handleAppActivation(_ notification: Notification) {
        // Skip the check while we're inert -- nothing to defer.
        guard state == .processing || state == .idle else { return }
        if detectSystemAnimation() {
            transition(to: .systemAnimation)
        }
    }

    /// Returns true if a system-level animation (Mission Control, Launchpad,
    /// Stage Manager, app exposé) is currently in progress.
    ///
    /// Heuristic: the Dock process (`com.apple.dock`) becoming the
    /// frontmost application is a strong signal that Mission Control /
    /// Launchpad is in the middle of its zoom animation. We don't try to
    /// distinguish *which* system animation is running -- all of them
    /// produce a visually broken captured frame, so we treat them the same.
    @discardableResult
    func detectSystemAnimation() -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication else {
            return false
        }
        return front.bundleIdentifier == dockBundleID
    }

    // MARK: - State transitions

    func transition(to newState: OverlayState) {
        guard newState != state else { return }

        let oldState = state
        state = newState

        print("[Hyperfocus] State: \(oldState.label) → \(newState.label)")

        switch newState {
        case .off:
            onEnterOff?()

        case .idle:
            onEnterIdle?()

        case .processing:
            onEnterProcessing?()

        case .systemAnimation:
            onEnterSystemAnimation?()
            // Auto-transition back after animation settles
            let work = DispatchWorkItem { [weak self] in
                guard self?.state == .systemAnimation else { return }
                self?.transition(to: .processing)
            }
            animationDebounce?.cancel()
            animationDebounce = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        }
    }

    var isActive: Bool {
        state != .off
    }
}
