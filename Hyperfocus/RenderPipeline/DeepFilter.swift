import Foundation
import simd

// Filter parameter model and preset catalog for Deep mode.
//
// `FilterParameters` is the single source of truth for every visual
// treatment applied after the blur. It is blittable: its memory layout
// matches `FilterUniforms` in BlurDesatShaders.metal field for field
// (see the layout comment there). The renderer harness asserts the encoded
// stride so the two definitions cannot silently drift apart.

/// Post-processing parameters applied to the blurred background.
///
/// Layout contract with Metal (32-bit floats, float3 fields are 16-byte
/// aligned):
///   offset  0: saturation, exposure, blackPoint, contrast
///   offset 16: tintColor (float3)
///   offset 32: tintOpacity
///   offset 48: duotoneA (float3)
///   offset 64: duotoneB (float3)
///   offset 80: duotoneAmount, vignetteStrength, vignetteFeather,
///              grainAmount, grainSeed, bloomAmount
///   stride 112
struct FilterParameters: Equatable {
    /// 0 = grayscale, 1 = original color.
    var saturation: Float = 0.0
    /// Exposure compensation in EV stops (multiplier is 2^exposure).
    var exposure: Float = 0.0
    /// Black-point lift toward white (0 = none, 1 = full white frame).
    var blackPoint: Float = 0.0
    /// Contrast multiplier around mid gray (1 = unchanged).
    var contrast: Float = 1.0
    var tintColor: SIMD3<Float> = .zero
    var tintOpacity: Float = 0.0
    /// Duotone shadow color (luma 0) and highlight color (luma 1).
    var duotoneA: SIMD3<Float> = .zero
    var duotoneB: SIMD3<Float> = .one
    var duotoneAmount: Float = 0.0
    var vignetteStrength: Float = 0.0
    var vignetteFeather: Float = 0.5
    /// Grain amplitude as a multiple of 2/255 per channel (clamped 0...1
    /// in the kernel). Never animated; see `grainSeed`.
    var grainAmount: Float = 0.0
    /// Renderer-managed: derived from the content hash per rendered frame
    /// so identical content always shows identical grain. Callers pass 0.
    var grainSeed: Float = 0.0
    /// Additive highlight bloom strength. Only Bokeh ships with this > 0.
    var bloomAmount: Float = 0.0

    /// Untreated passthrough (used by tests and as a safe fallback).
    static let neutral = FilterParameters(saturation: 1.0)
}

// Codable is hand-written because SIMD3 does not conform to Codable.
extension FilterParameters: Codable {
    private enum CodingKeys: String, CodingKey {
        case saturation, exposure, blackPoint, contrast
        case tintColor, tintOpacity, duotoneA, duotoneB, duotoneAmount
        case vignetteStrength, vignetteFeather, grainAmount, bloomAmount
        // grainSeed is renderer-managed and intentionally not persisted.
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func decodeVector(_ key: CodingKeys) throws -> SIMD3<Float> {
            let values = try c.decode([Float].self, forKey: key)
            guard values.count == 3 else {
                throw DecodingError.dataCorruptedError(
                    forKey: key,
                    in: c,
                    debugDescription: "Expected exactly three color components"
                )
            }
            return SIMD3(values[0], values[1], values[2])
        }

        saturation = try c.decode(Float.self, forKey: .saturation)
        exposure = try c.decode(Float.self, forKey: .exposure)
        blackPoint = try c.decode(Float.self, forKey: .blackPoint)
        contrast = try c.decode(Float.self, forKey: .contrast)
        tintColor = try decodeVector(.tintColor)
        tintOpacity = try c.decode(Float.self, forKey: .tintOpacity)
        duotoneA = try decodeVector(.duotoneA)
        duotoneB = try decodeVector(.duotoneB)
        duotoneAmount = try c.decode(Float.self, forKey: .duotoneAmount)
        vignetteStrength = try c.decode(Float.self, forKey: .vignetteStrength)
        vignetteFeather = try c.decode(Float.self, forKey: .vignetteFeather)
        grainAmount = try c.decode(Float.self, forKey: .grainAmount)
        bloomAmount = try c.decode(Float.self, forKey: .bloomAmount)
        grainSeed = 0
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(saturation, forKey: .saturation)
        try c.encode(exposure, forKey: .exposure)
        try c.encode(blackPoint, forKey: .blackPoint)
        try c.encode(contrast, forKey: .contrast)
        try c.encode([tintColor.x, tintColor.y, tintColor.z], forKey: .tintColor)
        try c.encode(tintOpacity, forKey: .tintOpacity)
        try c.encode([duotoneA.x, duotoneA.y, duotoneA.z], forKey: .duotoneA)
        try c.encode([duotoneB.x, duotoneB.y, duotoneB.z], forKey: .duotoneB)
        try c.encode(duotoneAmount, forKey: .duotoneAmount)
        try c.encode(vignetteStrength, forKey: .vignetteStrength)
        try c.encode(vignetteFeather, forKey: .vignetteFeather)
        try c.encode(grainAmount, forKey: .grainAmount)
        try c.encode(bloomAmount, forKey: .bloomAmount)
    }
}

