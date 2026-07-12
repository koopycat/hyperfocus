import Cocoa
import ScreenCaptureKit
import Metal

/// Single rendering engine for Hyperfocus.
///
/// Captures each display at quarter resolution via ScreenCaptureKit, runs the
/// frames through `MetalBlurRenderer` (fused Gaussian blur + BT.709
/// desaturation + bilinear upscale), and hands the result to the matching
/// overlay. Each overlay's own window is excluded from capture to prevent
/// feedback flicker.
///
/// Requires Screen Recording permission (prompted on first activation).
final class BlurEngine: NSObject, SCStreamOutput {
    private var streams: [CGDirectDisplayID: SCStream] = [:]
    private var renderer: MetalBlurRenderer?
    private var displayOverlays: [CGDirectDisplayID: OverlayWindowController] = [:]
    private var displaySizes: [CGDirectDisplayID: CGSize] = [:]

    /// Guards the permission-denied alert so it is shown at most once per session
    /// (avoids spamming across multi-display attach / reconfigure cycles).
    private var permissionDeniedReported = false

    /// Cached Screen Recording permission verdict for this session.
    /// Resolved exactly once; subsequent toggles reuse it so the system
    /// prompt never reappears within the same process lifetime.
    private enum ScreenCapturePermission { case unknown, granted, denied }
    private var screenCapturePermission: ScreenCapturePermission = .unknown

    // Settings (updated live from the UI).
    private var blurRadius: CGFloat = 20
    private var saturation: CGFloat = 0.0

    override init() {
        super.init()
        self.renderer = MetalBlurRenderer()
    }

    // MARK: - Lifecycle

    func attach(to overlay: OverlayWindowController, displayID: CGDirectDisplayID) {
        NSLog("[Hyperfocus] attach display \(displayID)")
        displayOverlays[displayID] = overlay
        Task {
            guard await requestPermissionIfNeeded() else { return }

            // Show a blurred still screenshot immediately so activation
            // feels instant; the live stream blends over the top.
            await captureStillScreenshot(for: displayID, overlay: overlay)
            await startCapture(for: displayID, overlay: overlay)
        }
    }

    func updateSettings(blurRadius: CGFloat, saturation: CGFloat) {
        self.blurRadius = blurRadius
        self.saturation = saturation
    }

    func detach(from displayID: CGDirectDisplayID) {
        Task { await stopCapture(for: displayID) }
        displayOverlays.removeValue(forKey: displayID)
        displaySizes.removeValue(forKey: displayID)
    }

    func detachAll() {
        let ids = Array(streams.keys)
        Task {
            for id in ids { await stopCapture(for: id) }
        }
        displayOverlays.removeAll()
        displaySizes.removeAll()
    }

    // MARK: - Screen Recording Permission

    /// Resolves Screen Recording permission exactly once per session and
    /// caches the result. Subsequent toggles reuse the cached verdict, so
    /// the system prompt can never reappear on every toggle.
    func requestPermissionIfNeeded() async -> Bool {
        switch screenCapturePermission {
        case .granted:
            NSLog("[Hyperfocus] SC permission: cached granted")
            return true
        case .denied:
            NSLog("[Hyperfocus] SC permission: cached denied")
            await presentPermissionDeniedAlert()
            return false
        case .unknown:
            break
        }

        let granted = await resolvePermission()
        screenCapturePermission = granted ? .granted : .denied
        NSLog("[Hyperfocus] SC permission resolved this session: \(granted ? "GRANTED" : "DENIED")")
        if !granted { await presentPermissionDeniedAlert() }
        return granted
    }

    /// Performs the one-time permission probe. Preflight first (no prompt);
    /// only if that is missing does it ask the system, which shows the
    /// single user-facing prompt at most once per app lifetime.
    private func resolvePermission() async -> Bool {
        let preflight = CGPreflightScreenCaptureAccess()
        NSLog("[Hyperfocus] SC preflight (already-granted?): \(preflight)")
        if preflight { return true }

        let requested = CGRequestScreenCaptureAccess()
        NSLog("[Hyperfocus] SC request result: \(requested)")
        if requested { return true }

        // CGRequestScreenCaptureAccess returns false for both "denied" and
        // "undetermined-but-no-prompt-this-call". Probe SCShareableContent
        // to distinguish: empty displays ⇒ truly denied.
        do {
            let content = try await SCShareableContent.current
            if content.displays.isEmpty {
                NSLog("[Hyperfocus] SC shareable content: no displays ⇒ denied")
                return false
            }
            NSLog("[Hyperfocus] SC shareable content: \(content.displays.count) displays ⇒ granted")
            return true
        } catch {
            NSLog("[Hyperfocus] SC shareable content error: \(error)")
            return false
        }
    }

