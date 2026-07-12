import Foundation
import Metal
import MetalPerformanceShaders
import CoreVideo
import QuartzCore

/// GPU-accelerated Gaussian blur + parameterized post-processing using Metal.
///
/// Pipeline per frame (all GPU, no CPU readback):
///   1. `frameHash` compute pass over a strided sample grid of the capture,
///      excluding the active-window cutout rect.
///   2. The active `TemporalMode` decides whether the frame is dropped:
///      Live renders on any background change, Settled coalesces changes to
///      one render per interval, Frozen holds the presented frame and only
///      re-renders on settings changes.
///   3. Otherwise: MPSImageGaussianBlur (separable, device-tuned) into an
///      intermediate, an optional bloom stage (threshold + MPS blur at half
///      resolution, scheduled only when `bloomAmount > 0`), then
///      `postProcess` writes the filtered result directly into the
///      CAMetalLayer drawable (which is sized to the quarter-res capture, so
///      Core Animation performs the upscale while compositing).
///
/// Threading: all mutable state is confined to `stateQueue`.  `processFrame`
/// may be called from any queue; Metal completion handlers bounce back to
/// `stateQueue` before touching bookkeeping.

enum FrameRenderResult: Equatable {
    case rendered
    case skipped
}

final class MetalBlurRenderer: @unchecked Sendable {

    let device: MTLDevice
    let commandQueue: MTLCommandQueue

    private let postProcessPipeline: MTLComputePipelineState
    private let bloomThresholdPipeline: MTLComputePipelineState
    private let frameHashPipeline: MTLComputePipelineState
    private var mpsBlur: MPSImageGaussianBlur?
    private var mpsBlurSigma: Float = -1   // force first allocation
    /// Fixed-sigma blur for the half-res bloom texture; created lazily on
    /// first bloom-enabled frame (sigma is immutable after creation).
    private var mpsBloomBlur: MPSImageGaussianBlur?

    /// Luminance cutoff for bloom highlight extraction.
    private static let bloomThreshold: Float = 0.65
    private static let bloomSigma: Float = 3.0

    private var textureCache: CVMetalTextureCache?

    /// Serial queue confining all mutable renderer state (texture pool, MPS
    /// filter, per-display frame state, counters).
    private let stateQueue = DispatchQueue(label: "com.hyperfocus.renderer-state")

    // Double-buffered intermediate + output textures keyed by (width * 100_000 + height).
    // Two pairs let the GPU work on frame N while the CPU encodes frame N+1.
    private var texturePool: [Int: [TexturePair]] = [:]
    private var poolIndex:  [Int: Int] = [:]

    private struct TexturePair {
        let intermediate: MTLTexture
        let output: MTLTexture
    }

    /// Per-display change-detection state, keyed by an identifier the caller
    /// provides (display ID).  The hash buffers hold per-tile 64-bit FNV
    /// hashes of the last two hashed frames (ping-pong), so the host can both
    /// detect any change and count how many tiles changed.
    private struct FrameState {
        var hasPresentedHash = false
        /// Two shared-memory buffers; `hashWriteIndex` alternates each frame.
        var hashBuffers: [MTLBuffer?] = [nil, nil]
        var hashWriteIndex = 0
        /// Number of tile hashes a buffer holds (tilesX * tilesY).
        var hashTileCount = 0
        var lastBlurRadius: CGFloat = -1
        var lastFilterID: String?
        var lastParameters: FilterParameters?
        var lastTemporalMode: TemporalMode?
        var lastRenderTime: CFAbsoluteTime = 0
    }
    private var frameStates: [Int: FrameState] = [:]

