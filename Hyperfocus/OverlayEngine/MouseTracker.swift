import Cocoa

/// Tracks the mouse position by polling `NSEvent.mouseLocation` at 20 Hz.
/// No Accessibility or other permissions required.
final class MouseTracker {
    /// Fires when the cursor moves from outside the focused window into it.
    var onMouseEnteredWindow: (() -> Void)?

    /// Fires when the cursor moves from inside the focused window to outside.
    var onMouseExitedWindow: (() -> Void)?

    /// The window frame to hit-test against. Updated externally by the
    /// ActiveWindowTracker when the frontmost window frame changes.
    var windowFrame: CGRect?

    /// Small inward margin on the frame to prevent rapid enter/leave
    /// flickering when the cursor is exactly on the edge.
    private let edgeInset: CGFloat = 5

    private var timer: Timer?
    private var isInside = false

    /// Whether the cursor is currently inside the focused window frame.
    var isMouseInsideWindow: Bool { isInside }

    // MARK: - Lifecycle

    func start() {
        guard timer == nil else { return }
        isInside = false
        let timer = Timer(timeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isInside = false
    }

    // MARK: - Hit testing

    private func poll() {
        let screenPoint = NSEvent.mouseLocation
        guard let frame = windowFrame else { return }

        // Both are in AppKit screen coordinates (bottom-left origin).
        let insetFrame = frame.insetBy(dx: edgeInset, dy: edgeInset)
        let nowInside = insetFrame.contains(screenPoint)

        if nowInside && !isInside {
            isInside = true
            onMouseEnteredWindow?()
        } else if !nowInside && isInside {
            isInside = false
            onMouseExitedWindow?()
        }
    }
}
