import Cocoa
import QuartzCore

/// One borderless overlay window per display.
///
/// The window covers the whole screen at level 19 (below Dock=20 and menu
/// bar=24). Its content layer holds the blurred desktop image. A
/// `CAShapeLayer` mask carves a rounded-rect hole over the active window so
/// the sharp, live window shows through the gap.
///
/// Geometry notes:
/// - All input frames are in AppKit global coordinates (bottom-left origin,
///   spanning all displays), matching `NSScreen.frame` and
///   `ActiveWindowTracker.currentFrontmostWindowFrame`.
/// - The mask path uses `evenOdd` fill rule: the full-screen rect plus the
///   rounded inner rect cancel out, leaving the hole transparent so the
///   underlying active window is visible.
final class OverlayWindowController {
    private let screen: NSScreen
    private var window: NSWindow?

    /// Layer that displays the blurred desktop image.
    private var contentLayer: CALayer?

    /// Mask that carves the rounded active-window hole.
    private var maskLayer: CAShapeLayer?

    /// Active window frame in AppKit global coordinates, or nil to cover
    /// the whole screen (no hole).
    private var cutoutFrame: CGRect?

    /// Rounded-corner radius matching macOS window corners.
    private let cornerRadius: CGFloat = 10

    /// Small breathing room around the active window so its border is not
    /// clipped by the mask edge.
    private let edgePadding: CGFloat = 2

    /// Small zone at the bottom of each display left uncovered so the
    /// auto-hidden Dock slides up over the real desktop instead of the
    /// blurred overlay. Kept small (roughly the Dock tile size plus glass
    /// padding) so it is barely noticeable when the Dock is hidden.
    private let dockZoneHeight: CGFloat = 40

    init(screen: NSScreen) {
        self.screen = screen
    }

    // MARK: - Window Lifecycle

    /// Frame the overlay sits in, in screen coordinates. The bottom
    /// `dockZoneHeight` points are excluded so the Dock has a clean surface
    /// to composite against.
    private var overlayFrame: CGRect {
        var f = screen.frame
        f.size.height -= dockZoneHeight
        f.origin.y += dockZoneHeight
        return f
    }

    private func ensureWindow() {
        guard window == nil else { return }
        let frame = overlayFrame

        let w = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        w.isOpaque = false
        w.hasShadow = false
        w.backgroundColor = .clear
        w.level = NSWindow.Level(rawValue: 19)
        w.ignoresMouseEvents = true
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        w.sharingType = .none

        // Disable layer-tree flattening so each overlay is composited
        // independently (matches the design decision, avoids implicit
        // offscreen passes when several overlays coexist).
        w.contentView?.wantsLayer = true
        w.contentView?.layer?.isOpaque = false

        let content = CALayer()
        content.frame = CGRect(origin: .zero, size: frame.size)
        content.contentsGravity = .resize
        // Deep mode deliberately hands this layer a low-resolution image.
        // Linear filtering gives it a soft, natural enlargement without a
        // separate full-display Metal upscale pass every frame.
        content.magnificationFilter = .linear
        content.minificationFilter = .linear
        content.isOpaque = false
        w.contentView?.layer?.addSublayer(content)

        let mask = CAShapeLayer()
        mask.fillRule = .evenOdd
        mask.frame = CGRect(origin: .zero, size: frame.size)
        content.mask = mask

        self.window = w
        self.contentLayer = content
        self.maskLayer = mask

        updateMask()
    }

    // MARK: - Cutout

    /// Update the active-window hole. Pass `nil` to blur the whole screen
    /// (no visible window, e.g. on focus activation before the tracker has
    /// a frame, or when the frontmost window cannot be determined).
    func setCutout(_ frame: CGRect?) {
        cutoutFrame = frame
        updateMask()
    }


    private func updateMask() {
        guard let mask = maskLayer else { return }

        let local = CGRect(origin: .zero, size: overlayFrame.size)
        let path = CGMutablePath()
        path.addRect(local)

        if let cf = cutoutFrame, !cf.isNull, cf.width > 0, cf.height > 0 {
            // Convert global AppKit frame to this overlay's local space.
            let originX = cf.minX - overlayFrame.minX - edgePadding
            let originY = cf.minY - overlayFrame.minY - edgePadding
            var hole = CGRect(
                x: originX,
                y: originY,
                width: cf.width + edgePadding * 2,
                height: cf.height + edgePadding * 2
            )
            hole = hole.intersection(local)
            if !hole.isNull && !hole.isEmpty {
                path.addRoundedRect(
                    in: hole,
                    cornerWidth: cornerRadius,
                    cornerHeight: cornerRadius
                )
            }
        }

        mask.path = path
    }

    // MARK: - Content

    /// Display the permission-free Studio effect. The mask keeps the active
    /// window live and sharp while the rest of the display is dimmed.
    func applyDim(_ color: NSColor) {
        ensureWindow()
        contentLayer?.contents = nil
        contentLayer?.backgroundColor = color.cgColor
    }

    /// Display a processed (blurred) image of the whole screen. The mask
    /// handles the active-window cutout; this just paints the pixels.
    func applyImage(_ cg: CGImage) {
        ensureWindow()
        contentLayer?.backgroundColor = nil
        contentLayer?.contents = cg
    }

    /// CGWindowID of the overlay window, used by the capture filter to
    /// exclude the overlay from its own capture (avoids feedback flicker).
    var windowNumber: CGWindowID {
        guard let w = window else { return 0 }
        return CGWindowID(w.windowNumber)
    }

    // MARK: - Visibility

    func show() {
        ensureWindow()
        window?.alphaValue = 0
        window?.orderFrontRegardless()
        window?.animator().alphaValue = 1.0
    }

    func hide() {
        window?.animator().alphaValue = 0
        let n = window?.windowNumber
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            // Only order out if still hidden (avoid pulling the rug if show()
            // was called again within the fade window).
            guard let self, let w = self.window, w.windowNumber == n, w.alphaValue < 0.01 else { return }
            w.orderOut(nil)
        }
    }

    func orderOut() {
        window?.orderOut(nil)
    }
}
