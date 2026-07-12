import Metal
import CoreGraphics
import Dispatch

/// Per-display cache for captured and processed textures.
/// Enables tile-based dirty region detection to minimize re-blur work.
final class DisplayCache {
    let displayID: CGDirectDisplayID

    /// Latest captured frame (quarter-res)
    var sourceTexture: MTLTexture?

    /// Blurred + desaturated output
    var processedTexture: MTLTexture?

    /// Per-tile content hashes for change detection
    var tileHashes: [[UInt64]] = []

    /// Tiles that need re-blurring
    var dirtyTiles: Set<TileIndex> = []

    /// Whether the cache has valid data
    var isValid: Bool { sourceTexture != nil && processedTexture != nil }

    /// Whether this is the primary (focused) display -- non-primary caches
    /// are first to be marked volatile under memory pressure.
    var isPrimary: Bool = false

    private let tileSize: Int = 128
    private let device: MTLDevice

    init(displayID: CGDirectDisplayID, device: MTLDevice) {
        self.displayID = displayID
        self.device = device
    }

    func resetTileGrid(width: Int, height: Int) {
        let cols = (width + tileSize - 1) / tileSize
        let rows = (height + tileSize - 1) / tileSize
        tileHashes = Array(repeating: Array(repeating: 0, count: rows), count: cols)
        dirtyTiles.removeAll()
    }

    func invalidateAll() {
        for x in 0..<tileHashes.count {
            for y in 0..<tileHashes[x].count {
                dirtyTiles.insert(TileIndex(x: x, y: y))
            }
        }
    }

    func markDirty(rect: CGRect, bleed: CGFloat, workSize: CGSize) {
        let tileW = CGFloat(tileSize)
        let tileH = CGFloat(tileSize)

        let left = max(0, Int(floor((rect.minX - bleed) / tileW)))
        let right = min(tileHashes.count - 1, Int(ceil((rect.maxX + bleed) / tileW)))
        let top = max(0, Int(floor((rect.minY - bleed) / tileH)))
        let bottom = min(tileHashes[0].count - 1, Int(ceil((rect.maxY + bleed) / tileH)))

        for x in left...right {
            for y in top...bottom {
                dirtyTiles.insert(TileIndex(x: x, y: y))
            }
        }
    }

    func hasChanges(for newHashes: [[UInt64]]) -> Bool {
        // Compare and update hashes
        var changed = false
        for x in 0..<min(tileHashes.count, newHashes.count) {
            for y in 0..<min(tileHashes[x].count, newHashes[x].count) {
                if tileHashes[x][y] != newHashes[x][y] {
                    dirtyTiles.insert(TileIndex(x: x, y: y))
                    tileHashes[x][y] = newHashes[x][y]
                    changed = true
                }
            }
        }
        return changed
    }

    func clearDirtyTiles() {
        dirtyTiles.removeAll()
    }

    // MARK: - Memory Pressure

    /// Hint the OS that the contents of these textures may be discarded.
    /// On Apple Silicon, `MTLStorageMode.shared` makes this a no-op; on
    /// discrete GPUs it lets the driver drop the backing pages to reclaim
    /// memory. Textures remain valid (and will be re-uploaded on next use).
    func markTexturesVolatile() {
        sourceTexture?.setPurgeableState(.volatile)
        processedTexture?.setPurgeableState(.volatile)
    }

    /// Fully release cached textures. Non-primary displays should be first
    /// to go under CRITICAL memory pressure.
    func releaseTextures() {
        sourceTexture = nil
        processedTexture = nil
    }
}

struct TileIndex: Hashable {
    let x: Int
    let y: Int
}

// MARK: - Tile Hash Computer

/// Dispatches the `computeTileHashes` Metal kernel and returns the
/// per-tile content fingerprints as a 2D array matching `DisplayCache.tileHashes`.
final class TileHashComputer {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState

    private let tileSize: Int = 128
    private let threadsPerSide: Int = 16

    init?(device: MTLDevice) {
        guard let queue = device.makeCommandQueue() else { return nil }

        guard let library = device.makeDefaultLibrary() else {
            print("[Hyperfocus] TileHashComputer: failed to load default Metal library")
            return nil
        }
        guard let fn = library.makeFunction(name: "computeTileHashes") else {
            print("[Hyperfocus] TileHashComputer: function 'computeTileHashes' not found")
            return nil
        }
        do {
            self.pipeline = try device.makeComputePipelineState(function: fn)
        } catch {
            print("[Hyperfocus] TileHashComputer: pipeline creation failed: \(error)")
            return nil
        }

        self.device = device
        self.commandQueue = queue
    }

