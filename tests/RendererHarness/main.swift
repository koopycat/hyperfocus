import Cocoa
import Metal
import QuartzCore

// End-to-end harness for the reworked Deep-mode pipeline.
// Drives the REAL MetalBlurRenderer with synthetic frames through a real
// CAMetalLayer and asserts the change-detection and drawable behavior.

let W = 640
let H = 360

func makePixelBuffer(fill: (_ x: Int, _ y: Int) -> UInt8) -> CVPixelBuffer? {
    var pb: CVPixelBuffer?
    let attrs: [CFString: Any] = [
        kCVPixelBufferMetalCompatibilityKey: true,
        kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
    ]
    guard CVPixelBufferCreate(kCFAllocatorDefault, W, H, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb) == kCVReturnSuccess,
          let buffer = pb else { return nil }
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
            p[0] = value; p[1] = value; p[2] = value; p[3] = 255
        }
    }
    CVPixelBufferUnlockBaseAddress(base, [])
    return base
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

// Verify drawable now matches capture size (the P0 fix).
guard let probe = metalLayer.nextDrawable() else {
    print("FATAL: no drawable")
    exit(1)
}
let drawableOK = probe.texture.width == W && probe.texture.height == H
print("\(drawableOK ? "PASS" : "FAIL"): drawable size \(probe.texture.width)x\(probe.texture.height) == capture \(W)x\(H)")

var failures = 0
func check(_ name: String, _ cond: Bool) {
    print("\(cond ? "PASS" : "FAIL"): \(name)")
    if !cond { failures += 1 }
}

func waitForStats(rendered: Int, skipped: Int, timeout: TimeInterval = 5) -> (rendered: Int, skipped: Int) {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        let s = renderer.debugStats
        if s.rendered >= rendered && s.skipped >= skipped { return s }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
    }
    return renderer.debugStats
}

let key = 42
let skipRect = CGRect(x: 10, y: 10, width: 100, height: 100)

// Scenario 1: first frame must render.
let frameA = makePixelBuffer { _, _ in 128 }!
renderer.processFrame(pixelBuffer: frameA, blurRadius: 5, saturation: 0.0,
                      metalLayer: metalLayer, cacheKey: key, skipRect: skipRect) {}
var s = waitForStats(rendered: 1, skipped: 0)
check("first frame rendered", s.rendered == 1 && s.skipped == 0)

// Scenario 2: identical frame must be skipped.
renderer.processFrame(pixelBuffer: frameA, blurRadius: 5, saturation: 0.0,
                      metalLayer: metalLayer, cacheKey: key, skipRect: skipRect) {}
s = waitForStats(rendered: 1, skipped: 1)
check("identical frame skipped", s.rendered == 1 && s.skipped == 1)

// Scenario 3: change INSIDE the cutout must be skipped (focused window is live).
let frameB = makePixelBuffer { _, _ in 128 }!
_ = withModifiedRegion(frameB, rect: skipRect.insetBy(dx: 4, dy: 4), value: 255)
renderer.processFrame(pixelBuffer: frameB, blurRadius: 5, saturation: 0.0,
                      metalLayer: metalLayer, cacheKey: key, skipRect: skipRect) {}
s = waitForStats(rendered: 1, skipped: 2)
check("cutout-only change skipped", s.rendered == 1 && s.skipped == 2)

// Scenario 4: change OUTSIDE the cutout must render.
let frameC = makePixelBuffer { _, _ in 128 }!
_ = withModifiedRegion(frameC, rect: CGRect(x: 300, y: 200, width: 8, height: 8), value: 200)
renderer.processFrame(pixelBuffer: frameC, blurRadius: 5, saturation: 0.0,
                      metalLayer: metalLayer, cacheKey: key, skipRect: skipRect) {}
s = waitForStats(rendered: 2, skipped: 2)
check("background change rendered", s.rendered == 2 && s.skipped == 2)

// Scenario 5: same pixels, changed settings must render.
renderer.processFrame(pixelBuffer: frameC, blurRadius: 9, saturation: 0.0,
                      metalLayer: metalLayer, cacheKey: key, skipRect: skipRect) {}
s = waitForStats(rendered: 3, skipped: 2)
check("settings change forces render", s.rendered == 3 && s.skipped == 2)

// Scenario 6: clearFrameState forces a render even with identical pixels.
renderer.clearFrameState(cacheKey: key)
Thread.sleep(forTimeInterval: 0.1) // let the clear land on stateQueue
renderer.processFrame(pixelBuffer: frameC, blurRadius: 9, saturation: 0.0,
                      metalLayer: metalLayer, cacheKey: key, skipRect: skipRect) {}
s = waitForStats(rendered: 4, skipped: 2)
check("clearFrameState forces render", s.rendered == 4 && s.skipped == 2)

// Scenario 7: burst of 50 identical frames --> all skipped (steady-state cost ~= 0).
for _ in 0..<50 {
    renderer.processFrame(pixelBuffer: frameC, blurRadius: 9, saturation: 0.0,
                          metalLayer: metalLayer, cacheKey: key, skipRect: skipRect) {}
}
s = waitForStats(rendered: 4, skipped: 52)
check("steady-state burst fully skipped (rendered=\(s.rendered), skipped=\(s.skipped))",
      s.rendered == 4 && s.skipped == 52)

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURES")
exit(failures == 0 ? 0 : 1)
