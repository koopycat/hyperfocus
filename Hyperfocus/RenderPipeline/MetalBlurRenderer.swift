import Metal
import MetalPerformanceShaders
import CoreVideo
import QuartzCore

/// GPU-accelerated Gaussian blur + desaturation using Metal.
///
/// Pipeline per frame (all GPU, no CPU readback):
///   1. `frameHash` compute pass over a strided sample grid of the capture,
///      excluding the active-window cutout rect.
///   2. If the hash matches the last rendered frame AND blur/saturation
///      settings are unchanged, the frame is dropped -- no render, no present,
///      no WindowServer recomposite.  On a static desktop this removes almost
///      all steady-state GPU work; the capture itself is cheap.
///   3. Otherwise: MPSImageGaussianBlur (separable, device-tuned) into an
///      intermediate, then `desaturate` writes directly into the CAMetalLayer
///      drawable (which is sized to the quarter-res capture, so Core Animation
///      performs the upscale while compositing).
///
/// Threading: all mutable state is confined to `stateQueue`.  `processFrame`
/// may be called from any queue; Metal completion handlers bounce back to
/// `stateQueue` before touching bookkeeping.
final class MetalBlurRenderer: @unchecked Sendable {

    let device: MTLDevice
    let commandQueue: MTLCommandQueue

    private let desaturatePipeline: MTLComputePipelineState
    private let frameHashPipeline: MTLComputePipelineState
    private var mpsBlur: MPSImageGaussianBlur?
    private var mpsBlurSigma: Float = -1   // force first allocation

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
    /// provides (display ID).  `lastHash`/`lastSettings` describe the frame
    /// whose pixels are currently visible in the display's drawable.
    private struct FrameState {
        var lastHash: UInt64?
        var lastBlurRadius: CGFloat = -1
        var lastSaturation: CGFloat = -1
        var hashBuffer: MTLBuffer?
    }
    private var frameStates: [Int: FrameState] = [:]

    /// Counters for diagnostics and tests.
    private var renderedFrameCount = 0
    private var skippedFrameCount = 0

    /// Synchronously-read diagnostics counters.
    var debugStats: (rendered: Int, skipped: Int) {
        stateQueue.sync { (renderedFrameCount, skippedFrameCount) }
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

        guard let desatFn = library.makeFunction(name: "desaturate"),
              let hashFn = library.makeFunction(name: "frameHash") else {
            print("[Hyperfocus] Metal functions not found in library")
            return nil
        }

        do {
            self.desaturatePipeline = try device.makeComputePipelineState(function: desatFn)
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
    /// `metalLayer`, skipping the render entirely when neither the captured
    /// pixels (outside `skipRect`) nor the effect settings changed.
    ///
    /// - Parameters:
    ///   - pixelBuffer: BGRA capture from ScreenCaptureKit at quarter resolution.
    ///   - blurRadius:  Gaussian sigma = blurRadius / 2, clamped.
    ///   - saturation: 0 = grayscale, 1 = original colour.
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
        saturation: CGFloat,
        metalLayer: CAMetalLayer,
        cacheKey: Int,
        skipRect: CGRect,
        completion: @escaping () -> Void
    ) {
        stateQueue.async {
            self.beginHashPhase(
                pixelBuffer: pixelBuffer,
                blurRadius: blurRadius,
                saturation: saturation,
                metalLayer: metalLayer,
                cacheKey: cacheKey,
                skipRect: skipRect,
                completion: completion
            )
        }
    }

    /// Runs on `stateQueue`.  Encodes the change-detection hash pass.
    private func beginHashPhase(
        pixelBuffer: CVPixelBuffer,
        blurRadius: CGFloat,
        saturation: CGFloat,
        metalLayer: CAMetalLayer,
        cacheKey: Int,
        skipRect: CGRect,
        completion: @escaping () -> Void
    ) {
        guard let sourceTexture = makeTexture(from: pixelBuffer),
              sourceTexture.width > 0, sourceTexture.height > 0 else {
            completion()
            return
        }

        var state = frameStates[cacheKey] ?? FrameState()
        if state.hashBuffer == nil {
            state.hashBuffer = device.makeBuffer(
                length: MemoryLayout<UInt64>.size,
                options: .storageModeShared
            )
            frameStates[cacheKey] = state
        }

        guard let hashBuffer = state.hashBuffer,
              let hashCommandBuffer = commandQueue.makeCommandBuffer(),
              let hashEncoder = hashCommandBuffer.makeComputeCommandEncoder() else {
            completion()
            return
        }

        hashEncoder.setComputePipelineState(frameHashPipeline)
        hashEncoder.setTexture(sourceTexture, index: 0)
        hashEncoder.setBuffer(hashBuffer, offset: 0, index: 0)
        var rect = simd_uint4(
            UInt32(max(0, skipRect.origin.x)),
            UInt32(max(0, skipRect.origin.y)),
            UInt32(max(0, skipRect.size.width)),
            UInt32(max(0, skipRect.size.height))
        )
        hashEncoder.setBytes(&rect, length: MemoryLayout<simd_uint4>.size, index: 1)
        hashEncoder.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1),
                                         threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
        hashEncoder.endEncoding()

        hashCommandBuffer.addCompletedHandler { [weak self] _ in
            guard let self else {
                completion()
                return
            }
            self.stateQueue.async {
                self.finishHashPhase(
                    hashBuffer: hashBuffer,
                    sourceTexture: sourceTexture,
                    blurRadius: blurRadius,
                    saturation: saturation,
                    metalLayer: metalLayer,
                    cacheKey: cacheKey,
                    completion: completion
                )
            }
        }
        hashCommandBuffer.commit()
    }