    @MainActor
    private func presentPermissionDeniedAlert() {
        guard !permissionDeniedReported else { return }
        permissionDeniedReported = true

        let alert = NSAlert()
        alert.messageText = "Screen Recording Permission Required"
        alert.informativeText = """
            Hyperfocus needs Screen Recording access to blur the area behind your \
            active window. Grant access in System Settings ▸ Privacy & Security ▸ \
            Screen Recording, then quit and relaunch Hyperfocus.
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Dismiss")

        if alert.runModal() == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    // MARK: - Still Screenshot Boot

    /// Capture a single still image of the display, blur it, and push it to
    /// the overlay before the live stream delivers its first frame.
    private func captureStillScreenshot(for displayID: CGDirectDisplayID, overlay: OverlayWindowController) async {
        do {
            let content = try await SCShareableContent.current
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else { return }

            // Exclude the overlay window from its own capture.
            let excludedWindows = content.windows.filter { $0.windowID == overlay.windowNumber }
            let filter = SCContentFilter(display: display, excludingWindows: excludedWindows)

            let screenshotConfig = SCStreamConfiguration()
            screenshotConfig.width = Int(display.width) / 4
            screenshotConfig.height = Int(display.height) / 4
            screenshotConfig.pixelFormat = kCVPixelFormatType_32BGRA
            if #available(macOS 13.0, *) { screenshotConfig.capturesAudio = false }

            let cgImage: CGImage?
            if #available(macOS 14.0, *) {
                cgImage = try await SCScreenshotManager.captureImage(
                    contentFilter: filter,
                    configuration: screenshotConfig
                )
            } else {
                cgImage = await captureStillFrameFallback(filter: filter, configuration: screenshotConfig)
            }

            if let image = cgImage {
                if let processed = renderer?.processCGImage(image, blurRadius: blurRadius, saturation: saturation) {
                    overlay.applyImage(processed)
                } else {
                    overlay.applyImage(image)
                }
            }
        } catch {
            print("[Hyperfocus] Still screenshot failed for display \(displayID): \(error)")
        }
    }

    /// Fallback for macOS < 14.0: spin up a transient SCStream, take its
    /// first frame, tear it down. The stream is not added to `self.streams`.
    private func captureStillFrameFallback(
        filter: SCContentFilter,
        configuration: SCStreamConfiguration
    ) async -> CGImage? {
        let collector = StillFrameCollector()
        do {
            let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
            try stream.addStreamOutput(collector, type: .screen, sampleHandlerQueue: DispatchQueue.main)
            try await stream.startCapture()
            let image = await collector.waitForFrame(timeout: 1.0)
            try? await stream.stopCapture()
            return image
        } catch {
            print("[Hyperfocus] Still frame fallback failed: \(error)")
            return nil
        }
    }

    // MARK: - Capture Management

    private func startCapture(for displayID: CGDirectDisplayID, overlay: OverlayWindowController) async {
        do {
            let content = try await SCShareableContent.current
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else { return }

            displaySizes[displayID] = CGSize(width: CGFloat(display.width), height: CGFloat(display.height))

            let excludedWindows = content.windows.filter { $0.windowID == overlay.windowNumber }
            let filter = SCContentFilter(display: display, excludingWindows: excludedWindows)

            let config = SCStreamConfiguration()
            config.width = Int(display.width) / 4   // quarter resolution
            config.height = Int(display.height) / 4
            config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            config.showsCursor = false
            if #available(macOS 13.0, *) { config.capturesAudio = false }
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.queueDepth = 3

            let stream = SCStream(filter: filter, configuration: config, delegate: nil)
            try stream.addStreamOutput(self, type: SCStreamOutputType.screen, sampleHandlerQueue: DispatchQueue.main)
            try await stream.startCapture()

            streams[displayID] = stream
        } catch {
            print("[Hyperfocus] Failed to start capture for display \(displayID): \(error)")
        }
    }

    private func stopCapture(for displayID: CGDirectDisplayID) async {
        guard let stream = streams[displayID] else { return }
        try? await stream.stopCapture()
        streams.removeValue(forKey: displayID)
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let pixelBuffer = sampleBuffer.imageBuffer,
              let displayID = streams.first(where: { $0.value === stream })?.key,
              let overlay = displayOverlays[displayID]
        else { return }

        let outputSize = displaySizes[displayID] ?? CGSize(
            width: CGFloat(CVPixelBufferGetWidth(pixelBuffer) * 4),
            height: CGFloat(CVPixelBufferGetHeight(pixelBuffer) * 4)
        )

        if let cgImage = renderer?.processFrame(
            pixelBuffer: pixelBuffer,
            blurRadius: blurRadius,
            saturation: saturation,
            outputSize: outputSize
        ) {
            overlay.applyImage(cgImage)
        }
    }
}

// MARK: - Still Frame Collector

/// One-shot `SCStreamOutput` used by the still-screenshot fallback path.
private final class StillFrameCollector: NSObject, SCStreamOutput, @unchecked Sendable {
    private var continuation: CheckedContinuation<CGImage?, Never>?
    private var done = false

    func waitForFrame(timeout: TimeInterval) async -> CGImage? {
        await withCheckedContinuation { (cont: CheckedContinuation<CGImage?, Never>) in
            self.continuation = cont
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self = self, !self.done else { return }
                self.done = true
                self.continuation?.resume(returning: nil)
                self.continuation = nil
            }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !done, type == .screen, let pixelBuffer = sampleBuffer.imageBuffer else { return }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext(options: nil)
        guard let cg = context.createCGImage(ciImage, from: ciImage.extent) else { return }

        done = true
        continuation?.resume(returning: cg)
        continuation = nil
    }
}
