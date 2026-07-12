import Metal
import MetalKit
import CoreVideo

/// GPU-accelerated Gaussian blur + desaturation using Metal compute
final class MetalBlurRenderer {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let blurPipeline: MTLComputePipelineState
    private var upscalePipeline: MTLComputePipelineState?
    private var textureCache: CVMetalTextureCache?

    init?() {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        self.device = device
        self.commandQueue = device.makeCommandQueue()!

        // Compile Metal shaders from source at runtime.
        // No precompiled .metallib needed -- works with Command Line Tools only (no Xcode).
        guard let library = MetalBlurRenderer.loadShaderLibrary(device: device) else {
            print("[Hyperfocus] Failed to compile Metal shaders from source")
            return nil
        }

        guard let blurFn = library.makeFunction(name: "blurAndDesaturate") else {
            print("[Hyperfocus] Metal function 'blurAndDesaturate' not found")
            return nil
        }

        do {
            self.blurPipeline = try device.makeComputePipelineState(function: blurFn)
        } catch {
            print("[Hyperfocus] Failed to create compute pipeline: \(error)")
            return nil
        }

        // Optional bilinear-upscale pipeline. If absent, processFrame falls back
        // to returning the quarter-res blurred texture.
        if let upscaleFn = library.makeFunction(name: "bilinearUpscale") {
            do {
                self.upscalePipeline = try device.makeComputePipelineState(function: upscaleFn)
            } catch {
                print("[Hyperfocus] Failed to create upscale pipeline: \(error)")
                self.upscalePipeline = nil
            }
        } else {
            print("[Hyperfocus] Metal function 'bilinearUpscale' not found; upscaling disabled")
            self.upscalePipeline = nil
        }

        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        self.textureCache = cache
    }

    // MARK: - Frame Processing

    /// Process a captured pixel buffer through the blur+desat pipeline, then
    /// bilinearly upscale to full display resolution.
    ///
    /// Pipeline: quarter-res capture → blur+desat (quarter-res) → bilinear
    /// upscale (full-res) → CGImage. `outputSize` should be the full display
    /// resolution (e.g. 4× the captured buffer dimensions); the returned CGImage
    /// is at that resolution, not quarter-res. Returns a CGImage suitable for
    /// CALayer.contents.
    func processFrame(
        pixelBuffer: CVPixelBuffer,
        blurRadius: CGFloat,
        saturation: CGFloat,
        outputSize: CGSize
    ) -> CGImage? {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return nil }

        // Create Metal texture from pixel buffer (zero-copy via IOSurface)
        guard let sourceTexture = makeTexture(from: pixelBuffer) else { return nil }

        let width = sourceTexture.width
        let height = sourceTexture.height

        // Quarter-res blurred output (also shader-readable for the upscale pass)
        let blurDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        blurDesc.usage = [.shaderWrite, .shaderRead]
        guard let blurTexture = device.makeTexture(descriptor: blurDesc) else { return nil }

        guard let computeEncoder = commandBuffer.makeComputeCommandEncoder() else { return nil }

        // Pass 1: fused Gaussian blur + desaturation at quarter-res
        computeEncoder.setComputePipelineState(blurPipeline)
        computeEncoder.setTexture(sourceTexture, index: 0)
        computeEncoder.setTexture(blurTexture, index: 1)

        var radius = Float(blurRadius)
        var sat = Float(saturation)
        computeEncoder.setBytes(&radius, length: MemoryLayout<Float>.size, index: 0)
        computeEncoder.setBytes(&sat, length: MemoryLayout<Float>.size, index: 1)

        let threadGroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let gridSize = MTLSize(
            width: (width + threadGroupSize.width - 1) / threadGroupSize.width,
            height: (height + threadGroupSize.height - 1) / threadGroupSize.height,
            depth: 1
        )
        computeEncoder.dispatchThreadgroups(gridSize, threadsPerThreadgroup: threadGroupSize)
        computeEncoder.endEncoding()

