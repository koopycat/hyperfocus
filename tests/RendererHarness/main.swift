import Cocoa
import Metal
import QuartzCore

// End-to-end harness for the Deep-mode renderer.
//
// It drives the real MetalBlurRenderer, compiled from the production shader,
// through a CAMetalLayer and synthetic inputs. It deliberately exercises the
// behavior that makes a filter a focus feature rather than mere decoration:
// background text becomes illegible, active-cutout changes do not redraw, and
// temporal modes suppress unnecessary motion.

let W = 640
let H = 360

func makePixelBuffer(fill: (_ x: Int, _ y: Int) -> UInt8) -> CVPixelBuffer? {
    var pb: CVPixelBuffer?
    let attrs: [CFString: Any] = [
        kCVPixelBufferMetalCompatibilityKey: true,
        kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
    ]
    guard CVPixelBufferCreate(
        kCFAllocatorDefault,
        W,
        H,
        kCVPixelFormatType_32BGRA,
        attrs as CFDictionary,
        &pb
    ) == kCVReturnSuccess, let buffer = pb else { return nil }

    CVPixelBufferLockBaseAddress(buffer, [])
    let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
    let bpr = CVPixelBufferGetBytesPerRow(buffer)
    for y in 0..<H {
        for x in 0..<W {
            let v = fill(x, y)
            let p = base + y * bpr + x * 4
            p[0] = v       // B
            p[1] = v       // G
            p[2] = v       // R
            p[3] = 255     // A
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    return buffer
}

func withModifiedRegion(_ base: CVPixelBuffer, rect: CGRect, value: UInt8) -> CVPixelBuffer {
    CVPixelBufferLockBaseAddress(base, [])
    let p0 = CVPixelBufferGetBaseAddress(base)!.assumingMemoryBound(to: UInt8.self)
    let bpr = CVPixelBufferGetBytesPerRow(base)
    for y in Int(rect.minY)..<Int(rect.maxY) {
        for x in Int(rect.minX)..<Int(rect.maxX) {
            let p = p0 + y * bpr + x * 4
            p[0] = value
            p[1] = value
            p[2] = value
            p[3] = 255
        }
    }
    CVPixelBufferUnlockBaseAddress(base, [])
    return base
}

/// Produces small desktop-style text at capture resolution across several
/// sizes and contrast levels. A real 12pt desktop font is roughly this scale
/// after Hyperfocus downsizes a source display by 4x, so the fixture avoids
/// misleading giant title text that would remain readable in the product too.
struct TextFixture {
    let image: CGImage
    /// A dilated edge mask derived from the exact text glyphs. Measuring only
    /// these pixels avoids diluting the legibility metric with blank panels.
    let edgeMask: [Bool]
}

private struct FixtureLine {
    let text: String
    let size: CGFloat
    let point: NSPoint
    let background: NSColor
    let foreground: NSColor
}

private let fixtureLines: [FixtureLine] = [
    FixtureLine(
        text: "Slack  •  design review in five minutes",
        size: 10,
        point: NSPoint(x: 58, y: 232),
        background: NSColor(calibratedWhite: 0.92, alpha: 1),
        foreground: .black
    ),
    FixtureLine(
        text: "Inbox:  12 unread messages",
        size: 11,
        point: NSPoint(x: 58, y: 196),
        background: NSColor(calibratedWhite: 0.58, alpha: 1),
        foreground: NSColor(calibratedWhite: 0.15, alpha: 1)
    ),
    FixtureLine(
        text: "Build succeeded   14:22",
        size: 12,
        point: NSPoint(x: 58, y: 158),
        background: NSColor(calibratedWhite: 0.18, alpha: 1),
        foreground: NSColor(calibratedWhite: 0.94, alpha: 1)
    ),
    FixtureLine(
        text: "Meeting notes - draft proposal",
        size: 10,
        point: NSPoint(x: 58, y: 122),
        background: NSColor(calibratedWhite: 0.76, alpha: 1),
        foreground: NSColor(calibratedWhite: 0.34, alpha: 1)
    ),
    FixtureLine(
        text: "Terminal  ~/src/hyperfocus",
        size: 9,
        point: NSPoint(x: 58, y: 88),
        background: NSColor(calibratedWhite: 0.08, alpha: 1),
        foreground: NSColor(calibratedWhite: 0.72, alpha: 1)
    ),
]

private func fixtureImage(maskOnly: Bool) -> CGImage {
    let image = NSImage(size: NSSize(width: W, height: H))
    image.lockFocus()
    (maskOnly ? NSColor.black : NSColor(calibratedWhite: 0.12, alpha: 1)).setFill()
    NSBezierPath(rect: NSRect(x: 0, y: 0, width: W, height: H)).fill()

    for line in fixtureLines {
        if !maskOnly {
            line.background.setFill()
            NSBezierPath(rect: NSRect(x: 42, y: line.point.y - 5, width: 556, height: 28)).fill()
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: line.size, weight: .regular),
            .foregroundColor: maskOnly ? NSColor.white : line.foreground,
        ]
        NSAttributedString(string: line.text, attributes: attributes).draw(at: line.point)
    }
    image.unlockFocus()

    guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        fatalError("Could not create synthetic text fixture")
    }
    return cg
}