    /// Compute a 2D array of UInt64 hashes (one per 128×128 tile) for `texture`.
    ///
    /// - Returns: `[x][y]` indexed hashes, sized to the texture's tile grid.
    func computeHashes(for texture: MTLTexture) -> [[UInt64]]? {
        let width = Int(texture.width)
        let height = Int(texture.height)
        let cols = (width + tileSize - 1) / tileSize
        let rows = (height + tileSize - 1) / tileSize
        let count = cols * rows
        guard count > 0 else { return [] }

        // Output buffer -- use shared storage on Apple Silicon so the GPU
        // can write directly into CPU-visible memory with no copy.
        let bufferLength = count * MemoryLayout<UInt64>.size
        guard let buffer = device.makeBuffer(
            length: bufferLength,
            options: [.storageModeShared]
        ) else {
            return nil
        }
        // Zero the buffer so partial writes don't leak prior frame data.
        memset(buffer.contents(), 0, bufferLength)

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return nil
        }

        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(texture, index: 0)
        encoder.setBuffer(buffer, offset: 0, index: 0)

        var tilesX = UInt32(cols)
        encoder.setBytes(&tilesX, length: MemoryLayout<UInt32>.size, index: 1)

        let groups = MTLSize(width: cols, height: rows, depth: 1)
        let threads = MTLSize(width: threadsPerSide, height: threadsPerSide, depth: 1)
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threads)
        encoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        // Copy out into a 2D array matching DisplayCache.tileHashes layout.
        let raw = buffer.contents().bindMemory(
            to: UInt64.self, capacity: count)
        var result = Array(
            repeating: Array(repeating: UInt64(0), count: rows),
            count: cols
        )
        for x in 0..<cols {
            for y in 0..<rows {
                result[x][y] = raw[y * cols + x]
            }
        }
        return result
    }
}

// MARK: - Cache Manager (memory pressure + global registry)

/// Process-wide registry of `DisplayCache` instances and the memory-pressure
/// observer that drops or releases their textures under pressure.
///
/// Behaviour:
/// - **WARN**     : mark non-primary caches' textures as `MTLPurgeableState.volatile`
///                  so the driver can reclaim them; primary cache keeps full quality.
/// - **CRITICAL** : release non-primary caches entirely; mark primary cache volatile.
final class CacheManager {
    static let shared = CacheManager()

    private let queue = DispatchQueue(label: "com.hyperfocus.cache-manager", qos: .utility)
    private var caches: [CGDirectDisplayID: DisplayCache] = [:]
    private var primaryDisplayID: CGDirectDisplayID?
    private var pressureSource: DispatchSourceMemoryPressure?

    private init() {
        startMemoryPressureObserver()
    }

    func register(_ cache: DisplayCache, isPrimary: Bool) {
        queue.async {
            self.caches[cache.displayID] = cache
            if isPrimary {
                self.primaryDisplayID = cache.displayID
            }
            cache.isPrimary = isPrimary
        }
    }

    func unregister(_ displayID: CGDirectDisplayID) {
        queue.async {
            self.caches.removeValue(forKey: displayID)
            if self.primaryDisplayID == displayID {
                self.primaryDisplayID = nil
            }
        }
    }

    // MARK: - Memory pressure source

    private func startMemoryPressureObserver() {
        let src = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: queue
        )
        src.setEventHandler { [weak self] in
            guard let self = self else { return }
            let event = src.data
            self.handlePressureEvent(event)
        }
        src.resume()
        self.pressureSource = src
    }

    private func handlePressureEvent(_ event: DispatchSource.MemoryPressureEvent) {
        let isCritical = event.contains(.critical)
        let isWarning = event.contains(.warning)
        guard isCritical || isWarning else { return }

        print("[Hyperfocus] Memory pressure: \(isCritical ? "CRITICAL" : "WARN")")

        let primaryID = primaryDisplayID

        for (id, cache) in caches {
            if isCritical {
                if id != primaryID {
                    // CRITICAL: drop non-primary caches entirely.
                    cache.releaseTextures()
                } else {
                    // Primary: keep around but tell the driver it's evictable.
                    cache.markTexturesVolatile()
                }
            } else {
                // WARN: only mark non-primary as volatile; keep primary resident.
                if id != primaryID {
                    cache.markTexturesVolatile()
                }
            }
        }
    }
}
