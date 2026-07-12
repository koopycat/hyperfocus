#include <metal_stdlib>
using namespace metal;

/// Tile size used by the tile-hash kernel and the CachingEngine.
/// One threadgroup per 128×128 tile; each thread processes an 8×8 block.
constant uint kHashTileSize = 128;
constant uint kHashTileBlockSize = 8;
constant uint kHashThreadsPerSide = 16; // 16×16 = 256 threads per group

/// Per-tile content hash.
///
/// One threadgroup is dispatched per 128×128 tile. Each thread reads an
/// 8×8 block of pixels, folds them into a 64-bit accumulator using a
/// multiplicative additive hash, then a threadgroup reduction sums the
/// 256 partial hashes into a single UInt64 stored in `hashes`.
///
/// The hash is intentionally cheap (not cryptographic) -- fast enough to
/// run on every captured frame and good enough to detect per-tile change
/// in the CachingEngine's dirty-region logic.
kernel void computeTileHashes(
    texture2d<float, access::read> src         [[texture(0)]],
    device uint64_t*              hashes       [[buffer(0)]],
    constant uint&                tilesX       [[buffer(1)]],
    uint2 tid [[thread_position_in_threadgroup]],
    uint2 gid [[threadgroup_position_in_grid]])
{
    // 256-partial-hash reduction buffer
    threadgroup uint64_t partial[16 * 16];

    const uint tileOriginX = gid.x * kHashTileSize;
    const uint tileOriginY = gid.y * kHashTileSize;

    const uint localIndex = tid.y * kHashThreadsPerSide + tid.x;

    // Sample 8×8 block: thread (tx,ty) handles pixels in
    // (tx*8..tx*8+7, ty*8..ty*8+7) of the tile.
    uint64_t threadHash = 0;

    const uint width = src.get_width();
    const uint height = src.get_height();

    for (uint dy = 0; dy < kHashTileBlockSize; dy++) {
        uint py = tileOriginY + tid.y * kHashTileBlockSize + dy;
        if (py >= height) break;

        for (uint dx = 0; dx < kHashTileBlockSize; dx++) {
            uint px = tileOriginX + tid.x * kHashTileBlockSize + dx;
            if (px >= width) break;

            float4 c = src.read(uint2(px, py));

            // Pack to 24-bit RGB and multiply-add with a spatial mix
            uint r = uint(saturate(c.r) * 255.0);
            uint g = uint(saturate(c.g) * 255.0);
            uint b = uint(saturate(c.b) * 255.0);
            uint packed = (r << 16) | (g << 8) | b;

            // Prime multiplier + per-pixel position offset yields
            // a hash that changes when any pixel changes
            uint64_t k = 1099511628211ull; // FNV-style 64-bit prime
            uint64_t coord = (uint64_t(px) << 32) ^ uint64_t(py);
            threadHash = threadHash * k + uint64_t(packed) + coord;
        }
    }

    partial[localIndex] = threadHash;
    threadgroup_barrier(mem_flags::mem_threadgroup);

    // Tree reduction across 256 entries (8 levels of halving).
    if (localIndex < 128) partial[localIndex] += partial[localIndex + 128];
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (localIndex < 64)  partial[localIndex] += partial[localIndex + 64];
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (localIndex < 32)  partial[localIndex] += partial[localIndex + 32];
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (localIndex < 16)  partial[localIndex] += partial[localIndex + 16];
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (localIndex < 8)   partial[localIndex] += partial[localIndex + 8];
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (localIndex < 4)   partial[localIndex] += partial[localIndex + 4];
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (localIndex < 2)   partial[localIndex] += partial[localIndex + 2];
    threadgroup_barrier(mem_flags::mem_threadgroup);

    if (localIndex == 0) {
        uint64_t finalHash = partial[0] + partial[1];

        // Mix in tile coordinates so neighbouring tiles with identical
        // pixel content still hash to different values.
        finalHash ^= (uint64_t(gid.x) << 32) ^ uint64_t(gid.y);

        hashes[uint(gid.y) * tilesX + uint(gid.x)] = finalHash;
    }
}

/// Fused Gaussian blur + BT.709 desaturation in a single compute pass.
///
/// blurRadius: Gaussian sigma in pixels (applied at quarter-res, visually ≈ 4× at full-res)
/// saturation: 0.0 = full grayscale, 1.0 = original color
kernel void blurAndDesaturate(
    texture2d<float, access::read>  src     [[texture(0)]],
    texture2d<float, access::write> dst     [[texture(1)]],
    constant float& blurRadius             [[buffer(0)]],
    constant float& saturation             [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    uint width = dst.get_width();
    uint height = dst.get_height();

    if (gid.x >= width || gid.y >= height) return;

    int radius = int(blurRadius);
    float sigma = max(float(radius) / 2.0, 0.001);

    // Horizontal pass: sample along x-axis
    float4 hSum = float4(0);
    float hWeightSum = 0;

    for (int dx = -radius; dx <= radius; dx++) {
        uint sx = uint(clamp(int(gid.x) + dx, 0, int(width - 1)));
        float4 sample = src.read(uint2(sx, gid.y));

        float d = float(dx);
        float w = exp(-(d * d) / (2.0 * sigma * sigma));

        hSum += sample * w;
        hWeightSum += w;
    }

    float4 blurred = hSum / hWeightSum;

    // BT.709 luminance desaturation (fused into the kernel -- no extra pass)
    float luma = dot(blurred.rgb, float3(0.2126, 0.7152, 0.0722));
    blurred.rgb = mix(float3(luma), blurred.rgb, saturation);

    dst.write(blurred, gid);
}

/// Bilinearly upscales the quarter-res processed texture to full display
/// resolution. Manual 4-tap bilinear with edge clamping (no sampler required,
/// so it behaves uniformly as a compute kernel).
///
/// Reads from the quarter-res blurred/desaturated texture and writes a
/// smoothly interpolated full-res result.
kernel void bilinearUpscale(
    texture2d<float, access::read>  src [[texture(0)]],
    texture2d<float, access::write> dst [[texture(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    uint dstW = dst.get_width();
    uint dstH = dst.get_height();
    if (gid.x >= dstW || gid.y >= dstH) return;

    float2 srcSize = float2(src.get_width(), src.get_height());
    float2 dstSize = float2(dstW, dstH);

    // Map destination pixel center to a source pixel-center coordinate.
    float2 srcCoord = (float2(gid) + 0.5) * (srcSize / dstSize) - 0.5;

    int x0 = int(floor(srcCoord.x));
    int y0 = int(floor(srcCoord.y));
    int x1 = x0 + 1;
    int y1 = y0 + 1;

    float fx = srcCoord.x - float(x0);
    float fy = srcCoord.y - float(y0);

    int maxSX = int(srcSize.x) - 1;
    int maxSY = int(srcSize.y) - 1;

    uint sx0 = uint(clamp(x0, 0, maxSX));
    uint sx1 = uint(clamp(x1, 0, maxSX));
    uint sy0 = uint(clamp(y0, 0, maxSY));
    uint sy1 = uint(clamp(y1, 0, maxSY));

    float4 c00 = src.read(uint2(sx0, sy0));
    float4 c10 = src.read(uint2(sx1, sy0));
    float4 c01 = src.read(uint2(sx0, sy1));
    float4 c11 = src.read(uint2(sx1, sy1));

    float4 top    = mix(c00, c10, fx);
    float4 bottom = mix(c01, c11, fx);
    float4 result = mix(top, bottom, fy);

    dst.write(result, gid);
}