/// Normalizes every image to known BGRA byte order before measuring it.
func bgraBytes(from image: CGImage) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: W * H * 4)
    bytes.withUnsafeMutableBytes { rawBuffer in
        guard let context = CGContext(
            data: rawBuffer.baseAddress,
            width: W,
            height: H,
            bitsPerComponent: 8,
            bytesPerRow: W * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.union(
                CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
            ).rawValue
        ) else {
            fatalError("Could not create bitmap context")
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: W, height: H))
    }
    return bytes
}

func luma(_ bytes: [UInt8], x: Int, y: Int) -> Double {
    let i = (y * W + x) * 4
    let b = Double(bytes[i]) / 255.0
    let g = Double(bytes[i + 1]) / 255.0
    let r = Double(bytes[i + 2]) / 255.0
    return r * 0.2126 + g * 0.7152 + b * 0.0722
}

private func dilatedTextEdgeMask(from glyphMask: CGImage) -> [Bool] {
    let bytes = bgraBytes(from: glyphMask)
    var edgeMask = [Bool](repeating: false, count: W * H)

    for y in 1..<(H - 1) {
        for x in 1..<(W - 1) where luma(bytes, x: x, y: y) > 0.5 {
            let isEdge = luma(bytes, x: x - 1, y: y) <= 0.5
                || luma(bytes, x: x + 1, y: y) <= 0.5
                || luma(bytes, x: x, y: y - 1) <= 0.5
                || luma(bytes, x: x, y: y + 1) <= 0.5
            guard isEdge else { continue }

            // A small halo captures the blurred edge rather than only its
            // original sharp source position.
            for yy in max(1, y - 2)...min(H - 2, y + 2) {
                for xx in max(1, x - 2)...min(W - 2, x + 2) {
                    edgeMask[yy * W + xx] = true
                }
            }
        }
    }
    return edgeMask
}

func makeTextFixture() -> TextFixture {
    let image = fixtureImage(maskOnly: false)
    let glyphMask = fixtureImage(maskOnly: true)
    return TextFixture(image: image, edgeMask: dilatedTextEdgeMask(from: glyphMask))
}

/// A stable legibility proxy. Text creates concentrated high-frequency edge
/// energy; blur destroys it. The mask contains only text edge pixels and a
/// two-pixel halo, so whitespace and panel boundaries cannot dilute results.
func normalizedGradientEnergy(_ image: CGImage, edgeMask: [Bool]) -> Double {
    let bytes = bgraBytes(from: image)
    var total = 0.0
    var samples = 0
    for y in 1..<(H - 1) {
        for x in 1..<(W - 1) where edgeMask[y * W + x] {
            let center = luma(bytes, x: x, y: y)
            total += abs(center - luma(bytes, x: x - 1, y: y))
            total += abs(center - luma(bytes, x: x, y: y - 1))
            samples += 1
        }
    }
    return total / Double(max(samples * 2, 1))
}

// --- App + window + CAMetalLayer (mirrors OverlayWindowController.configureMetalLayer) ---
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

guard let renderer = MetalBlurRenderer() else {
    print("FATAL: MetalBlurRenderer init failed")
    exit(1)
}

