#include <metal_stdlib>
using namespace metal;

/// Post-processing parameter block. MUST match the Swift `FilterParameters`
/// struct in DeepFilter.swift field for field (the renderer harness asserts
/// the layout):
///   offset  0: saturation, exposure, blackPoint, contrast
///   offset 16: tintColor (float3, 16-byte aligned)
///   offset 32: tintOpacity
///   offset 48: duotoneA (float3)
///   offset 64: duotoneB (float3)
///   offset 80: duotoneAmount, vignetteStrength, vignetteFeather,
///              grainAmount, grainSeed, bloomAmount
///   stride 112
struct FilterUniforms {
    float saturation;      // 0 = grayscale, 1 = original color
    float exposure;        // EV stops, multiplier is 2^exposure
    float blackPoint;      // lift toward white
    float contrast;        // around mid gray, 1 = unchanged
    float3 tintColor;
    float tintOpacity;
    float3 duotoneA;       // shadow color (luma 0)
    float3 duotoneB;       // highlight color (luma 1)
    float duotoneAmount;
    float vignetteStrength;
    float vignetteFeather;
    float grainAmount;     // multiple of 2/255 per channel, clamped to 1
    float grainSeed;       // renderer-managed, static per rendered frame
    float bloomAmount;     // additive highlight bloom strength
};

constant float3 kLuma709 = float3(0.2126, 0.7152, 0.0722);

/// Fused post-processing kernel.
///
/// Reads the pre-blurred texture and applies the full filter chain in a
/// fixed order: exposure, black-point lift, contrast, saturation, duotone,
/// tint, additive bloom, vignette, grain. Grain runs last so vignette does
/// not darken it unevenly. Blur is handled upstream by MPS; bloom arrives
/// pre-blurred in `bloomTex` (a dummy binding when `bloomAmount == 0`, the
/// branch short-circuits before any sample).
///
/// Every operation is a pure function of the source pixel: no time-varying
/// state, so a static frame always produces a pixel-identical result.
kernel void postProcess(
    texture2d<float, access::read>   src      [[texture(0)]],
    texture2d<float, access::write>  dst      [[texture(1)]],
    texture2d<float, access::sample> bloomTex [[texture(2)]],
    constant FilterUniforms&         u        [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= src.get_width() || gid.y >= src.get_height()) return;
    constexpr sampler linearSamp(filter::linear, address::clamp_to_edge, coord::normalized);

    float4 color = src.read(gid);
    float3 c = color.rgb;

    // Exposure compensation.
    c *= exp2(u.exposure);

    // Black-point lift (Fog's milky fade).
    c = c * (1.0 - u.blackPoint) + u.blackPoint;

    // Contrast around mid gray.
    c = (c - 0.5) * u.contrast + 0.5;
    c = clamp(c, 0.0, 1.0);

    // BT.709 saturation.
    float luma = dot(c, kLuma709);
    c = mix(float3(luma), c, u.saturation);

    // Duotone mapping over the pre-tint luminance.
    if (u.duotoneAmount > 0.0) {
        float3 duo = mix(u.duotoneA, u.duotoneB, luma);
        c = mix(c, duo, u.duotoneAmount);
    }

    // Solid tint wash.
    if (u.tintOpacity > 0.0) {
        c = mix(c, u.tintColor, u.tintOpacity);
    }

    // Additive highlight bloom. Sits before vignette so edge bloom is
    // dimmed by the vignette like everything else (lens behavior).
    if (u.bloomAmount > 0.0) {
        float2 uv = (float2(gid) + 0.5) / float2(src.get_width(), src.get_height());
        c += bloomTex.sample(linearSamp, uv).rgb * u.bloomAmount;
    }

    // Vignette: falloff computed in normalized screen space, which makes
    // it elliptical in physical space and therefore fitted to the display
    // shape (important on ultrawides; r ~ 1.41 in corners everywhere).
    if (u.vignetteStrength > 0.0) {
        float2 uv = (float2(gid) + 0.5) / float2(src.get_width(), src.get_height());
        float2 q = (uv - 0.5) * 2.0;
        float r = length(q);
        float v = smoothstep(1.0 - u.vignetteFeather, 1.4142, r);
        c *= 1.0 - v * u.vignetteStrength;
    }

    // Static grain, re-seeded per rendered frame by the renderer (never on
    // a timer). Masks 8-bit banding on blurred gradients.
    if (u.grainAmount > 0.0) {
        float n = fract(sin(dot(float2(gid) + u.grainSeed, float2(12.9898, 78.233))) * 43758.5453);
        c += (n * 2.0 - 1.0) * min(u.grainAmount, 1.0) * (2.0 / 255.0);
    }

    dst.write(float4(clamp(c, 0.0, 1.0), color.a), gid);
}

/// Highlight extraction for the bloom stage.
///
/// Reads the blurred full-resolution texture and writes a half-resolution
/// texture containing only energy above `threshold`, scaled by how far the
/// pixel exceeds it. The result is blurred by MPS and composited additively
/// in `postProcess`.
kernel void bloomThreshold(
    texture2d<float, access::read>  src        [[texture(0)]],
    texture2d<float, access::write> dst        [[texture(1)]],
    constant float&                 threshold  [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;

    uint2 sgid = min(gid * 2, uint2(src.get_width() - 1, src.get_height() - 1));
    float3 c = src.read(sgid).rgb;
    float luma = dot(c, kLuma709);
    float k = max(luma - threshold, 0.0) / max(luma, 1e-4);
    dst.write(float4(c * k, 1.0), gid);
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
