import Cocoa
import ScreenCaptureKit
import Metal
import QuartzCore

private struct LiveRenderInput: @unchecked Sendable {
    /// ScreenCaptureKit owns the IOSurface-backed buffer until the renderer
    /// completes, and CAMetalLayer is used only for nextDrawable/present on
    /// the render queue. The wrapper documents that intentional handoff.
    let pixelBuffer: CVPixelBuffer
    let metalLayer: CAMetalLayer
}

/// Single rendering engine for Hyperfocus.
///
/// Captures each display at quarter resolution via ScreenCaptureKit, runs the
/// frames through `MetalBlurRenderer` (MPS 2D Gaussian blur + parameterized
/// post-processing), and composites the result directly into the overlay's
/// `CAMetalLayer` -- no CPU readback. Core Animation enlarges the
/// low-resolution result from the drawable while compositing, avoiding a
/// full-display render pass.
/// Each overlay's own window is excluded from capture to prevent feedback flicker.
///
/// Requires Screen Recording permission (prompted on first activation).
///
/// All mutable state is confined to the main queue. The ScreenCaptureKit
/// callback only forwards a pixel buffer there, while Metal work is confined
/// to `renderQueue`.
final class BlurEngine: NSObject, SCStreamOutput, @unchecked Sendable {
    private var streams: [CGDirectDisplayID: SCStream] = [:]
    private var renderer: MetalBlurRenderer?
    private var displayOverlays: [CGDirectDisplayID: OverlayWindowController] = [:]

    /// Invalidates pending permission, still-frame, and stream-start tasks
    /// when a focus session ends. Without this, an async teardown can stop a
    /// freshly-created replacement stream for the same display.
    private var captureGeneration: UInt = 0

    /// Frame rate for ScreenCaptureKit streams. User-configurable in
    /// Settings → Effects; defaults to 10 for a good energy/smoothness
    /// balance on most Macs. `integer(forKey:)` returns 0 when the key was
    /// never written (fresh install), so map 0 to the default instead of
    /// clamping to 1 FPS.
    private var framesPerSecond: Int32 {
        Int32(DeepSettings.sanitizedFramesPerSecond(
            UserDefaults.standard.integer(forKey: "blurFPS")
        ))
    }

    private let captureScale: CGFloat = 4
    private let maximumCaptureBlurRadius: CGFloat = 12
    private let sampleHandlerQueue = DispatchQueue(
        label: "com.hyperfocus.capture",
        qos: .utility
    )
    private let renderQueue = DispatchQueue(
        label: "com.hyperfocus.blur-render",
        qos: .utility
    )

    /// Accessed only from the main queue. At most one render per display may
    /// be in flight, so slow GPUs drop obsolete frames instead of building a
    /// queue that increases latency and energy use.
    private var renderingDisplays: Set<CGDirectDisplayID> = []

    /// Main-queue confined. While true, captured frames are dropped before any
    /// Metal work is scheduled. Used when every overlay is invisible (window
    /// drag, mouse left the focused window, excluded app frontmost): the
    /// capture keeps running for instant resume, but no GPU render, present,
    /// or WindowServer recomposite happens for content nobody can see.
    private var renderingPaused = false

    /// Guards the permission-denied alert so it is shown at most once per session
    /// (avoids spamming across multi-display attach / reconfigure cycles).
    private var permissionDeniedReported = false

    /// Cached Screen Recording permission verdict. Only the granted state is
    /// cached; denied is not cached so that a user who grants permission in
    /// System Settings while the app is running can activate Deep mode on the
    /// next toggle without having to relaunch.
    private var screenCapturePermissionGranted = false