let window = NSWindow(
    contentRect: CGRect(x: 0, y: 0, width: W, height: H),
    styleMask: [.titled], backing: .buffered, defer: false
)
window.contentView?.wantsLayer = true
let metalLayer = CAMetalLayer()
metalLayer.device = renderer.device
metalLayer.pixelFormat = .bgra8Unorm
metalLayer.framebufferOnly = false
metalLayer.isOpaque = false
metalLayer.backgroundColor = CGColor.clear
metalLayer.frame = CGRect(x: 0, y: 0, width: W, height: H)
metalLayer.drawableSize = CGSize(width: W, height: H)
window.contentView?.layer?.addSublayer(metalLayer)
window.orderFrontRegardless()
RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))

var failures = 0
func check(_ name: String, _ condition: Bool) {
    print("\(condition ? "PASS" : "FAIL"): \(name)")
    if !condition { failures += 1 }
}

// Requirement: the visible active-window cutout is an actual transparent
// even-odd mask hole, not merely a hash exclusion. A transparent overlay at
// that point means WindowServer composites the source focused window beneath
// it unmodified, independent of the active Deep filter.
if let screen = NSScreen.main {
    let overlay = OverlayWindowController(screen: screen)
    overlay.prepareForDeep()
    let frame = screen.frame
    let cutout = CGRect(
        x: frame.minX + frame.width * 0.40,
        y: frame.minY + frame.height * 0.40,
        width: max(40, frame.width * 0.15),
        height: max(40, frame.height * 0.15)
    )
    overlay.setCutout(cutout)

    let maskIsCorrect: Bool = {
        guard let content = overlay.testingContentLayer,
              let fade = content.mask as? CAGradientLayer,
              let shape = fade.mask as? CAShapeLayer,
              let path = shape.path
        else { return false }
        let localHoleCenter = CGPoint(
            x: cutout.midX - frame.minX,
            y: cutout.midY - frame.minY
        )
        let localBackground = CGPoint(x: max(10, frame.width * 0.10), y: frame.height * 0.50)
        return !path.contains(localHoleCenter, using: .evenOdd, transform: .identity)
            && path.contains(localBackground, using: .evenOdd, transform: .identity)
    }()
    check("active-window cutout is transparent while background remains filtered", maskIsCorrect)
    overlay.orderOut()
} else {
    check("active-window cutout mask can be created", false)
}

// A new Deep session must not reveal a previous session's CAMetalLayer
// drawable above its freshly captured still frame.
if let screen = NSScreen.main {
    let overlay = OverlayWindowController(screen: screen)
    overlay.configureMetalLayer(device: renderer.device, drawableSize: CGSize(width: W, height: H))
    let hadMetalLayer = overlay.metalLayer != nil
    overlay.prepareForDeep()
    check("new Deep session clears the prior Metal drawable", hadMetalLayer && overlay.metalLayer == nil)
    overlay.orderOut()
} else {
    check("new Deep session can reset its Metal layer", false)
}

func waitForStats(
    rendered: Int,
    skipped: Int,
    bloomPasses: Int? = nil,
    timeout: TimeInterval = 5
) -> (rendered: Int, skipped: Int, bloomPasses: Int) {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        let stats = renderer.debugStats
        if stats.rendered >= rendered,
           stats.skipped >= skipped,
           bloomPasses.map({ stats.bloomPasses >= $0 }) ?? true {
            return stats
        }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
    }
    return renderer.debugStats
}

let skipRect = CGRect(x: 10, y: 10, width: 100, height: 100)

func submit(
    _ pixelBuffer: CVPixelBuffer,
    key: Int,
    filterID: String = DeepFilter.deepID,
    parameters: FilterParameters = DeepFilter.deep.parameters,
    temporalMode: TemporalMode = .live,
    blurRadius: CGFloat = 5,
    skipRect: CGRect = skipRect
) {
    renderer.processFrame(
        pixelBuffer: pixelBuffer,
        blurRadius: blurRadius,
        filterID: filterID,
        parameters: parameters,
        temporalMode: temporalMode,
        metalLayer: metalLayer,
        cacheKey: key,
        skipRect: skipRect,
        completion: { _ in }
    )
}

// Requirement: drawable remains quarter-resolution capture size.
guard let probe = metalLayer.nextDrawable() else {
    print("FATAL: no drawable")
    exit(1)
}
check(
    "drawable size \(probe.texture.width)x\(probe.texture.height) == capture \(W)x\(H)",
    probe.texture.width == W && probe.texture.height == H
)

