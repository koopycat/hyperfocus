#include <metal_stdlib>
using namespace metal;

/// BT.709 desaturation kernel.
///
/// Reads a pre-blurred texture and mixes each pixel toward grayscale using the
/// BT.709 luminance coefficients.  Blur is handled upstream by MPS.
///
/// saturation: 0.0 = full grayscale, 1.0 = original color
kernel void desaturate(
    texture2d<float, access::read>  src         [[texture(0)]],
    texture2d<float, access::write> dst         [[texture(1)]],
    constant float&                 saturation  [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= src.get_width() || gid.y >= src.get_height()) return;

    float4 color = src.read(gid);

    float luma = dot(color.rgb, float3(0.2126, 0.7152, 0.0722));
    color.rgb = mix(float3(luma), color.rgb, saturation);

    dst.write(color, gid);
}

/// Scene-change detection hash.
///
/// Computes a single 64-bit FNV-style hash over a strided sample grid of the
/// captured frame.  Pixels inside `skipRect` (the active-window cutout, in
/// capture pixels) are excluded: the focused window shows through the mask
/// hole live and unprocessed, so its content must not count as "background
/// change".  Typing in the focused window on an otherwise static desktop
/// therefore does not trigger re-renders.
///
/// Rendering and presenting the result is by far the most expensive part of
/// the Deep-mode pipeline (full-screen recomposite by WindowServer), so a
/// cheap hash that lets us skip unchanged frames saves nearly all steady-state
/// GPU work.
///
/// Dispatched as a single threadgroup of kHashThreads threads; each thread
/// folds a strided subset of pixels into an accumulator, then a tree
/// reduction merges the partials into out[0].
///
/// The quantization from unorm float back to 8-bit is not perfectly exact,
/// but it is fully deterministic -- identical input always produces the same
/// hash, which is all change detection requires.
///
/// skipRect: (x, y, width, height) in pixels; width == 0 disables skipping.
constant uint kHashThreads = 256;
constant uint kSampleStride = 2;

kernel void frameHash(
    texture2d<float, access::read> src      [[texture(0)]],
    device uint64_t*               out      [[buffer(0)]],
    constant uint4&                skipRect [[buffer(1)]],
    uint tid [[thread_index_in_threadgroup]])
{
    const uint width = src.get_width();
    const uint height = src.get_height();
    const uint samplesPerRow = (width + kSampleStride - 1) / kSampleStride;
    const uint totalSamples = samplesPerRow * ((height + kSampleStride - 1) / kSampleStride);

    const uint skipX = skipRect.x;
    const uint skipY = skipRect.y;
    const uint skipMaxX = skipRect.x + skipRect.z;
    const uint skipMaxY = skipRect.y + skipRect.w;
    const bool skipEnabled = skipRect.z > 0;

    uint64_t acc = 1469598103934665603ull; // FNV offset basis

    for (uint i = tid; i < totalSamples; i += kHashThreads) {
        uint x = (i % samplesPerRow) * kSampleStride;
        uint y = (i / samplesPerRow) * kSampleStride;

        if (skipEnabled && x >= skipX && x < skipMaxX && y >= skipY && y < skipMaxY) {
            continue;
        }

        float4 c = src.read(uint2(x, y));
        uint r = uint(saturate(c.r) * 255.0);
        uint g = uint(saturate(c.g) * 255.0);
        uint b = uint(saturate(c.b) * 255.0);
        uint64_t packed = uint64_t((r << 16) | (g << 8) | b);

        acc = (acc ^ packed) * 1099511628211ull; // FNV prime
    }

    // Tree reduction across the threadgroup.
    threadgroup uint64_t partial[kHashThreads];
    partial[tid] = acc;
    threadgroup_barrier(mem_flags::mem_threadgroup);

    for (uint offset = kHashThreads / 2; offset > 0; offset >>= 1) {
        if (tid < offset) {
            // XOR keeps the reduction order-independent (unlike +, no carry
            // concerns) and is plenty for change detection.
            partial[tid] = partial[tid] * 1099511628211ull + partial[tid + offset];
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }

    if (tid == 0) {
        out[0] = partial[0];
    }
}