    // Resolved Deep-mode settings, updated live from the UI. `filterID` is
    // retained in addition to its parameters so selecting a named preset
    // always forces a frame even when its values happen to match Custom.
    private var activeFilterID = DeepFilter.deepID
    private var blurRadius: CGFloat = 20
    private var filterParameters = DeepFilter.deep.parameters
    private var temporalMode: TemporalMode = .live
    /// Monotonic configuration generation captured with each submitted frame.
    /// It lets AppDelegate wait for the exact new-filter frame before fading
    /// an overlay back in, rather than exposing the previous drawable.
    private var filterRevision: UInt = 0

    /// Called on the main queue after a frame is successfully presented.
    /// The revision identifies the settings snapshot that generated it.
    var onFramePresented: ((CGDirectDisplayID, UInt) -> Void)?

    /// Thermal/power-aware frame rate. If the system is in low-power mode,
    /// on battery, or under thermal pressure, we cap the user-selected rate to
    /// keep Deep mode from worsening the situation. The stream is restarted
    /// when the effective rate changes, so this adapts live.
    private var effectiveFramesPerSecond: Int32 {
        let user = framesPerSecond
        let processInfo = ProcessInfo.processInfo

        if ProcessInfo.processInfo.isLowPowerModeEnabled {
            return max(1, min(user, 10))
        }

        switch processInfo.thermalState {
        case .serious, .critical:
            return max(1, min(user, 5))
        case .fair:
            return max(1, min(user, 15))
        default:
            return user
        }
    }

    private var lastEffectiveFramesPerSecond: Int32 = -1
    static let thermalThrottlingChanged = Notification.Name("com.hyperfocus.thermalThrottlingChanged")

    override init() {
        super.init()
        self.renderer = MetalBlurRenderer()
        self.lastEffectiveFramesPerSecond = effectiveFramesPerSecond
        registerThermalAndPowerObservers()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func registerThermalAndPowerObservers() {
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(thermalOrPowerStateChanged),
            name: ProcessInfo.thermalStateDidChangeNotification,
            object: nil
        )
        // Low-power mode on macOS does not always expose a typed Swift
        // constant, so use the raw Foundation notification string.
        center.addObserver(
            self,
            selector: #selector(thermalOrPowerStateChanged),
            name: Notification.Name("NSProcessInfoPowerStateDidChangeNotification"),
            object: nil
        )
    }

    @objc private func thermalOrPowerStateChanged() {
        // ProcessInfo posts this notification from a worker queue. The
        // resulting session restart creates and orders AppKit windows, so both
        // state comparison and notification delivery must happen on main.
        DispatchQueue.main.async { [weak self] in
            self?.applyThermalOrPowerStateChange()
        }
    }

    private func applyThermalOrPowerStateChange() {
        dispatchPrecondition(condition: .onQueue(.main))
        let newFPS = effectiveFramesPerSecond
        guard newFPS != lastEffectiveFramesPerSecond else { return }
        lastEffectiveFramesPerSecond = newFPS
        NSLog("[Hyperfocus] Thermal/power change: effective FPS now \(newFPS)")
        NotificationCenter.default.post(
            name: Self.thermalThrottlingChanged,
            object: nil
        )
    }

    // MARK: - Lifecycle

    @MainActor
    func attach(to overlay: OverlayWindowController, displayID: CGDirectDisplayID) {
        NSLog("[Hyperfocus] attach display \(displayID)")
        displayOverlays[displayID] = overlay

        // Configure the Metal layer before any rendering starts so the
        // still-screenshot boot frame and live stream share the same surface.
        // The drawable must be sized to the quarter-res capture; a full-size
        // drawable would leave 94% of every presented texture as stale garbage
        // and cost 16x the drawable memory.
        if let device = renderer?.device {
            overlay.configureMetalLayer(
                device: device,
                drawableSize: capturePixelSize(for: displayID)
            )
        }

        let generation = captureGeneration
        Task { @MainActor [weak self] in
            guard let self, self.captureGeneration == generation else { return }
            guard await self.requestPermissionIfNeeded(for: generation),
                  self.captureGeneration == generation
            else { return }

            // A single content snapshot covers both the boot screenshot and
            // the stream filter. The overlay window is already on-screen (the
            // AppDelegate shows it before attaching), so its windowNumber is
            // visible in this snapshot and can be excluded reliably.
            let content = await self.fetchShareableContent()
            guard self.captureGeneration == generation else { return }
            guard let content = content, !content.displays.isEmpty else {
                NSLog("[Hyperfocus] Shareable content empty after permission grant for display \(displayID)")
                self.presentPermissionDeniedAlert()
                return
            }

            // Show a blurred still screenshot immediately so activation
            // feels instant; the live stream blends over the top.
            await self.captureStillScreenshot(
                for: displayID,
                overlay: overlay,
                generation: generation,
                content: content
            )
            guard self.captureGeneration == generation else { return }
            await self.startCapture(
                for: displayID,
                overlay: overlay,
                generation: generation,
                content: content
            )
        }
    }