// Requirement: Swift parameter data matches the Metal uniform layout.
check(
    "FilterParameters stride matches Metal FilterUniforms (112 bytes)",
    MemoryLayout<FilterParameters>.stride == 112
)

// Migration: both legacy visual overrides become a seeded Custom filter, and
// Deep mode stops consulting the old radius key after migration completes.
let migrationSuite = "com.hyperfocus.RendererHarness.migration.\(UUID().uuidString)"
guard let migrationDefaults = UserDefaults(suiteName: migrationSuite) else {
    fatalError("Could not create isolated migration defaults")
}
migrationDefaults.removePersistentDomain(forName: migrationSuite)
migrationDefaults.set(31.0, forKey: DeepSettings.legacyBlurRadiusKey)
migrationDefaults.set(0.45, forKey: DeepSettings.legacySaturationKey)
DeepSettings.migrateIfNeeded(migrationDefaults)
let migrated = DeepSettings.resolve(migrationDefaults)
check(
    "legacy radius and saturation seed Custom Deep settings",
    migrated.filterID == DeepFilter.customID
        && migrated.isCustom
        && migrated.blurRadius == 31.0
        && abs(migrated.parameters.saturation - 0.45) < 0.001
)
migrationDefaults.set(2.0, forKey: DeepSettings.legacyBlurRadiusKey)
let postMigration = DeepSettings.resolve(migrationDefaults)
check(
    "Deep resolution no longer reads the legacy blur-radius key",
    postMigration.blurRadius == 31.0
)
migrationDefaults.removePersistentDomain(forName: migrationSuite)

// Existing GPU-pipeline scenarios, now through the Deep preset.
let key = 42
let deep = DeepFilter.deep
let frameA = makePixelBuffer { _, _ in 128 }!
submit(frameA, key: key, parameters: deep.parameters)
var stats = waitForStats(rendered: 1, skipped: 0)
check("first frame rendered", stats.rendered == 1 && stats.skipped == 0)

submit(frameA, key: key, parameters: deep.parameters)
stats = waitForStats(rendered: 1, skipped: 1)
check("identical frame skipped", stats.rendered == 1 && stats.skipped == 1)

let frameB = makePixelBuffer { _, _ in 128 }!
_ = withModifiedRegion(frameB, rect: skipRect.insetBy(dx: 4, dy: 4), value: 255)
submit(frameB, key: key, parameters: deep.parameters)
stats = waitForStats(rendered: 1, skipped: 2)
check("Deep cutout-only change skipped", stats.rendered == 1 && stats.skipped == 2)

let frameC = makePixelBuffer { _, _ in 128 }!
_ = withModifiedRegion(frameC, rect: CGRect(x: 300, y: 200, width: 8, height: 8), value: 200)
submit(frameC, key: key, parameters: deep.parameters)
stats = waitForStats(rendered: 2, skipped: 2)
check("background change rendered", stats.rendered == 2 && stats.skipped == 2)

submit(frameC, key: key, parameters: deep.parameters, blurRadius: 9)
stats = waitForStats(rendered: 3, skipped: 2)
check("blur setting change forces render", stats.rendered == 3 && stats.skipped == 2)

renderer.clearFrameState(cacheKey: key)
Thread.sleep(forTimeInterval: 0.1)
submit(frameC, key: key, parameters: deep.parameters, blurRadius: 9)
stats = waitForStats(rendered: 4, skipped: 2)
check("clearFrameState forces render", stats.rendered == 4 && stats.skipped == 2)

for _ in 0..<50 {
    submit(frameC, key: key, parameters: deep.parameters, blurRadius: 9)
}
stats = waitForStats(rendered: 4, skipped: 52)
check(
    "steady-state burst fully skipped (rendered=\(stats.rendered), skipped=\(stats.skipped))",
    stats.rendered == 4 && stats.skipped == 52
)