// MARK: - Preset catalog

enum FilterCategory: String, Codable, CaseIterable {
    case focus
    case presentation

    var displayName: String {
        switch self {
        case .focus: return "Focus"
        case .presentation: return "Presentation"
        }
    }
}

/// A named bundle of post-processing parameters.
///
/// `minimumBlurRadius` is the legibility floor (in display pixels): blur is
/// what destroys background semantics, so a preset never allows the
/// effective radius below its floor no matter where the slider sits.
struct DeepFilter: Equatable, Identifiable {
    let id: String
    let name: String
    let category: FilterCategory
    let parameters: FilterParameters
    let minimumBlurRadius: Double

    static let deepID = "deep"
    static let customID = "custom"

    static let deep = DeepFilter(
        id: deepID, name: "Deep", category: .focus,
        parameters: FilterParameters(saturation: 0.0),
        minimumBlurRadius: 20
    )

    static let ink = DeepFilter(
        id: "ink", name: "Ink", category: .focus,
        parameters: FilterParameters(saturation: 0.0, blackPoint: 0.02, contrast: 1.15),
        minimumBlurRadius: 20
    )

    static let fog = DeepFilter(
        id: "fog", name: "Fog", category: .focus,
        parameters: FilterParameters(saturation: 0.15, exposure: 0.10, blackPoint: 0.18, contrast: 0.92),
        minimumBlurRadius: 20
    )

    static let ember = DeepFilter(
        id: "ember", name: "Ember", category: .focus,
        parameters: FilterParameters(
            saturation: 0.0,
            duotoneA: SIMD3(0.07, 0.03, 0.02),
            duotoneB: SIMD3(1.0, 0.82, 0.55),
            duotoneAmount: 1.0
        ),
        minimumBlurRadius: 20
    )

    static let vignette = DeepFilter(
        id: "vignette", name: "Vignette", category: .focus,
        parameters: FilterParameters(saturation: 0.0, vignetteStrength: 0.35, vignetteFeather: 0.5),
        minimumBlurRadius: 20
    )

    static let paper = DeepFilter(
        id: "paper", name: "Paper", category: .focus,
        parameters: FilterParameters(
            saturation: 0.10,
            tintColor: SIMD3(1.0, 0.96, 0.88),
            tintOpacity: 0.15,
            grainAmount: 1.0
        ),
        minimumBlurRadius: 20
    )

    static let frost = DeepFilter(
        id: "frost", name: "Frost", category: .presentation,
        parameters: FilterParameters(saturation: 0.70, exposure: 0.15, contrast: 0.95, tintColor: .one, tintOpacity: 0.08),
        minimumBlurRadius: 20
    )

    static let bokeh = DeepFilter(
        id: "bokeh", name: "Bokeh", category: .presentation,
        parameters: FilterParameters(saturation: 0.25, exposure: 0.05, bloomAmount: 0.6),
        minimumBlurRadius: 24
    )

    static let catalog: [DeepFilter] = [deep, ink, fog, ember, vignette, paper, frost, bokeh]

    static let focusPresets = catalog.filter { $0.category == .focus }
    static let presentationPresets = catalog.filter { $0.category == .presentation }

    static func withID(_ id: String) -> DeepFilter? {
        catalog.first { $0.id == id }
    }
}

// MARK: - Temporal background modes