    /// Applies the settings resolved at the AppDelegate -> renderer boundary.
    /// The Metal renderer compares these values against the visible frame and
    /// forces exactly one redraw when a filter, parameter, or temporal mode
    /// changes, including while Frozen mode is active.
    @MainActor
    @discardableResult
    func updateFilter(
        filterID: String,
        blurRadius: CGFloat,
        parameters: FilterParameters,
        temporalMode: TemporalMode
    ) -> UInt {
        let changed = activeFilterID != filterID
            || self.blurRadius != blurRadius
            || filterParameters != parameters
            || self.temporalMode != temporalMode
        activeFilterID = filterID
        self.blurRadius = blurRadius
        filterParameters = parameters
        self.temporalMode = temporalMode
        if changed { filterRevision &+= 1 }
        return filterRevision
    }

    /// Suspends or resumes GPU rendering for all displays. Capture streams
    /// keep running (cheap, and resume is instant); only the Metal render and
    /// drawable present are skipped.
    @MainActor
    func setRenderingPaused(_ paused: Bool) {
        renderingPaused = paused
    }

    @MainActor
    func detach(from displayID: CGDirectDisplayID) {
        let stream = streams.removeValue(forKey: displayID)
        displayOverlays.removeValue(forKey: displayID)
        renderingDisplays.remove(displayID)
        renderer?.clearFrameState(cacheKey: Int(displayID))
        if let stream {
            Task { try? await stream.stopCapture() }
        }
    }

    @MainActor
    func detachAll() {
        captureGeneration &+= 1
        let streamsToStop = Array(streams.values)
        let displayIDs = Array(streams.keys)
        streams.removeAll()
        displayOverlays.removeAll()
        renderingDisplays.removeAll()
        for displayID in displayIDs {
            renderer?.clearFrameState(cacheKey: Int(displayID))
        }
        Task {
            for stream in streamsToStop {
                try? await stream.stopCapture()
            }
        }
    }

    /// Returns the current shareable content. This is the expensive TCC IPC
    /// call that enumerates displays and windows; call it as few times as
    /// possible per activation.
    private func fetchShareableContent() async -> SCShareableContent? {
        try? await SCShareableContent.current
    }

    // MARK: - Screen Recording Permission

    /// Resolves Screen Recording permission. Always re-checks the current TCC
    /// state via `SCShareableContent.current` (no prompt) so a user who grants
    /// permission in System Settings while Hyperfocus is running can use Deep
    /// mode without relaunching. Only the granted state is cached.
    @MainActor
    private func requestPermissionIfNeeded(for generation: UInt) async -> Bool {
        guard captureGeneration == generation else { return false }
        if screenCapturePermissionGranted {
            NSLog("[Hyperfocus] SC permission: cached granted")
            return true
        }

        let granted = await resolvePermission(for: generation)
        guard captureGeneration == generation else { return false }
        screenCapturePermissionGranted = granted
        NSLog("[Hyperfocus] SC permission resolved this session: \(granted ? "GRANTED" : "DENIED")")
        if !granted { presentPermissionDeniedAlert() }
        return granted
    }