// Accessibility or display changes can briefly yield invalid window geometry.
// The renderer must treat that as no excluded hash region, never trap while
// converting the rect to the shader's unsigned coordinates.
let invalidCutoutKey = 43
let invalidCutoutBefore = renderer.debugStats
submit(
    frameA,
    key: invalidCutoutKey,
    parameters: deep.parameters,
    skipRect: CGRect(
        x: CGFloat.nan,
        y: CGFloat.infinity,
        width: CGFloat.nan,
        height: CGFloat.infinity
    )
)
stats = waitForStats(
    rendered: invalidCutoutBefore.rendered + 1,
    skipped: invalidCutoutBefore.skipped
)
check(
    "non-finite cutout is safely treated as no skipped region",
    stats.rendered == invalidCutoutBefore.rendered + 1
)

// Requirement: every catalog filter destroys desktop-scale text detail.
let textFixture = makeTextFixture()
let sourceEnergy = normalizedGradientEnergy(textFixture.image, edgeMask: textFixture.edgeMask)
// Tuned against the unfiltered desktop-scale fixture. A valid filter must
// pass both the fixed absolute cutoff and remove at least 60% of text-edge
// energy, so a weak effect cannot pass merely because one contrast is sparse.
let legibilityThreshold = 0.05
print(String(format: "INFO: source text gradient energy = %.5f", sourceEnergy))
check("text fixture starts above the legibility threshold", sourceEnergy > legibilityThreshold * 1.5)

let bloomBeforeFilterTests = renderer.debugStats.bloomPasses
for filter in DeepFilter.catalog where filter.id != DeepFilter.bokeh.id {
    let captureRadius = CGFloat(filter.minimumBlurRadius / 4.0)
    guard let output = renderer.processCGImage(
        textFixture.image,
        blurRadius: captureRadius,
        parameters: filter.parameters
    ) else {
        check("\(filter.name) produced an image", false)
        continue
    }
    let energy = normalizedGradientEnergy(output, edgeMask: textFixture.edgeMask)
    print(String(format: "INFO: %@ text gradient energy = %.5f", filter.name, energy))
    check(
        "\(filter.name) makes background text illegible",
        energy < legibilityThreshold && energy < sourceEnergy * 0.40
    )
}
stats = renderer.debugStats
check(
    "All non-Bokeh filters schedule no bloom passes",
    stats.bloomPasses == bloomBeforeFilterTests
)

let bokehCaptureRadius = CGFloat(DeepFilter.bokeh.minimumBlurRadius / 4.0)
guard let bokehOutput = renderer.processCGImage(
    textFixture.image,
    blurRadius: bokehCaptureRadius,
    parameters: DeepFilter.bokeh.parameters
) else {
    print("FATAL: Bokeh did not produce an image")
    exit(1)
}
let bokehEnergy = normalizedGradientEnergy(bokehOutput, edgeMask: textFixture.edgeMask)
print(String(format: "INFO: Bokeh text gradient energy = %.5f", bokehEnergy))
check(
    "Bokeh makes background text illegible",
    bokehEnergy < legibilityThreshold && bokehEnergy < sourceEnergy * 0.40
)
stats = renderer.debugStats
check(
    "Bokeh schedules its bloom stage",
    stats.bloomPasses == bloomBeforeFilterTests + 1
)

// The cutout is punched downstream by the overlay mask. At the renderer
// boundary, `skipRect` must remain hash-only under all filter parameters so
// typing inside the sharp window never schedules an expensive background draw.
for (index, filter) in DeepFilter.catalog.enumerated() {
    let cutoutKey = 700 + index
    let before = renderer.debugStats
    let original = makePixelBuffer { _, _ in 110 }!
    submit(
        original,
        key: cutoutKey,
        filterID: filter.id,
        parameters: filter.parameters,
        blurRadius: CGFloat(filter.minimumBlurRadius / 4.0)
    )
    _ = waitForStats(rendered: before.rendered + 1, skipped: before.skipped)

    let cutoutOnly = makePixelBuffer { _, _ in 110 }!
    _ = withModifiedRegion(cutoutOnly, rect: skipRect.insetBy(dx: 4, dy: 4), value: 240)
    submit(
        cutoutOnly,
        key: cutoutKey,
        filterID: filter.id,
        parameters: filter.parameters,
        blurRadius: CGFloat(filter.minimumBlurRadius / 4.0)
    )
    let final = waitForStats(rendered: before.rendered + 1, skipped: before.skipped + 1)
    check("\(filter.name) cutout-only change skipped", final.rendered == before.rendered + 1 && final.skipped == before.skipped + 1)
}