    /// Tile edge in samples (matches `kTileSize` in BlurDesatShaders.metal).
    /// Each sample covers a 2x2 pixel cell, so a tile covers 64x64 capture
    /// pixels -- the granularity of the Live-mode change-magnitude gate.
    private static let hashTileSize = 32
    /// Hash sampling stride in pixels (matches `kSampleStride` in the shader).
    private static let hashSampleStride = 2
    /// Minimum number of changed tiles that makes Live mode re-render. One
    /// tile covers ~256x256 display pixels, so this skips sub-tile micro-
    /// changes (blinking cursors, clock seconds, 1px spinners) while still
    /// tracking any real background motion.
    private static let liveMinimumChangedTiles = 2

    /// Half-resolution texture pairs for the bloom stage, keyed like the main
    /// pool. Allocated lazily because only bloom-enabled filters need them.
    private struct BloomPair {
        let threshold: MTLTexture
        let blurred: MTLTexture
    }
    private var bloomPool: [Int: [BloomPair]] = [:]
    private var bloomPoolIndex: [Int: Int] = [:]

    /// Counters for diagnostics and tests.
    private var renderedFrameCount = 0
    private var skippedFrameCount = 0
    private var bloomPassCount = 0

    /// Synchronously-read diagnostics counters.
    var debugStats: (rendered: Int, skipped: Int, bloomPasses: Int) {
        stateQueue.sync { (renderedFrameCount, skippedFrameCount, bloomPassCount) }
    }

    // MARK: - Init

    init?() {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        self.device = device
        self.commandQueue = device.makeCommandQueue()!

        guard let library = MetalBlurRenderer.loadShaderLibrary(device: device) else {
            print("[Hyperfocus] Failed to compile Metal shaders from source")
            return nil
        }

        guard let postFn = library.makeFunction(name: "postProcess"),
              let bloomFn = library.makeFunction(name: "bloomThreshold"),
              let hashFn = library.makeFunction(name: "frameHash") else {
            print("[Hyperfocus] Metal functions not found in library")
            return nil
        }

        do {
            self.postProcessPipeline = try device.makeComputePipelineState(function: postFn)
            self.bloomThresholdPipeline = try device.makeComputePipelineState(function: bloomFn)
            self.frameHashPipeline = try device.makeComputePipelineState(function: hashFn)
        } catch {
            print("[Hyperfocus] Failed to create compute pipelines: \(error)")
            return nil
        }

        // MPS filter is created on first use with the correct sigma.
        // sigma is immutable after creation so we recreate when it changes.

        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        self.textureCache = cache
    }

    // MARK: - Live Frame (CAMetalLayer path)

    /// Process a captured pixel buffer and render the result directly into
    /// `metalLayer`, skipping the render when the active temporal mode and
    /// the change-detection hash agree that nothing relevant changed.
    ///
    /// - Parameters:
    ///   - pixelBuffer: BGRA capture from ScreenCaptureKit at quarter resolution.
    ///   - blurRadius:  Gaussian sigma = blurRadius / 2, clamped.
    ///   - filterID: The selected preset or Custom identifier. Included in
    ///     change detection so a filter switch forces a render even when its
    ///     resolved parameters match the prior selection.
    ///   - parameters: Post-processing parameters (`grainSeed` is
    ///     renderer-managed; callers pass 0).
    ///   - temporalMode: Decides when a changed background triggers a render.
    ///   - metalLayer: Configured with `.bgra8Unorm`, non-opaque, clear bg,
    ///     and `drawableSize` equal to the capture size.
    ///   - cacheKey: Stable identifier per display for change-detection state.
    ///   - skipRect: Rect in capture pixels to exclude from change detection
    ///     (the active-window cutout).  `.zero` disables exclusion.
    ///   - completion: Called exactly once, both for rendered and for skipped
    ///     frames.  Use it for bookkeeping only, never for drawing.
    func processFrame(
        pixelBuffer: CVPixelBuffer,
        blurRadius: CGFloat,
        filterID: String,
        parameters: FilterParameters,
        temporalMode: TemporalMode,
        metalLayer: CAMetalLayer,
        cacheKey: Int,
        skipRect: CGRect,
        completion: @escaping (FrameRenderResult) -> Void
    ) {
        stateQueue.async {
            self.beginHashPhase(
                pixelBuffer: pixelBuffer,
                blurRadius: blurRadius,
                filterID: filterID,
                parameters: parameters,
                temporalMode: temporalMode,
                metalLayer: metalLayer,
                cacheKey: cacheKey,
                skipRect: skipRect,
                completion: completion
            )
        }
    }

