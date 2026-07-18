import Cocoa
import CoreImage
import QuartzCore
import Metal

/// One borderless overlay window per display.
///
/// The window covers the whole screen at level 19 (below Dock=20 and menu
/// bar=24).  Its content layer holds the blurred desktop image.  A
/// `CAShapeLayer` mask carves a rounded-rect hole over the active window so
/// the sharp, live window shows through the gap.
///
/// Two content-bearing layers can coexist:
/// - `contentLayer` (plain CALayer) shows the Studio dim color and the
///   Deep-mode still-screenshot boot frame.
/// - `metalLayer` (CAMetalLayer) sits above it and shows the live Deep-mode
///   stream.  It stays transparent until the first drawable is presented, so
///   the boot frame below remains visible while the stream starts.
/// Both carry an identical fade+cutout mask chain; `updateMask()` keeps all
/// of them in sync.
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

    /// Layer that displays the Studio dim and the Deep-mode boot still frame.
    private var contentLayer: CALayer?

    /// Metal-backed layer for zero-copy Deep mode rendering, above
    /// `contentLayer`.  Set via `configureMetalLayer(device:drawableSize:)`.
    private(set) var metalLayer: CAMetalLayer?

    /// Every cutout mask in the layer tree (one per content-bearing layer).
    /// `updateMask()` rewrites all of them so the hole stays aligned no
    /// matter which layer is currently visible.
    private var shapeMasks: [CAShapeLayer] = []

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
        w.level = NSWindow.Level(rawValue: 19)
        w.ignoresMouseEvents = true
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        w.sharingType = .none

        w.contentView?.wantsLayer = true
        w.contentView?.layer?.isOpaque = false

        let content = CALayer()
        content.frame = CGRect(origin: .zero, size: frame.size)
        content.contentsGravity = .resize
        content.magnificationFilter = .linear
        content.minificationFilter = .linear
        content.isOpaque = false
        w.contentView?.layer?.addSublayer(content)
        installMaskChain(on: content)

        self.window = w
        self.contentLayer = content

        updateMask()
    }

    /// Attaches the Dock-fade gradient + even-odd cutout shape mask chain to
    /// a layer.  The gradient is the content mask and the shape is the
    /// gradient's mask -- keeping them chained matters: sibling layers are
    /// composited source-over, which would paint the gradient back into the
    /// active-window hole.
    private func installMaskChain(on layer: CALayer) {
        let frame = CGRect(origin: .zero, size: screen.frame.size)

        let fade = CAGradientLayer()
        fade.frame = frame
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

        layer.mask = fade
        shapeMasks.append(mask)
    }

    // MARK: - Metal Layer

    /// Create and attach a `CAMetalLayer` for zero-copy Deep mode rendering.
    ///
    /// The layer is placed above the plain `contentLayer`, which stays in
    /// place for the still-screenshot boot frame.  Idempotent: repeated
    /// attaches reuse the existing layer and only update the drawable size,
    /// instead of stacking full-screen Metal layers that would double
    /// WindowServer compositing work.
    ///
    /// `drawableSize` MUST be the capture (quarter-res) pixel size.  Without
    /// this, CAMetalLayer derives a full-display drawable and the renderer's
    /// quarter-res output lands in a corner of a mostly stale texture --
    /// verified to render garbage on 94% of the screen.  With the correct
    /// size, Core Animation upscales the small drawable to the full-screen
    /// bounds while compositing: the enlargement is free and drawable memory
    /// drops 16x (e.g. 14.7 MB -> 0.9 MB per buffer).
    func configureMetalLayer(device: MTLDevice, drawableSize: CGSize) {
        ensureWindow()

        if let existing = metalLayer {
            existing.drawableSize = drawableSize
            return
        }

        let frame = screen.frame
        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = false
        layer.isOpaque = false
        layer.backgroundColor = CGColor.clear
        layer.frame = CGRect(origin: .zero, size: frame.size)
        layer.drawableSize = drawableSize

        installMaskChain(on: layer)
        window?.contentView?.layer?.addSublayer(layer)

        self.metalLayer = layer

        updateMask()
    }

    /// Removes the Metal layer when leaving Deep mode (e.g. switching to
    /// Studio mid-session), freeing its drawables and compositor cost.
    private func removeMetalLayer() {
        guard let layer = metalLayer else { return }
        if let chain = layer.mask as? CAGradientLayer,
           let shape = chain.mask as? CAShapeLayer,
           let idx = shapeMasks.firstIndex(of: shape) {
            shapeMasks.remove(at: idx)
        }
        layer.removeFromSuperlayer()
        metalLayer = nil
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
        guard !shapeMasks.isEmpty else { return }

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

        for mask in shapeMasks {
            mask.path = path
        }
    }

    // MARK: - Capture-space Cutout

    /// The active-window cutout in capture (quarter-res) pixel coordinates,
    /// top-left origin -- the coordinate space of the captured texture.
    ///
    /// `MetalBlurRenderer` excludes this rect from its frame-change hash: the
    /// focused window shows through the mask hole live and unprocessed, so its
    /// content (typing, cursor blinks) must not count as a background change.
    /// Returns `.zero` when there is no cutout (whole screen is processed).
    func cutoutInCapturePixels(captureScale: CGFloat) -> CGRect {
        guard let cf = cutoutFrame, !cf.isNull, cf.width > 0, cf.height > 0 else {
            return .zero
        }

        let scale = screen.backingScaleFactor / captureScale
        let localX = (cf.minX - screen.frame.minX) * scale
        // Flip from AppKit bottom-left origin to texture top-left origin.
        let localYTop = (screen.frame.height - (cf.minY - screen.frame.minY) - cf.height) * scale

        let captureSize = CGSize(
            width: screen.frame.width * scale,
            height: screen.frame.height * scale
        )
        let rect = CGRect(x: localX, y: localYTop, width: cf.width * scale, height: cf.height * scale)
        return rect.integral.intersection(CGRect(origin: .zero, size: captureSize))
    }

    // MARK: - Content

    /// Prepare a transparent, capture-ready surface for Deep mode. Calling
    /// this before ScreenCaptureKit attaches ensures the overlay has a real
    /// window number to exclude and removes any Studio-only compositor state.
    func prepareForDeep() {
        ensureWindow()
        // Metal layer may already be configured; only nil the plain layer.
        contentLayer?.contents = nil
        contentLayer?.backgroundColor = nil
        contentLayer?.backgroundFilters = nil
    }

    /// Display the permission-free Studio effect. The same cutout mask used
    /// for Deep mode keeps the active window precisely aligned and live.
    func applyDim(_ color: NSColor, saturation: CGFloat = 1.0) {
        ensureWindow()
        // Studio never renders through Metal; drop the layer entirely so a
        // Deep -> Studio switch does not leave a stale full-screen layer
        // composited on every frame.
        removeMetalLayer()
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
    ///
    /// Used for the still-screenshot boot frame and as a fallback when
    /// Metal-layer rendering is unavailable.
    func applyImage(_ cg: CGImage) {
        ensureWindow()
        guard let content = contentLayer else { return }
        content.backgroundColor = nil
        content.backgroundFilters = nil
        content.contents = cg
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
