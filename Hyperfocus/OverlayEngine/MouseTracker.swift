import Cocoa

/// Tracks the global mouse position and fires callbacks when the cursor
/// enters or leaves the focused window frame.
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

    private var monitor: Any?
    private var isInside = false

    /// Whether the cursor is currently inside the focused window frame.
    var isMouseInsideWindow: Bool { isInside }

    // MARK: - Lifecycle

    func start() {
        guard monitor == nil else { return }
        isInside = false
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            self?.handleMouseMove(at: NSEvent.mouseLocation)
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        isInside = false
    }

    // MARK: - Hit testing

    private func handleMouseMove(at screenPoint: NSPoint) {
        guard let frame = windowFrame else { return }

        // Convert from bottom-left (Cocoa) to our frame's coordinate system.
        // NSEvent.mouseLocation is in AppKit screen coordinates (bottom-left origin),
        // same as CGRect. Simple CGRect.contains works.
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