    /// Compares every render-affecting input against the frame currently
    /// visible for a display. Called only from `stateQueue`.
    private func settingsChanged(
        _ state: FrameState,
        blurRadius: CGFloat,
        filterID: String,
        parameters: FilterParameters,
        temporalMode: TemporalMode
    ) -> Bool {
        state.lastBlurRadius != blurRadius
            || state.lastFilterID != filterID
            || state.lastParameters != parameters
            || state.lastTemporalMode != temporalMode
    }

    /// Runs on `stateQueue`. Encodes the change-detection hash pass unless a
    /// fully initialized Frozen frame can be dropped before any GPU work.
    private func beginHashPhase(
        pixelBuffer: CVPixelBuffer,
        blurRadius: CGFloat,
        filterID: String,
        parameters: FilterParameters,
        temporalMode: TemporalMode,
        metalLayer: CAMetalLayer,
        cacheKey: Int,
        skipRect: CGRect,
        completion: @escaping (FrameRenderResult) -> Void
    ) {
        var state = frameStates[cacheKey] ?? FrameState()
        // Frozen is intentionally a still image. Once it has presented a
        // frame, neither a source texture nor the hash pass is needed until a
        // filter, parameter, radius, or temporal-mode change asks for one.
        if temporalMode == .frozen,
           state.hasPresentedHash,
           !settingsChanged(
               state,
               blurRadius: blurRadius,
               filterID: filterID,
               parameters: parameters,
               temporalMode: temporalMode
           ) {
            skippedFrameCount += 1
            completion(.skipped)
            return
        }

        guard let sourceTexture = makeTexture(from: pixelBuffer),
              sourceTexture.width > 0, sourceTexture.height > 0 else {
            completion(.skipped)
            return
        }

        // Tile grid for this capture size. Buffers are recreated when the
        // capture resolution changes (display hot-plug / resolution switch).
        let samplesPerRow = (sourceTexture.width + Self.hashSampleStride - 1) / Self.hashSampleStride
        let sampleRows = (sourceTexture.height + Self.hashSampleStride - 1) / Self.hashSampleStride
        let tilesX = (samplesPerRow + Self.hashTileSize - 1) / Self.hashTileSize
        let tilesY = (sampleRows + Self.hashTileSize - 1) / Self.hashTileSize
        let totalTiles = tilesX * tilesY
        if state.hashTileCount != totalTiles {
            let byteCount = totalTiles * MemoryLayout<UInt64>.stride
            state.hashBuffers = [
                device.makeBuffer(length: byteCount, options: .storageModeShared),
                device.makeBuffer(length: byteCount, options: .storageModeShared)
            ]
            state.hashWriteIndex = 0
            state.hasPresentedHash = false
            state.hashTileCount = totalTiles
            frameStates[cacheKey] = state
        }

        guard let writeBuffer = state.hashBuffers[state.hashWriteIndex],
              let hashCommandBuffer = commandQueue.makeCommandBuffer(),
              let hashEncoder = hashCommandBuffer.makeComputeCommandEncoder() else {
            completion(.skipped)
            return
        }

        hashEncoder.setComputePipelineState(frameHashPipeline)
        hashEncoder.setTexture(sourceTexture, index: 0)
        hashEncoder.setBuffer(writeBuffer, offset: 0, index: 0)
        var rect = sanitizedHashSkipRect(
            skipRect,
            sourceWidth: sourceTexture.width,
            sourceHeight: sourceTexture.height
        )
        hashEncoder.setBytes(&rect, length: MemoryLayout<simd_uint4>.size, index: 1)
        hashEncoder.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1),
                                         threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
        hashEncoder.endEncoding()