// Requirement: Frozen ignores changed background content but settings changes
// still force exactly one fresh render.
let frozenKey = 900
let frozenBefore = renderer.debugStats
let frozenA = makePixelBuffer { _, _ in 80 }!
submit(frozenA, key: frozenKey, temporalMode: .frozen)
_ = waitForStats(rendered: frozenBefore.rendered + 1, skipped: frozenBefore.skipped)

let frozenB = makePixelBuffer { _, _ in 80 }!
_ = withModifiedRegion(frozenB, rect: CGRect(x: 280, y: 190, width: 12, height: 12), value: 220)
submit(frozenB, key: frozenKey, temporalMode: .frozen)
_ = waitForStats(rendered: frozenBefore.rendered + 1, skipped: frozenBefore.skipped + 1)

var frozenChangedParameters = DeepFilter.deep.parameters
frozenChangedParameters.contrast = 0.9
submit(
    frozenB,
    key: frozenKey,
    parameters: frozenChangedParameters,
    temporalMode: .frozen
)
_ = waitForStats(rendered: frozenBefore.rendered + 2, skipped: frozenBefore.skipped + 1)

let frozenC = makePixelBuffer { _, _ in 80 }!
_ = withModifiedRegion(frozenC, rect: CGRect(x: 320, y: 210, width: 12, height: 12), value: 230)
submit(
    frozenC,
    key: frozenKey,
    parameters: frozenChangedParameters,
    temporalMode: .frozen
)
stats = waitForStats(rendered: frozenBefore.rendered + 2, skipped: frozenBefore.skipped + 2)
check(
    "Frozen skips changes and renders exactly once after a parameter change",
    stats.rendered == frozenBefore.rendered + 2 && stats.skipped == frozenBefore.skipped + 2
)

// Requirement: Settled coalesces a burst of changes for five seconds.
let settledKey = 901
let settledBefore = renderer.debugStats
let settledA = makePixelBuffer { _, _ in 70 }!
submit(settledA, key: settledKey, temporalMode: .settled)
_ = waitForStats(rendered: settledBefore.rendered + 1, skipped: settledBefore.skipped)

for (offset, value) in [0, 1, 2].enumerated() {
    let changed = makePixelBuffer { _, _ in 70 }!
    _ = withModifiedRegion(
        changed,
        rect: CGRect(x: CGFloat(260 + offset * 10), y: 180, width: 8, height: 8),
        value: UInt8(150 + value * 20)
    )
    submit(changed, key: settledKey, temporalMode: .settled)
    _ = waitForStats(rendered: settledBefore.rendered + 1, skipped: settledBefore.skipped + offset + 1)
}

Thread.sleep(forTimeInterval: TemporalMode.settledInterval + 0.2)
let settledAfterGate = makePixelBuffer { _, _ in 70 }!
_ = withModifiedRegion(settledAfterGate, rect: CGRect(x: 300, y: 180, width: 8, height: 8), value: 245)
submit(settledAfterGate, key: settledKey, temporalMode: .settled)
stats = waitForStats(rendered: settledBefore.rendered + 2, skipped: settledBefore.skipped + 3)
check(
    "Settled coalesces rapid changes to one render per five-second interval",
    stats.rendered == settledBefore.rendered + 2 && stats.skipped == settledBefore.skipped + 3
)

// Requirement: Paper grain is static for a static source. `processCGImage`
// gives a direct readback path without involving the window compositor.
guard let paperFirst = renderer.processCGImage(
    textFixture.image,
    blurRadius: CGFloat(DeepFilter.paper.minimumBlurRadius / 4.0),
    parameters: DeepFilter.paper.parameters
), let paperSecond = renderer.processCGImage(
    textFixture.image,
    blurRadius: CGFloat(DeepFilter.paper.minimumBlurRadius / 4.0),
    parameters: DeepFilter.paper.parameters
) else {
    print("FATAL: Paper did not produce an image")
    exit(1)
}
check(
    "Paper static frame is pixel-identical across repeated renders",
    bgraBytes(from: paperFirst) == bgraBytes(from: paperSecond)
)

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURES")
exit(failures == 0 ? 0 : 1)