/// Controls when the blurred background is allowed to re-render.
/// Motion is the last attention-capture channel left after blur and
/// desaturation; these modes trade background freshness for calm.
enum TemporalMode: String, Codable, CaseIterable, Identifiable {
    /// Re-render whenever background content changes (previous behavior).
    case live
    /// Coalesce changes: re-render at most once per `settledInterval`.
    case settled
    /// Render once, then hold until parameters change or Deep mode re-toggles.
    case frozen

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .live: return "Live"
        case .settled: return "Settled"
        case .frozen: return "Frozen"
        }
    }

    var subtitle: String {
        switch self {
        case .live: return "Background follows changes in real time"
        case .settled: return "Background updates every few seconds"
        case .frozen: return "Background stays a still image; calmest and most efficient"
        }
    }

    /// Coalescing interval for `.settled`, in seconds.
    static let settledInterval: TimeInterval = 5.0
}

// MARK: - Custom filter (preset fork)

/// A Custom filter is a named preset the user forked by editing an override
/// slider. It keeps the base preset id (for the blur-radius floor and for
/// "reset to preset" behavior) plus the full edited parameter set.
struct CustomFilter: Codable, Equatable {
    var baseID: String
    var parameters: FilterParameters
}

// MARK: - Settings resolution

struct ResolvedDeepSettings: Equatable {
    /// Selected catalog identifier (`custom` for a forked preset).
    var filterID: String
    /// Effective blur radius in display pixels (slider value floored by the
    /// base preset's `minimumBlurRadius`).
    var blurRadius: Double
    var parameters: FilterParameters
    var temporalMode: TemporalMode
    var isCustom: Bool
}

enum DeepSettings {
    static let filterIDKey = "deepFilterID"
    static let deepBlurRadiusKey = "deepBlurRadius"
    static let temporalModeKey = "temporalMode"
    static let overridesKey = "filterOverrides"
    static let migratedKey = "filterSettingsMigrated"
    static let legacyBlurRadiusKey = "blurRadius"
    static let legacySaturationKey = "saturation"
    static let defaultBlurRadius: Double = 20
    static let maximumBlurRadius: Double = 48
    static let defaultFramesPerSecond = 10

    /// Normalizes persisted or imported blur values before they reach the UI
    /// or MPS. A non-finite value falls back to the product default; finite
    /// values retain their intent within the slider's supported range.
    static func sanitizedBlurRadius(_ value: Double) -> Double {
        guard value.isFinite else { return defaultBlurRadius }
        return min(max(value, 0), maximumBlurRadius)
    }

    /// Studio and Custom-filter saturation are both represented as a unit
    /// interval. Keeping this check centralized prevents imported settings
    /// from causing a trapping `Int` conversion in the Settings UI.
    static func sanitizedSaturation(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }

    /// `0` historically means an unset frame-rate preference, so preserve its
    /// established default rather than treating it as one frame per second.
    static func sanitizedFramesPerSecond(_ value: Int) -> Int {
        guard value > 0 else { return defaultFramesPerSecond }
        return min(value, 30)
    }

    /// Imported Custom payloads are untrusted data. The shipped UI currently
    /// exposes only saturation, but every shader uniform is normalized here so
    /// malformed JSON cannot introduce NaN, infinity, or unstable extremes.
    static func sanitizedParameters(_ parameters: FilterParameters) -> FilterParameters {
        func bounded(_ value: Float, _ range: ClosedRange<Float>, fallback: Float) -> Float {
            guard value.isFinite else { return fallback }
            return min(max(value, range.lowerBound), range.upperBound)
        }
        func color(_ value: SIMD3<Float>, fallback: SIMD3<Float>) -> SIMD3<Float> {
            SIMD3(
                bounded(value.x, 0...1, fallback: fallback.x),
                bounded(value.y, 0...1, fallback: fallback.y),
                bounded(value.z, 0...1, fallback: fallback.z)
            )
        }

        var result = parameters
        result.saturation = bounded(result.saturation, 0...1, fallback: 0)
        result.exposure = bounded(result.exposure, -2...2, fallback: 0)
        result.blackPoint = bounded(result.blackPoint, 0...0.95, fallback: 0)
        result.contrast = bounded(result.contrast, 0.1...2, fallback: 1)
        result.tintColor = color(result.tintColor, fallback: .zero)
        result.tintOpacity = bounded(result.tintOpacity, 0...1, fallback: 0)
        result.duotoneA = color(result.duotoneA, fallback: .zero)
        result.duotoneB = color(result.duotoneB, fallback: .one)
        result.duotoneAmount = bounded(result.duotoneAmount, 0...1, fallback: 0)
        result.vignetteStrength = bounded(result.vignetteStrength, 0...1, fallback: 0)
        result.vignetteFeather = bounded(result.vignetteFeather, 0.05...1, fallback: 0.5)
        result.grainAmount = bounded(result.grainAmount, 0...1, fallback: 0)
        result.grainSeed = 0
        result.bloomAmount = bounded(result.bloomAmount, 0...1, fallback: 0)
        return result
    }

