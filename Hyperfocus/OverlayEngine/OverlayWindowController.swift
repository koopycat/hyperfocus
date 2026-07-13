import Cocoa
import CoreImage
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

    /// Keep the cutout on the exact accessibility window frame. Any extra
    /// breathing room makes Studio visibly drift from the focused window.
    private let edgePadding: CGFloat = 0

    /// Small zone at the bottom of each display where the overlay fades
    /// to transparent via a gradient mask. The auto-hidden Dock slides up
    /// into this zone and composites against the real desktop, not the
    /// blurred overlay. The smooth transition avoids the harsh edge that
    /// causes visible halos when the Dock's glass background straddles
    /// the overlay boundary.
    private let dockFadeHeight: CGFloat = 25

    init(screen: NSScreen) {
        self.screen = screen
    }

    // MARK: - Window Lifecycle

    private func ensureWindow() {
        guard window == nil else { return }
        let frame = screen.frame

        let w = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        w.isOpaque = false
        w.hasShadow = false
        w.backgroundColor = .clear
        w.level = NSWindow.Level(rawValue: 19)  // above menu bar (24)
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
        content.magnificationFilter = .linear
        content.minificationFilter = .linear
        content.isOpaque = false
        w.contentView?.layer?.addSublayer(content)

        // The gradient is the content mask and the even-odd shape is its own
        // mask. Keeping them in a mask chain matters: sibling layers are
        // composited with source-over, which would paint the gradient back
        // into the active-window hole and blur the focused window.
        let fade = CAGradientLayer()
        fade.frame = CGRect(origin: .zero, size: frame.size)
        fade.colors = [
            CGColor(gray: 1, alpha: 0),   // y=0 (bottom): transparent
            CGColor(gray: 1, alpha: 1),   // y=dockFadeHeight: opaque
            CGColor(gray: 1, alpha: 1),   // rest: opaque
        ]
        let fadeFraction = min(1.0, dockFadeHeight / frame.height)
        fade.locations = [0, NSNumber(value: fadeFraction), 1]
        fade.startPoint = CGPoint(x: 0.5, y: 0)
        fade.endPoint = CGPoint(x: 0.5, y: 1)

        let mask = CAShapeLayer()
        mask.fillRule = .evenOdd
        mask.fillColor = CGColor(gray: 1, alpha: 1)
        mask.frame = fade.bounds
        fade.mask = mask

        content.mask = fade

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

        let local = CGRect(origin: .zero, size: screen.frame.size)
        let path = CGMutablePath()
        path.addRect(local)

        if let cf = cutoutFrame, !cf.isNull, cf.width > 0, cf.height > 0 {
            // Convert global AppKit frame to this overlay's local space.
            let originX = cf.minX - screen.frame.minX - edgePadding
            let originY = cf.minY - screen.frame.minY - edgePadding
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

    /// Prepare a transparent, capture-ready surface for Deep mode. Calling
    /// this before ScreenCaptureKit attaches ensures the overlay has a real
    /// window number to exclude and removes any Studio-only compositor state.
    func prepareForDeep() {
        ensureWindow()
        contentLayer?.contents = nil
        contentLayer?.backgroundColor = nil
        contentLayer?.backgroundFilters = nil
    }

    /// Display the permission-free Studio effect. The same cutout mask used
    /// for Deep mode keeps the active window precisely aligned and live.
    func applyDim(_ color: NSColor, saturation: CGFloat = 1.0) {
        ensureWindow()
        contentLayer?.contents = nil
        contentLayer?.backgroundColor = color.cgColor

        if saturation < 1.0, let filter = CIFilter(name: "CIColorControls") {
            filter.setValue(saturation, forKey: kCIInputSaturationKey)
            contentLayer?.backgroundFilters = [filter]
        } else {
            contentLayer?.backgroundFilters = nil
        }
    }

    /// Display a processed (blurred) image of the whole screen. The mask
    /// handles the active-window cutout; this just paints the pixels.
    func applyImage(_ cg: CGImage) {
        ensureWindow()
        contentLayer?.backgroundColor = nil
        contentLayer?.backgroundFilters = nil
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