        // Pass 2: bilinear upscale to full display resolution. Falls back to the
        // quarter-res blurred texture when the upscale pipeline is unavailable or
        // the requested size is not larger than the source.
        let finalTexture: MTLTexture
        if let upscaled = upscaleTexture(
            source: blurTexture,
            outputSize: outputSize,
            commandBuffer: commandBuffer
        ) {
            finalTexture = upscaled
        } else {
            finalTexture = blurTexture
        }

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        // Convert the (upscaled) Metal texture to CGImage for CALayer
        return makeCGImage(from: finalTexture)
    }

    // MARK: - Upscale

    /// Bilinearly upscales `source` to `outputSize` using the `bilinearUpscale`
    /// compute kernel. Encodes onto the given command buffer (caller commits),
    /// so it can run in the same submission as the blur pass. Returns nil (→ the
    /// caller falls back to the source texture) when the upscale pipeline is
    /// unavailable or the target size is not larger than the source.
    private func upscaleTexture(
        source: MTLTexture,
        outputSize: CGSize,
        commandBuffer: MTLCommandBuffer
    ) -> MTLTexture? {
        guard let upscalePipeline = upscalePipeline else { return nil }

        let outW = Int(outputSize.width)
        let outH = Int(outputSize.height)
        guard outW > source.width || outH > source.height else { return nil }

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: outW,
            height: outH,
            mipmapped: false
        )
        desc.usage = [.shaderWrite]
        guard let output = device.makeTexture(descriptor: desc) else { return nil }

        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return nil }
        encoder.setComputePipelineState(upscalePipeline)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(output, index: 1)

        let threadGroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let gridSize = MTLSize(
            width: (outW + threadGroupSize.width - 1) / threadGroupSize.width,
            height: (outH + threadGroupSize.height - 1) / threadGroupSize.height,
            depth: 1
        )
        encoder.dispatchThreadgroups(gridSize, threadsPerThreadgroup: threadGroupSize)
        encoder.endEncoding()

        return output
    }

    // MARK: - CGImage Processing (still-screenshot boot path)

    /// Process a `CGImage` through the blur+desat pipeline.
    /// Used by `BlurEngine.captureStillScreenshot` to push a still frame
    /// through the same pipeline as live frames.
    /// route the boot frame through the same kernel as live frames.
    func processCGImage(
        _ image: CGImage,
        blurRadius: CGFloat,
        saturation: CGFloat
    ) -> CGImage? {
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        guard let input = device.makeTexture(descriptor: desc) else { return nil }

        let outDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        outDesc.usage = [.shaderWrite, .shaderRead]
        guard let output = device.makeTexture(descriptor: outDesc) else { return nil }

        // Draw the source CGImage into a CPU buffer we can upload to the
        // input texture. Using a CGContext with a nil data pointer tells
        // CoreGraphics to allocate -- we then read its backing pointer.
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
        )
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let raw = context.data else { return nil }

        input.replace(
            region: MTLRegion(origin: .init(x: 0, y: 0, z: 0),
                              size: .init(width: width, height: height, depth: 1)),
            mipmapLevel: 0,
            withBytes: raw,
            bytesPerRow: bytesPerRow
        )

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return nil }

        encoder.setComputePipelineState(blurPipeline)
        encoder.setTexture(input, index: 0)
        encoder.setTexture(output, index: 1)

        var radius = Float(blurRadius)
        var sat = Float(saturation)
        encoder.setBytes(&radius, length: MemoryLayout<Float>.size, index: 0)
        encoder.setBytes(&sat, length: MemoryLayout<Float>.size, index: 1)

        let threads = MTLSize(width: 16, height: 16, depth: 1)
        let groups = MTLSize(
            width: (width + 15) / 16,
            height: (height + 15) / 16,
            depth: 1
        )
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threads)
        encoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        return makeCGImage(from: output)
    }

    // MARK: - Texture Helpers

    private func makeTexture(from pixelBuffer: CVPixelBuffer) -> MTLTexture? {
        guard let cache = textureCache else { return nil }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        var cvTexture: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            cache,
            pixelBuffer,
            nil,
            .bgra8Unorm,
            width,
            height,
            0,
            &cvTexture
        )

        return cvTexture.flatMap { CVMetalTextureGetTexture($0) }
    }

    private func makeCGImage(from texture: MTLTexture) -> CGImage? {
        let width = texture.width
        let height = texture.height
        let bytesPerRow = width * 4
        var data = [UInt8](repeating: 0, count: height * bytesPerRow)

        texture.getBytes(
            &data,
            bytesPerRow: bytesPerRow,
            from: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0), size: MTLSize(width: width, height: height, depth: 1)),
            mipmapLevel: 0
        )

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue))

        guard let provider = CGDataProvider(data: NSData(bytes: &data, length: data.count)) else { return nil }

        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    // MARK: - Runtime Shader Compilation

    /// Prefer the library that Xcode compiles into the app, then fall back to
    /// runtime compilation for the command-line build which ships the source.
    private static func loadShaderLibrary(device: MTLDevice) -> MTLLibrary? {
        if let defaultLibrary = device.makeDefaultLibrary() {
            return defaultLibrary
        }

        // Locate the shader source copied by scripts/build.sh.
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