        hashCommandBuffer.addCompletedHandler { [weak self] _ in
            guard let self else {
                completion(.skipped)
                return
            }
            self.stateQueue.async {
                self.finishHashPhase(
                    hashBuffer: writeBuffer,
                    previousBuffer: state.hashBuffers[1 - state.hashWriteIndex],
                    sourceTexture: sourceTexture,
                    blurRadius: blurRadius,
                    filterID: filterID,
                    parameters: parameters,
                    temporalMode: temporalMode,
                    metalLayer: metalLayer,
                    cacheKey: cacheKey,
                    completion: completion
                )
            }
        }
        hashCommandBuffer.commit()
    }

    /// Converts an AppKit-derived cutout into the unsigned capture-space
    /// values used by the hash shader. Accessibility and display transitions
    /// can briefly produce non-finite geometry, which must mean "no skipped
    /// region" rather than trapping while converting `NaN` to `UInt32`.
    private func sanitizedHashSkipRect(
        _ skipRect: CGRect,
        sourceWidth: Int,
        sourceHeight: Int
    ) -> simd_uint4 {
        guard skipRect.origin.x.isFinite,
              skipRect.origin.y.isFinite,
              skipRect.width.isFinite,
              skipRect.height.isFinite,
              skipRect.width > 0,
              skipRect.height > 0
        else {
            return simd_uint4(repeating: 0)
        }

        let bounds = CGRect(
            x: 0,
            y: 0,
            width: CGFloat(sourceWidth),
            height: CGFloat(sourceHeight)
        )
        let clipped = skipRect.integral.intersection(bounds)
        guard !clipped.isNull,
              !clipped.isEmpty,
              clipped.minX.isFinite,
              clipped.minY.isFinite,
              clipped.width.isFinite,
              clipped.height.isFinite
        else {
            return simd_uint4(repeating: 0)
        }

        // `clipped` is integral and contained in texture bounds, making each
        // conversion safe and keeping the shader's x + width arithmetic in
        // range as well.
        return simd_uint4(
            UInt32(Int(clipped.minX)),
            UInt32(Int(clipped.minY)),
            UInt32(Int(clipped.width)),
            UInt32(Int(clipped.height))
        )
    }

    /// Runs on `stateQueue`.  Applies the temporal-mode policy to the fresh
    /// hash and either drops the frame or encodes the render pass.
    private func finishHashPhase(
        hashBuffer: MTLBuffer,
        previousBuffer: MTLBuffer?,
        sourceTexture: MTLTexture,
        blurRadius: CGFloat,
        filterID: String,
        parameters: FilterParameters,
        temporalMode: TemporalMode,
        metalLayer: CAMetalLayer,
        cacheKey: Int,
        completion: @escaping (FrameRenderResult) -> Void
    ) {
        let state = frameStates[cacheKey] ?? FrameState()

        // Per-tile comparison: yields both a change verdict and a magnitude
        // (changed-tile count). `hashBuffer` holds this frame's hashes; the
        // previous frame's live in the ping-pong partner buffer.
        let tileCount = state.hashTileCount
        let tiles = hashBuffer.contents().assumingMemoryBound(to: UInt64.self)
        let previous = previousBuffer?.contents().assumingMemoryBound(to: UInt64.self)

        var combined: UInt64 = 1469598103934665603 // FNV offset basis
        var changedTiles = 0
        let contentChanged: Bool
        if !state.hasPresentedHash {
            // First hashed frame: the ping-pong partner buffer holds no
            // rendered reference yet, so there is nothing to compare against.
            for i in 0..<tileCount { combined ^= tiles[i] }
            contentChanged = true
        } else if let previous, tileCount > 0 {
            for i in 0..<tileCount {
                combined ^= tiles[i]
                if tiles[i] != previous[i] { changedTiles += 1 }
            }
            contentChanged = changedTiles > 0
        } else {
            contentChanged = true
        }
        let hasPresented = state.hasPresentedHash
        let now = CFAbsoluteTimeGetCurrent()

        let settingsChanged = self.settingsChanged(
            state,
            blurRadius: blurRadius,
            filterID: filterID,
            parameters: parameters,
            temporalMode: temporalMode
        )

        // Temporal policy. On skipped frames the stored hashes and render
        // time are deliberately NOT updated, so a Settled-mode skip keeps the
        // pending change visible to the gate and a later frame renders once
        // the interval elapses.
        let shouldRender: Bool
        switch temporalMode {
        case .live:
            // Magnitude gate: a single changed tile (a blinking cursor, the
            // clock's seconds tick, a 1px spinner) is not worth a full
            // re-blur + full-screen present. Two or more tiles means real
            // background motion.
            shouldRender = settingsChanged
                || (contentChanged && changedTiles >= Self.liveMinimumChangedTiles)
        case .settled:
            if settingsChanged || !hasPresented {
                shouldRender = true
            } else if contentChanged {
                shouldRender = (now - state.lastRenderTime) >= TemporalMode.settledInterval
            } else {
                shouldRender = false
            }
        case .frozen:
            shouldRender = settingsChanged || !hasPresented
        }

        guard shouldRender else {
            skippedFrameCount += 1
            completion(.skipped)
            return
        }

        let width = sourceTexture.width
        let height = sourceTexture.height

        guard let drawable = metalLayer.nextDrawable(),
              let pair = dequeueTexturePair(width: width, height: height),
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            completion(.skipped)
            return
        }

        // MPS separable 2D Gaussian -- sigma ~ radius/2.
        let sigma = max(Float(blurRadius) / 2.0, 0.001)
        prepareBlur(sigma: sigma)
        mpsBlur?.encode(commandBuffer: commandBuffer,
                        sourceTexture: sourceTexture,
                        destinationTexture: pair.intermediate)

        // Optional bloom stage (threshold + half-res blur). Only scheduled
        // for bloom-enabled filters; the returned texture is nil on failure
        // and the post kernel then runs with bloomAmount forced to 0.
        var bloomTexture: MTLTexture?
        if parameters.bloomAmount > 0 {
            bloomTexture = encodeBloomStage(source: pair.intermediate, commandBuffer: commandBuffer)
        }

        // Grain is re-seeded per rendered frame from the combined content hash,
        // so a static frame always shows identical grain and re-renders of
        // the same content never shimmer.
        var effectiveParameters = parameters
        effectiveParameters.grainSeed = Float(combined % 4096)
        if bloomTexture == nil { effectiveParameters.bloomAmount = 0 }

        // Post-process writes straight into the drawable when its size matches
        // the capture (the normal case -- drawableSize is configured to the
        // capture size).  Otherwise fall back to a clamped blit.
        let drawableMatches = drawable.texture.width == width && drawable.texture.height == height
        if drawableMatches {
            encodePostProcess(source: pair.intermediate,
                              bloom: bloomTexture,
                              destination: drawable.texture,
                              parameters: effectiveParameters,
                              commandBuffer: commandBuffer)
        } else {
            encodePostProcess(source: pair.intermediate,
                              bloom: bloomTexture,
                              destination: pair.output,
                              parameters: effectiveParameters,
                              commandBuffer: commandBuffer)
            if let blitEncoder = commandBuffer.makeBlitCommandEncoder() {
                let copyW = min(width, drawable.texture.width)
                let copyH = min(height, drawable.texture.height)
                blitEncoder.copy(from: pair.output,
                                 sourceSlice: 0, sourceLevel: 0,
                                 sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                                 sourceSize: MTLSize(width: copyW, height: copyH, depth: 1),
                                 to: drawable.texture,
                                 destinationSlice: 0, destinationLevel: 0,
                                 destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
                blitEncoder.endEncoding()
            }
        }

        commandBuffer.present(drawable)
        commandBuffer.addCompletedHandler { [weak self] buffer in
            guard let self else {
                completion(.skipped)
                return
            }
            self.stateQueue.async {
                // Bookkeeping is updated only after the GPU finished
                // successfully, so a dropped or failed render never freezes
                // the visible state.
                guard buffer.status == .completed else {
                    completion(.skipped)
                    return
                }
                var state = self.frameStates[cacheKey] ?? FrameState()
                // The just-written buffer becomes the comparison reference for
                // the next frame; the next write uses its ping-pong partner.
                // Swapping only here (not on skipped frames) keeps the last
                // rendered hashes as the reference, so a Settled/Live skip
                // cannot lose the pending change.
                state.hasPresentedHash = true
                state.hashWriteIndex = 1 - state.hashWriteIndex
                state.lastBlurRadius = blurRadius
                state.lastFilterID = filterID
                state.lastParameters = parameters
                state.lastTemporalMode = temporalMode
                state.lastRenderTime = now
                self.frameStates[cacheKey] = state
                self.renderedFrameCount += 1
                completion(.rendered)
            }
        }
        commandBuffer.commit()
    }

    /// Drops change-detection state for a display whose capture was torn down.
    /// The next frame for the key renders unconditionally.
    func clearFrameState(cacheKey: Int) {
        stateQueue.async {
            self.frameStates.removeValue(forKey: cacheKey)
        }
    }

    // MARK: - Post-Process Encode Helpers

    private func encodePostProcess(
        source: MTLTexture,
        bloom: MTLTexture?,
        destination: MTLTexture,
        parameters: FilterParameters,
        commandBuffer: MTLCommandBuffer
    ) {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.setComputePipelineState(postProcessPipeline)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(destination, index: 1)
        // Dummy binding when bloom is off; the kernel short-circuits on
        // bloomAmount == 0 before sampling.
        encoder.setTexture(bloom ?? source, index: 2)
        var uniforms = parameters
        if bloom == nil { uniforms.bloomAmount = 0 }
        encoder.setBytes(&uniforms, length: MemoryLayout<FilterParameters>.stride, index: 0)

        let w = postProcessPipeline.threadExecutionWidth
        let h = postProcessPipeline.maxTotalThreadsPerThreadgroup / w
        encoder.dispatchThreads(MTLSize(width: source.width, height: source.height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
        encoder.endEncoding()
    }

    /// Extracts highlights above the luminance threshold into a
    /// half-resolution texture and blurs them. Returns the blurred bloom
    /// texture for the additive composite in `postProcess`, or nil when
    /// allocation fails (the caller then renders without bloom).
    private func encodeBloomStage(
        source: MTLTexture,
        commandBuffer: MTLCommandBuffer
    ) -> MTLTexture? {
        let width = max(1, source.width / 2)
        let height = max(1, source.height / 2)
        guard let pair = dequeueBloomPair(width: width, height: height) else { return nil }

        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return nil }
        encoder.setComputePipelineState(bloomThresholdPipeline)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(pair.threshold, index: 1)
        var threshold = MetalBlurRenderer.bloomThreshold
        encoder.setBytes(&threshold, length: MemoryLayout<Float>.size, index: 0)
        let w = bloomThresholdPipeline.threadExecutionWidth
        let h = bloomThresholdPipeline.maxTotalThreadsPerThreadgroup / w
        encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
        encoder.endEncoding()

        if mpsBloomBlur == nil {
            mpsBloomBlur = MPSImageGaussianBlur(device: device, sigma: MetalBlurRenderer.bloomSigma)
        }
        mpsBloomBlur?.encode(commandBuffer: commandBuffer,
                             sourceTexture: pair.threshold,
                             destinationTexture: pair.blurred)

        bloomPassCount += 1
        return pair.blurred
    }

    // MARK: - CGImage Processing (still-screenshot boot path)

    /// Process a `CGImage` through the blur + post-processing pipeline and
    /// return a new `CGImage`. Used once at session start for the instant
    /// still-screenshot boot frame; the CPU readback cost is negligible for a
    /// single shot.
    ///
    /// Serialized against live-frame work via `stateQueue` because it shares
    /// the texture pool, MPS blur, and optional bloom textures.
    func processCGImage(
        _ image: CGImage,
        blurRadius: CGFloat,
        parameters: FilterParameters
    ) -> CGImage? {
        stateQueue.sync {
            processCGImageLocked(image, blurRadius: blurRadius, parameters: parameters)
        }
    }

    private func processCGImageLocked(
        _ image: CGImage,
        blurRadius: CGFloat,
        parameters: FilterParameters
    ) -> CGImage? {
        let width  = image.width
        let height = image.height

        guard width > 0, height > 0 else { return nil }

        // Upload source CGImage to a Metal texture.
        let bytesPerRow = width * 4
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width, height: height, mipmapped: false)
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        guard let input = device.makeTexture(descriptor: desc) else { return nil }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little
            .union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue))
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: colorSpace, bitmapInfo: bitmapInfo.rawValue)
        else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let raw = ctx.data else { return nil }
        input.replace(region: MTLRegionMake2D(0, 0, width, height),
                      mipmapLevel: 0, withBytes: raw, bytesPerRow: bytesPerRow)

        guard let pair = dequeueTexturePair(width: width, height: height),
              let commandBuffer = commandQueue.makeCommandBuffer() else { return nil }

        // MPS blur.
        let sigma = max(Float(blurRadius) / 2.0, 0.001)
        prepareBlur(sigma: sigma)
        mpsBlur?.encode(commandBuffer: commandBuffer,
                        sourceTexture: input,
                        destinationTexture: pair.intermediate)

        var bloomTexture: MTLTexture?
        if parameters.bloomAmount > 0 {
            bloomTexture = encodeBloomStage(source: pair.intermediate, commandBuffer: commandBuffer)
        }

        // The still-image path has no content hash. Keep its grain seed at 0
        // so repeated processing of the same screenshot is pixel-identical.
        var effectiveParameters = parameters
        effectiveParameters.grainSeed = 0
        if bloomTexture == nil { effectiveParameters.bloomAmount = 0 }
        encodePostProcess(source: pair.intermediate,
                          bloom: bloomTexture,
                          destination: pair.output,
                          parameters: effectiveParameters,
                          commandBuffer: commandBuffer)

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        return makeCGImage(from: pair.output)
    }

    // MARK: - Texture Helpers

    private func makeTexture(from pixelBuffer: CVPixelBuffer) -> MTLTexture? {
        guard let cache = textureCache else { return nil }
        let width  = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        var cvTexture: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, pixelBuffer, nil,
            .bgra8Unorm, width, height, 0, &cvTexture)
        return cvTexture.flatMap { CVMetalTextureGetTexture($0) }
    }

    private func makeTexture(width: Int, height: Int,
                              usage: MTLTextureUsage) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        desc.usage = usage
        return device.makeTexture(descriptor: desc)
    }

    private func makeCGImage(from texture: MTLTexture) -> CGImage? {
        let width  = texture.width
        let height = texture.height
        let bytesPerRow = width * 4
        var data = [UInt8](repeating: 0, count: height * bytesPerRow)
        texture.getBytes(&data, bytesPerRow: bytesPerRow,
                         from: MTLRegionMake2D(0, 0, width, height),
                         mipmapLevel: 0)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little
            .union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue))
        guard let provider = CGDataProvider(data: NSData(bytes: &data, length: data.count))
        else { return nil }

        return CGImage(width: width, height: height,
                       bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: bytesPerRow, space: colorSpace,
                       bitmapInfo: bitmapInfo, provider: provider,
                       decode: nil, shouldInterpolate: true,
                       intent: .defaultIntent)
    }

    // MARK: - MPS Filter Management

    /// Recreate the Gaussian blur filter when sigma changes (sigma is immutable
    /// after `MPSImageGaussianBlur` is created). Quantize to 0.5 steps so
    /// dragging the blur slider does not allocate a brand new filter on every
    /// 1-px tick; visual difference is imperceptible.
    private func prepareBlur(sigma: Float) {
        let quantized = max(0.001, round(sigma * 2.0) / 2.0)
        guard quantized != mpsBlurSigma else { return }
        mpsBlur = MPSImageGaussianBlur(device: device, sigma: quantized)
        mpsBlurSigma = quantized
    }

    // MARK: - Double-Buffered Texture Pool

    /// Returns nil instead of crashing when allocation fails; callers fall
    /// back to dropping the frame.
    private func dequeueTexturePair(width: Int, height: Int) -> TexturePair? {
        let key = width * 100_000 + height

        if let pool = texturePool[key] {
            let idx = poolIndex[key, default: 0]
            poolIndex[key] = (idx + 1) % pool.count
            return pool[idx]
        }

        // Allocate two pairs so we can ping-pong.
        var pairs: [TexturePair] = []
        let usage: MTLTextureUsage = [.shaderWrite, .shaderRead]
        for _ in 0..<2 {
            guard let inter = makeTexture(width: width, height: height, usage: usage),
                  let out   = makeTexture(width: width, height: height, usage: usage)
            else {
                print("[Hyperfocus] Failed to allocate blur textures (\(width)x\(height)); dropping frame")
                return nil
            }
            pairs.append(TexturePair(intermediate: inter, output: out))
        }
        texturePool[key] = pairs
        poolIndex[key] = 1    // next call returns [0]
        return pairs[0]
    }

    /// Returns a double-buffered pair of half-resolution bloom textures.
    /// The first receives the threshold output; MPS writes the blurred result
    /// into the second. This is separate from the main pool so non-Bokeh
    /// filters never allocate its memory.
    private func dequeueBloomPair(width: Int, height: Int) -> BloomPair? {
        let key = width * 100_000 + height

        if let pool = bloomPool[key] {
            let idx = bloomPoolIndex[key, default: 0]
            bloomPoolIndex[key] = (idx + 1) % pool.count
            return pool[idx]
        }

        var pairs: [BloomPair] = []
        let usage: MTLTextureUsage = [.shaderWrite, .shaderRead]
        for _ in 0..<2 {
            guard let threshold = makeTexture(width: width, height: height, usage: usage),
                  let blurred = makeTexture(width: width, height: height, usage: usage)
            else {
                print("[Hyperfocus] Failed to allocate bloom textures (\(width)x\(height)); rendering without bloom")
                return nil
            }
            pairs.append(BloomPair(threshold: threshold, blurred: blurred))
        }
        bloomPool[key] = pairs
        bloomPoolIndex[key] = 1
        return pairs[0]
    }

    // MARK: - Runtime Shader Compilation

    /// Prefer the library that Xcode compiles into the app, then fall back to
    /// runtime compilation for the command-line build which ships the source.
    private static func loadShaderLibrary(device: MTLDevice) -> MTLLibrary? {
        if let defaultLibrary = device.makeDefaultLibrary() {
            return defaultLibrary
        }

        let possiblePaths = [
            Bundle.main.path(forResource: "BlurDesatShaders", ofType: "metal"),
            Bundle.main.path(forResource: "BlurDesatShaders", ofType: "metal", inDirectory: "Shaders"),
        ]

        guard let shaderPath = possiblePaths.compactMap({ $0 }).first,
              let shaderSource = try? String(contentsOfFile: shaderPath, encoding: .utf8)
        else {
            print("[Hyperfocus] Could not find BlurDesatShaders.metal in bundle")
            return nil
        }

        do {
            let library = try device.makeLibrary(source: shaderSource, options: nil)
            print("[Hyperfocus] Metal shaders compiled from source at runtime")
            return library
        } catch {
            print("[Hyperfocus] Metal shader compilation error: \(error)")
            if let compileError = error as? MTLLibraryError {
                print("[Hyperfocus] Compile error code: \(compileError.errorCode)")
            }
            return nil
        }
    }
}