    /// Decodes, validates, and re-encodes a persisted Custom override. Invalid
    /// payloads intentionally become nil, which makes the resolver use Deep.
    static func sanitizedCustomFilterData(_ data: Data?) -> Data? {
        guard let data,
              var custom = try? JSONDecoder().decode(CustomFilter.self, from: data),
              DeepFilter.withID(custom.baseID) != nil
        else {
            return nil
        }
        custom.parameters = sanitizedParameters(custom.parameters)
        return try? JSONEncoder().encode(custom)
    }

    /// One-time migration: copy the old shared blur-radius and saturation
    /// values into Deep-specific state. Either nondefault legacy override
    /// becomes a Custom filter seeded from Deep, so existing users retain the
    /// exact intent they had before presets existed. Legacy keys remain only
    /// for downgrade safety and are never read by Deep mode after migration.
    static func migrateIfNeeded(_ defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: migratedKey) else { return }

        let legacyRadius = sanitizedBlurRadius(
            defaults.object(forKey: legacyBlurRadiusKey) as? Double ?? defaultBlurRadius
        )
        let legacySaturation = sanitizedSaturation(
            defaults.object(forKey: legacySaturationKey) as? Double ?? 0.0
        )
        defaults.set(legacyRadius, forKey: deepBlurRadiusKey)
        defaults.set(TemporalMode.live.rawValue, forKey: temporalModeKey)

        let radiusChanged = legacyRadius != defaultBlurRadius
        let saturationChanged = legacySaturation != Double(DeepFilter.deep.parameters.saturation)
        if radiusChanged || saturationChanged {
            var parameters = DeepFilter.deep.parameters
            parameters.saturation = Float(legacySaturation)
            let custom = CustomFilter(baseID: DeepFilter.deepID, parameters: parameters)
            if let data = try? JSONEncoder().encode(custom) {
                defaults.set(data, forKey: overridesKey)
                defaults.set(customID, forKey: filterIDKey)
            }
        } else {
            defaults.set(DeepFilter.deepID, forKey: filterIDKey)
        }

        defaults.set(true, forKey: migratedKey)
    }

    static let customID = DeepFilter.customID

    /// Resolves the stored settings (preset id + optional Custom overrides +
    /// legacy sliders) into the concrete values the engine renders with.
    static func resolve(_ defaults: UserDefaults = .standard) -> ResolvedDeepSettings {
        migrateIfNeeded(defaults)

        let userRadius = sanitizedBlurRadius(
            defaults.object(forKey: deepBlurRadiusKey) as? Double ?? defaultBlurRadius
        )
        let mode = TemporalMode(rawValue: defaults.string(forKey: temporalModeKey) ?? "") ?? .live
        let id = defaults.string(forKey: filterIDKey) ?? DeepFilter.deepID

        if id == customID,
           let data = defaults.data(forKey: overridesKey),
           let custom = try? JSONDecoder().decode(CustomFilter.self, from: data) {
            let base = DeepFilter.withID(custom.baseID) ?? .deep
            return ResolvedDeepSettings(
                filterID: customID,
                blurRadius: max(userRadius, base.minimumBlurRadius),
                parameters: sanitizedParameters(custom.parameters),
                temporalMode: mode,
                isCustom: true
            )
        }

        let preset = DeepFilter.withID(id) ?? .deep
        return ResolvedDeepSettings(
            filterID: preset.id,
            blurRadius: max(userRadius, preset.minimumBlurRadius),
            parameters: preset.parameters,
            temporalMode: mode,
            isCustom: false
        )
    }
}