    /// Runs on `stateQueue`.  Compares the fresh hash against the visible
    /// frame and either drops the frame or encodes the render pass.
    private func finishHashPhase(
        hashBuffer: MTLBuffer,
        sourceTexture: MTLTexture,
        blurRadius: CGFloat,
        saturation: CGFloat,
        metalLayer: CAMetalLayer,
        cacheKey: Int,
        completion: @escaping () -> Void
    ) {
        let hash = hashBuffer.contents().load(as: UInt64.self)
        let state = frameStates[cacheKey] ?? FrameState()

        let settingsChanged = state.lastBlurRadius != blurRadius
            || state.lastSaturation != saturation
        let contentChanged = state.lastHash != hash

        guard contentChanged || settingsChanged else {
            skippedFrameCount += 1
            completion()
            return
        }

        let width = sourceTexture.width
        let height = sourceTexture.height

        guard let drawable = metalLayer.nextDrawable(),
              let pair = dequeueTexturePair(width: width, height: height),
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            completion()
            return
        }

        // MPS separable 2D Gaussian -- sigma ~ radius/2.
        let sigma = max(Float(blurRadius) / 2.0, 0.001)
        prepareBlur(sigma: sigma)
        mpsBlur?.encode(commandBuffer: commandBuffer,
                        sourceTexture: sourceTexture,
                        destinationTexture: pair.intermediate)

        // Desaturate writes straight into the drawable when its size matches
        // the capture (the normal case -- drawableSize is configured to the
        // capture size).  Otherwise fall back to a clamped blit.
        let drawableMatches = drawable.texture.width == width && drawable.texture.height == height
        if drawableMatches {
            encodeDesaturate(source: pair.intermediate,
                             destination: drawable.texture,
                             saturation: saturation,
                             commandBuffer: commandBuffer)
        } else {
            encodeDesaturate(source: pair.intermediate,
                             destination: pair.output,
                             saturation: saturation,
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
        commandBuffer.addCompletedHandler { [weak self] _ in
            guard let self else {
                completion()
                return
            }
            self.stateQueue.async {
                // Bookkeeping is updated only after the GPU finished, so a
                // dropped or failed render never freezes the visible state.
                var state = self.frameStates[cacheKey] ?? FrameState()
                state.lastHash = hash
                state.lastBlurRadius = blurRadius
                state.lastSaturation = saturation
                self.frameStates[cacheKey] = state
                self.renderedFrameCount += 1
                completion()
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

    // MARK: - Desaturate Encode Helper

    private func encodeDesaturate(
        source: MTLTexture,
        destination: MTLTexture,
        saturation: CGFloat,
        commandBuffer: MTLCommandBuffer
    ) {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.setComputePipelineState(desaturatePipeline)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(destination, index: 1)
        var sat = Float(saturation)
        encoder.setBytes(&sat, length: MemoryLayout<Float>.size, index: 0)

        let w = desaturatePipeline.threadExecutionWidth
        let h = desaturatePipeline.maxTotalThreadsPerThreadgroup / w
        encoder.dispatchThreads(MTLSize(width: source.width, height: source.height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
        encoder.endEncoding()
    }

    // MARK: - CGImage Processing (still-screenshot boot path)

    /// Process a `CGImage` through the blur+desat pipeline and return a new
    /// `CGImage`.  Used once at session start for the instant still-screenshot
    /// boot frame; the CPU readback cost is negligible for a single shot.
    ///
    /// Serialized against live-frame work via `stateQueue` because it shares
    /// the texture pool and MPS filter.
    func processCGImage(
        _ image: CGImage,
        blurRadius: CGFloat,
        saturation: CGFloat
    ) -> CGImage? {
        stateQueue.sync {
            processCGImageLocked(image, blurRadius: blurRadius, saturation: saturation)
        }
    }

    private func processCGImageLocked(
        _ image: CGImage,
        blurRadius: CGFloat,
        saturation: CGFloat
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

        encodeDesaturate(source: pair.intermediate,
                         destination: pair.output,
                         saturation: saturation,
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