    /// Checks permission via `SCShareableContent.current` (no prompt). Only
    /// falls back to `CGRequestScreenCaptureAccess` on the very first attempt
    /// in this app install's lifetime -- tracked via UserDefaults to ensure at
    /// most one system prompt ever appears. If the user has already been
    /// prompted and denied, subsequent calls return immediately after the
    /// prompt-free check, so granting permission in System Settings is picked
    /// up on the next toggle without a relaunch.
    @MainActor
    private func resolvePermission(for generation: UInt) async -> Bool {
        let hasPromptedKey = "SCScreenCapturePermissionPrompted"
        guard captureGeneration == generation else { return false }

        // SCShareableContent is the authoritative, prompt-free check.
        // Re-check every time so a mid-session Settings grant is honored.
        if let granted = await checkShareableContent(), granted {
            return captureGeneration == generation
        }
        guard captureGeneration == generation else { return false }

        // First failure: if we've never prompted before, ask once.
        if !UserDefaults.standard.bool(forKey: hasPromptedKey) {
            UserDefaults.standard.set(true, forKey: hasPromptedKey)
            let requested = CGRequestScreenCaptureAccess()
            NSLog("[Hyperfocus] SC one-time request result: \(requested)")
            if requested { return captureGeneration == generation }
            // The prompt was shown but the user may still be deciding, or the
            // TCC database has not updated yet. Give it a short moment and
            // re-check once.
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard captureGeneration == generation else { return false }
            if let granted = await checkShareableContent() {
                return granted && captureGeneration == generation
            }
        }

        return false
    }

    /// Returns `true` if shareable content enumerates displays, `false` if
    /// empty (truly denied), or `nil` if the call timed out or errored.
    private func checkShareableContent() async -> Bool? {
        do {
            let content = try await SCShareableContent.current
            let granted = !content.displays.isEmpty
            NSLog("[Hyperfocus] SC shareable content: \(content.displays.count) displays ⇒ \(granted ? "granted" : "denied")")
            return granted
        } catch {
            NSLog("[Hyperfocus] SC shareable content error: \(error)")
            return nil
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
            Screen Recording, then toggle Hyperfocus off and back on.
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
    ///
    /// Uses the CGImage path (applyImage) for the one-shot boot frame;
    /// the CPU readback cost is negligible for a single shot.
    ///
    /// - Parameter content: Optional pre-fetched shareable content so the
    ///   activation path does not fetch it twice.
    @MainActor
    private func captureStillScreenshot(
        for displayID: CGDirectDisplayID,
        overlay: OverlayWindowController,
        generation: UInt,
        content: SCShareableContent? = nil
    ) async {
        do {
            let resolvedContent: SCShareableContent?
            if let content = content {
                resolvedContent = content
            } else {
                resolvedContent = await fetchShareableContent()
            }
            guard let resolvedContent = resolvedContent else { return }
            guard captureGeneration == generation else { return }
            guard let display = resolvedContent.displays.first(where: { $0.displayID == displayID }) else { return }

            // Exclude the overlay window from its own capture.
            let excludedWindows = resolvedContent.windows.filter { $0.windowID == overlay.windowNumber }
            let filter = SCContentFilter(display: display, excludingWindows: excludedWindows)

            let screenshotConfig = SCStreamConfiguration()
            screenshotConfig.width = captureDimension(display.width)
            screenshotConfig.height = captureDimension(display.height)
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
                guard captureGeneration == generation else { return }
                let overlayIdentifier = ObjectIdentifier(overlay)
                let processed = await renderStillImage(
                    image,
                    renderer: renderer,
                    blurRadius: captureSpaceBlurRadius,
                    parameters: renderParameters
                )
                let imageToApply = processed ?? image
                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          self.captureGeneration == generation,
                          let currentOverlay = self.displayOverlays[displayID],
                          ObjectIdentifier(currentOverlay) == overlayIdentifier
                    else { return }
                    currentOverlay.applyImage(imageToApply)
                    if !self.renderingPaused {
                        currentOverlay.revealDeepFrame()
                    }
                }
            }
        } catch {
            print("[Hyperfocus] Still screenshot failed for display \(displayID): \(error)")
        }
    }

