import Cocoa

/// Four borderless NSWindows per display that dim everything *except* the
/// active window. The four strips (top, bottom, left, right) surround the
/// active window frame with a small gap, so the real window at level 0 is
/// fully visible through the physical gap between strips.
///
/// This is the approach used by HazeOver. It requires no permissions and
/// works reliably because the active window at level 0 naturally renders
/// above the window server's desktop level whenever it is frontmost.
final class StripOverlay {
    private let screen: NSScreen
    private var strips: [NSWindow] = []
    private var cutoutFrame: CGRect?

    /// Padding around the active window so its rounded corners and shadow
    /// are not clipped by the strip edges.
    private let padding: CGFloat = 8

    /// Fade zone at the bottom where the Dock's auto-hidden glass panel
    /// overlays the dim strip, preventing a visible halo.
    private let dockFadeHeight: CGFloat = 25

    init(screen: NSScreen) {
        self.screen = screen
    }

    // MARK: - Window creation

    private func makeStrip(frame: CGRect, color: CGColor) -> NSWindow {
        let w = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        w.isOpaque = false
        w.hasShadow = false
        w.backgroundColor = NSColor(cgColor: color) ?? .clear
        w.level = NSWindow.Level(rawValue: 19)
        w.ignoresMouseEvents = true
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        w.sharingType = .none
        return w
    }

    // MARK: - Cutout

    func setCutout(_ frame: CGRect?) {
        cutoutFrame = frame
    }

    // MARK: - Content

    func applyDim(_ color: NSColor) {
        guard let cutoutFrame, !cutoutFrame.isNull, cutoutFrame.width > 0, cutoutFrame.height > 0 else {
            // No window to cut out — dim the whole display
            applyFullscreenDim(color)
            return
        }

        removeStrips()

        let screenFrame = screen.frame
        let cgColor = color.cgColor

        // Clamp cutout to this display's bounds
        let hole = cutoutFrame.insetBy(dx: -padding, dy: -padding)
            .intersection(screenFrame)

        guard !hole.isNull, !hole.isEmpty else {
            applyFullscreenDim(color)
            return
        }

        // Top strip: from top of hole to top of screen
        let topH = screenFrame.maxY - hole.maxY
        if topH > 0 {
            strips.append(makeStrip(
                frame: CGRect(x: screenFrame.minX, y: hole.maxY,
                              width: screenFrame.width, height: topH),
                color: cgColor
            ))
        }

        // Bottom strip: from bottom of screen to bottom of hole (with Dock fade)
        let bottomH = hole.minY - screenFrame.minY
        if bottomH > 0 {
            strips.append(makeStrip(
                frame: CGRect(x: screenFrame.minX, y: screenFrame.minY,
                              width: screenFrame.width, height: bottomH),
                color: cgColor
            ))
        }

        // Left strip: screen-height slice to the left of hole
        let leftW = hole.minX - screenFrame.minX
        if leftW > 0 {
            strips.append(makeStrip(
                frame: CGRect(x: screenFrame.minX, y: hole.minY,
                              width: leftW, height: hole.height),
                color: cgColor
            ))
        }

        // Right strip: screen-height slice to the right of hole
        let rightW = screenFrame.maxX - hole.maxX
        if rightW > 0 {
            strips.append(makeStrip(
                frame: CGRect(x: hole.maxX, y: hole.minY,
                              width: rightW, height: hole.height),
                color: cgColor
            ))
        }
    }

    private func applyFullscreenDim(_ color: NSColor) {
        removeStrips()
        strips.append(makeStrip(frame: screen.frame, color: color.cgColor))
    }

    // MARK: - Visibility

    func show() {
        for strip in strips {
            strip.alphaValue = 0
            strip.orderFrontRegardless()
            strip.animator().alphaValue = 1.0
        }
    }

    func hide() {
        let windowNumbers = strips.map(\.windowNumber)
        for strip in strips {
            strip.animator().alphaValue = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            // Only order out strips that are still hidden (avoid pulling the
            // rug if show() was called again within the fade window).
            for (i, strip) in self.strips.enumerated() where i < windowNumbers.count {
                if strip.windowNumber == windowNumbers[i], strip.alphaValue < 0.01 {
                    strip.orderOut(nil)
                }
            }
        }
    }

    func orderOut() {
        for strip in strips { strip.orderOut(nil) }
    }

    var windowNumbers: [CGWindowID] {
        strips.map { CGWindowID($0.windowNumber) }
    }

    // MARK: - Private

    private func removeStrips() {
        for strip in strips { strip.orderOut(nil) }
        strips.removeAll()
    }
}