    /// Fallback for macOS < 14.0: spin up a transient SCStream, take its
    /// first frame, tear it down. The stream is not added to `self.streams`.
    @MainActor
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

    @MainActor
    private func startCapture(
        for displayID: CGDirectDisplayID,
        overlay: OverlayWindowController,
        generation: UInt,
        content: SCShareableContent? = nil
    ) async {
        // Record the effective FPS actually used for this stream so thermal
        // change notifications compare against the live setting, not a stale
        // baseline from before the last user edit.
        lastEffectiveFramesPerSecond = effectiveFramesPerSecond

        var streamToStart: SCStream?
        do {
            let resolvedContent: SCShareableContent?
            if let content = content {
                resolvedContent = content
            } else {
                resolvedContent = await fetchShareableContent()
            }
            guard let resolvedContent = resolvedContent else { return }
            guard captureGeneration == generation else { return }
            guard let display = resolvedContent.displays.first(where: { $0.displayID == displayID }) else { return }

            let excludedWindows = resolvedContent.windows.filter { $0.windowID == overlay.windowNumber }
            let filter = SCContentFilter(display: display, excludingWindows: excludedWindows)

            let config = SCStreamConfiguration()
            config.width = captureDimension(display.width)
            config.height = captureDimension(display.height)
            config.minimumFrameInterval = CMTime(value: 1, timescale: effectiveFramesPerSecond)
            config.showsCursor = false
            if #available(macOS 13.0, *) { config.capturesAudio = false }
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.queueDepth = 2

            let stream = SCStream(filter: filter, configuration: config, delegate: nil)
            streamToStart = stream
            try stream.addStreamOutput(self, type: SCStreamOutputType.screen, sampleHandlerQueue: sampleHandlerQueue)
            guard captureGeneration == generation else { return }
            streams[displayID] = stream
            try await stream.startCapture()
            guard captureGeneration == generation else {
                if streams[displayID] === stream {
                    streams.removeValue(forKey: displayID)
                }
                try? await stream.stopCapture()
                return
            }
        } catch {
            guard captureGeneration == generation else {
                try? await streamToStart?.stopCapture()
                return
            }
            if let streamToStart, streams[displayID] === streamToStart {
                streams.removeValue(forKey: displayID)
            }
            NSLog("[Hyperfocus] Failed to start capture for display \(displayID): \(error)")
            self.presentStreamFailureAlert(displayID: displayID, error: error)
        }
    }

    // MARK: - Alerts

    @MainActor
    private func presentStreamFailureAlert(displayID: CGDirectDisplayID, error: Error) {
        let alert = NSAlert()
        alert.messageText = "Could Not Start Blur Stream"
        alert.informativeText = """
            Hyperfocus could not start the ScreenCaptureKit stream for display \"(displayID)\". \
            Make sure Screen Recording access is still granted in System Settings ▸ \
            Privacy & Security ▸ Screen Recording. Error: \\(error.localizedDescription)
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

    // MARK: - Frame scheduling

    private func captureDimension(_ dimension: Int) -> Int {
        max(1, Int(CGFloat(dimension) / captureScale))
    }

    /// Pixel size of the quarter-res capture for a display, derived from
    /// CoreGraphics display info so it is available synchronously at attach
    /// time (before the first SCShareableContent fetch resolves).
    private func capturePixelSize(for displayID: CGDirectDisplayID) -> CGSize {
        CGSize(
            width: captureDimension(CGDisplayPixelsWide(displayID)),
            height: captureDimension(CGDisplayPixelsHigh(displayID))
        )
    }

    /// Settings are expressed in display pixels, while Metal receives a
    /// quarter-resolution image. Scaling and capping the radius preserves the
    /// intended visual blur without paying for an oversized convolution.
    private var captureSpaceBlurRadius: CGFloat {
        min(maximumCaptureBlurRadius, max(0, blurRadius / captureScale))
    }

    /// Thermal or low-power pressure suppresses bloom. The rest of the
    /// selected filter stays intact, so Bokeh degrades gracefully rather than
    /// spending an extra two passes when the system has asked us to be
    /// conservative. This checks the state itself rather than comparing FPS,
    /// because a user may already have chosen a rate below the cap.
    private var renderParameters: FilterParameters {
        var parameters = filterParameters
        let processInfo = ProcessInfo.processInfo
        if processInfo.isLowPowerModeEnabled || processInfo.thermalState != .nominal {
            parameters.bloomAmount = 0
        }
        return parameters
    }

    private func renderStillImage(
        _ image: CGImage,
        renderer: MetalBlurRenderer?,
        blurRadius: CGFloat,
        parameters: FilterParameters
    ) async -> CGImage? {
        await withCheckedContinuation { continuation in
            renderQueue.async {
                continuation.resume(
                    returning: renderer?.processCGImage(
                        image,
                        blurRadius: blurRadius,
                        parameters: parameters
                    )
                )
            }
        }
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let pixelBuffer = sampleBuffer.imageBuffer else { return }

        // The stream callback runs on `sampleHandlerQueue`. Keep it cheap and
        // move shared state access to the main queue.
        DispatchQueue.main.async { [weak self] in
            self?.scheduleLiveFrame(pixelBuffer, from: stream)
        }
    }

    /// Must run on the main queue.
    @MainActor
    private func scheduleLiveFrame(_ pixelBuffer: CVPixelBuffer, from stream: SCStream) {
        guard !renderingPaused,
              let displayID = streams.first(where: { $0.value === stream })?.key,
              let overlay = displayOverlays[displayID],
              !renderingDisplays.contains(displayID),
              let renderer
        else { return }

        renderingDisplays.insert(displayID)
        let generation = captureGeneration
        let renderRadius = captureSpaceBlurRadius
        let renderFilterID = activeFilterID
        let frameParameters = renderParameters
        let renderTemporalMode = temporalMode
        let renderRevision = filterRevision
        let cacheKey = Int(displayID)
        // Exclude the focused window's rect from change detection: its content
        // is shown live through the mask hole, so typing must not trigger
        // background re-renders.
        let skipRect = overlay.cutoutInCapturePixels(captureScale: captureScale)

        // Grab the Metal layer while on the main queue (UI objects are
        // main-thread-only).  Metal layer is configured in attach() before
        // capture starts, so it should never be nil here.
        guard let metalLayer = overlay.metalLayer else {
            renderingDisplays.remove(displayID)
            return
        }

        let renderInput = LiveRenderInput(pixelBuffer: pixelBuffer, metalLayer: metalLayer)
        renderQueue.async { [weak self, renderInput] in
            renderer.processFrame(
                pixelBuffer: renderInput.pixelBuffer,
                blurRadius: renderRadius,
                filterID: renderFilterID,
                parameters: frameParameters,
                temporalMode: renderTemporalMode,
                metalLayer: renderInput.metalLayer,
                cacheKey: cacheKey,
                skipRect: skipRect,
                completion: { result in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        // `detachAll()` clears this set and advances the
                        // generation.  Do not let a queued frame from the
                        // old session clear the new session's in-flight
                        // marker.
                        guard self.captureGeneration == generation else { return }
                        self.renderingDisplays.remove(displayID)
                        if result == .rendered {
                            self.onFramePresented?(displayID, renderRevision)
                        }
                    }
                }
            )
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
