import SwiftUI
import UniformTypeIdentifiers

// MARK: - Settings Models

struct DisplaySetting: Codable, Identifiable, Equatable {
    var id: String
    var displayName: String
    var enabled: Bool = true
}

/// Canonicalizes imported display settings before they touch SwiftUI state.
/// `Dictionary(uniqueKeysWithValues:)` traps on duplicate keys, so an import
/// must collapse duplicates even when it originated from a hand-edited file.
private func normalizedDisplaySettings(_ settings: [DisplaySetting]) -> [DisplaySetting] {
    var unique: [String: DisplaySetting] = [:]
    for setting in settings where !setting.id.isEmpty {
        unique[setting.id] = setting
    }
    return unique.values.sorted { $0.id < $1.id }
}

struct HyperfocusSettings: Codable {
    /// Legacy pre-filter Deep blur setting, retained in exports for downgrade.
    var blurRadius: Double
    var saturation: Double
    var deepBlurRadius: Double?
    var deepFilterID: String?
    var temporalMode: String?
    var filterOverrides: Data?
    var tintColorData: Data?
    var launchAtLogin: Bool
    var focusMode: String?
    var blurFPS: Int
    var excludedApps: [String]
    var perDisplay: [DisplaySetting]
}

extension HyperfocusSettings {
    static func current() -> HyperfocusSettings {
        let defaults = UserDefaults.standard
        return HyperfocusSettings(
            blurRadius: DeepSettings.sanitizedBlurRadius(
                defaults.object(forKey: "blurRadius") as? Double ?? DeepSettings.defaultBlurRadius
            ),
            saturation: DeepSettings.sanitizedSaturation(
                defaults.object(forKey: "saturation") as? Double ?? 0
            ),
            deepBlurRadius: (defaults.object(forKey: DeepSettings.deepBlurRadiusKey) as? Double)
                .map { DeepSettings.sanitizedBlurRadius($0) },
            deepFilterID: defaults.string(forKey: DeepSettings.filterIDKey),
            temporalMode: defaults.string(forKey: DeepSettings.temporalModeKey),
            filterOverrides: DeepSettings.sanitizedCustomFilterData(
                defaults.data(forKey: DeepSettings.overridesKey)
            ),
            tintColorData: defaults.data(forKey: "tintColorData"),
            launchAtLogin: defaults.bool(forKey: "launchAtLogin"),
            focusMode: defaults.string(forKey: "hyperfocusMode"),
            blurFPS: DeepSettings.sanitizedFramesPerSecond(defaults.integer(forKey: "blurFPS")),
            excludedApps: (try? JSONDecoder().decode([String].self, from: defaults.data(forKey: "excludedApps") ?? Data())) ?? [],
            perDisplay: normalizedDisplaySettings(
                (try? JSONDecoder().decode(
                    [DisplaySetting].self,
                    from: defaults.data(forKey: "perDisplaySettings") ?? Data()
                )) ?? []
            )
        )
    }

    func apply() {
        let defaults = UserDefaults.standard
        defaults.set(DeepSettings.sanitizedBlurRadius(blurRadius), forKey: "blurRadius")
        defaults.set(DeepSettings.sanitizedSaturation(saturation), forKey: "saturation")

        if let deepFilterID, let deepBlurRadius {
            let overrides = DeepSettings.sanitizedCustomFilterData(filterOverrides)
            let filterID: String
            if deepFilterID == DeepFilter.customID, overrides != nil {
                filterID = DeepFilter.customID
            } else if let preset = DeepFilter.withID(deepFilterID) {
                filterID = preset.id
            } else {
                filterID = DeepFilter.deepID
            }

            // Set the values the resolver reads before publishing the filter
            // id, whose KVO observer can trigger a live Deep transition.
            defaults.set(
                DeepSettings.sanitizedBlurRadius(deepBlurRadius),
                forKey: DeepSettings.deepBlurRadiusKey
            )
            defaults.set(
                TemporalMode(rawValue: temporalMode ?? "")?.rawValue ?? TemporalMode.live.rawValue,
                forKey: DeepSettings.temporalModeKey
            )
            if filterID == DeepFilter.customID, let overrides {
                defaults.set(overrides, forKey: DeepSettings.overridesKey)
            } else {
                defaults.removeObject(forKey: DeepSettings.overridesKey)
            }
            defaults.set(true, forKey: DeepSettings.migratedKey)
            defaults.set(filterID, forKey: DeepSettings.filterIDKey)
        } else {
            // Importing a pre-filter export deliberately re-runs the legacy
            // migration so its radius and saturation seed a Custom filter.
            defaults.removeObject(forKey: DeepSettings.filterIDKey)
            defaults.removeObject(forKey: DeepSettings.deepBlurRadiusKey)
            defaults.removeObject(forKey: DeepSettings.temporalModeKey)
            defaults.removeObject(forKey: DeepSettings.overridesKey)
            defaults.removeObject(forKey: DeepSettings.migratedKey)
        }

        defaults.set(tintColorData, forKey: "tintColorData")
        defaults.set(launchAtLogin, forKey: "launchAtLogin")
        defaults.set(
            focusMode.flatMap(HyperfocusMode.init(rawValue:))?.rawValue,
            forKey: "hyperfocusMode"
        )
        defaults.set(DeepSettings.sanitizedFramesPerSecond(blurFPS), forKey: "blurFPS")
        defaults.set(try? JSONEncoder().encode(excludedApps), forKey: "excludedApps")
        defaults.set(
            try? JSONEncoder().encode(normalizedDisplaySettings(perDisplay)),
            forKey: "perDisplaySettings"
        )
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @AppStorage(DeepSettings.deepBlurRadiusKey) private var deepBlurRadius: Double = DeepSettings.defaultBlurRadius
    @AppStorage("saturation") private var saturation: Double = 0.0
    @AppStorage("tintColorData") private var tintColorData: Data?
    @AppStorage(DeepSettings.filterIDKey) private var deepFilterID: String = DeepFilter.deepID
    @AppStorage(DeepSettings.temporalModeKey) private var temporalMode: String = TemporalMode.live.rawValue
    @AppStorage(DeepSettings.overridesKey) private var filterOverrides: Data?
    @AppStorage("hyperfocusMode") private var focusMode: String = HyperfocusMode.studio.rawValue

    private var mode: HyperfocusMode {
        HyperfocusMode(rawValue: focusMode) ?? .studio
    }

    private var tintSelection: Binding<Color> {
        Binding(
            get: {
                guard let tintColorData,
                      let color = try? NSKeyedUnarchiver.unarchivedObject(
                          ofClass: NSColor.self, from: tintColorData
                      )
                else { return .black }
                return Color(nsColor: color)
            },
            set: { color in
                tintColorData = try? NSKeyedArchiver.archivedData(
                    withRootObject: NSColor(color).withAlphaComponent(1),
                    requiringSecureCoding: true
                )
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                Picker("Focus Mode", selection: $focusMode) {
                    ForEach(HyperfocusMode.allCases) { mode in
                        Text(mode.displayName).tag(mode.rawValue)
                    }
                }
                .frame(width: 190)

                VStack(alignment: .leading, spacing: 2) {
                    Text(mode.headline)
                    Text(mode.detail)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding()

            Divider()

            TabView {
                GeneralTab()
                    .tabItem { Label("General", systemImage: "gearshape") }

                EffectsTab(
                    mode: mode,
                    blurRadius: $deepBlurRadius,
                    saturation: $saturation,
                    deepFilterID: $deepFilterID,
                    temporalMode: $temporalMode,
                    filterOverrides: $filterOverrides,
                    selectedTint: tintSelection
                )
                .tabItem { Label("Effects", systemImage: "camera.filters") }

                ExclusionsTab()
                    .tabItem { Label("Exclusions", systemImage: "list.bullet.rectangle") }

                DisplaysTab()
                    .tabItem { Label("Displays", systemImage: "display") }
            }
        }
        .frame(width: 520, height: 540)
        .onAppear { DeepSettings.migrateIfNeeded() }
    }

}

// MARK: - General Tab

struct GeneralTab: View {
    @AppStorage("launchAtLogin") private var launchAtLogin: Bool = false

    var body: some View {
        Form {
            if #available(macOS 13.0, *) {
                Toggle("Launch at Login", isOn: $launchAtLogin)
            } else {
                Text("Launch at Login requires macOS 13 or later.")
                    .foregroundColor(.secondary)
            }

            HStack {
                Button("Export Settings...") { exportSettings() }
                Button("Import Settings...") { importSettings() }
                Spacer()
            }

            Spacer()
        }
        .padding()
    }

    private func exportSettings() {
        let settings = HyperfocusSettings.current()
        guard let data = try? JSONEncoder().encode(settings) else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "hyperfocus-settings.json"
        panel.begin { result in
            guard result == .OK, let url = panel.url else { return }
            do {
                try data.write(to: url)
            } catch {
                print("[Hyperfocus] Failed to export settings: \(error)")
            }
        }
    }

    private func importSettings() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.begin { result in
            guard result == .OK, let url = panel.url,
                  let data = try? Data(contentsOf: url),
                  let settings = try? JSONDecoder().decode(HyperfocusSettings.self, from: data)
            else { return }
            settings.apply()
        }
    }
}

// MARK: - Effects Tab

struct EffectsTab: View {
    let mode: HyperfocusMode
    @Binding var blurRadius: Double
    @Binding var saturation: Double
    @Binding var deepFilterID: String
    @Binding var temporalMode: String
    @Binding var filterOverrides: Data?
    @Binding var selectedTint: Color
    @AppStorage("blurFPS") private var blurFPS: Int = 10

    private var customFilter: CustomFilter? {
        guard let filterOverrides,
              var custom = try? JSONDecoder().decode(CustomFilter.self, from: filterOverrides)
        else {
            return nil
        }
        custom.parameters = DeepSettings.sanitizedParameters(custom.parameters)
        return custom
    }

    private var activeCustomFilter: CustomFilter? {
        deepFilterID == DeepFilter.customID ? customFilter : nil
    }

    /// For Custom, use the preset it forked from so its legibility floor is
    /// retained even when the user adjusts raw sliders.
    private var basePreset: DeepFilter {
        if let activeCustomFilter,
           let preset = DeepFilter.withID(activeCustomFilter.baseID) {
            return preset
        }
        return DeepFilter.withID(deepFilterID) ?? .deep
    }

    private var displayedParameters: FilterParameters {
        activeCustomFilter?.parameters ?? basePreset.parameters
    }

    private var effectiveBlurRadius: Double {
        max(DeepSettings.sanitizedBlurRadius(blurRadius), basePreset.minimumBlurRadius)
    }

    private var currentTemporalMode: TemporalMode {
        TemporalMode(rawValue: temporalMode) ?? .live
    }

    private var filterSelection: Binding<String> {
        Binding(
            get: { deepFilterID },
            set: selectFilter
        )
    }

    private var blurRadiusBinding: Binding<Double> {
        Binding(
            get: { effectiveBlurRadius },
            set: { value in
                if deepFilterID != DeepFilter.customID {
                    forkToCustom()
                }
                blurRadius = DeepSettings.sanitizedBlurRadius(value)
            }
        )
    }

    private var saturationBinding: Binding<Double> {
        Binding(
            get: { Double(displayedParameters.saturation) },
            set: { value in
                var custom = activeCustomFilter ?? CustomFilter(
                    baseID: basePreset.id,
                    parameters: displayedParameters
                )
                custom.parameters.saturation = Float(DeepSettings.sanitizedSaturation(value))
                custom.parameters.grainSeed = 0
                saveCustom(custom)
            }
        )
    }

    private var studioSaturationBinding: Binding<Double> {
        Binding(
            get: { DeepSettings.sanitizedSaturation(saturation) },
            set: { saturation = DeepSettings.sanitizedSaturation($0) }
        )
    }

    private var usesSourceColors: Bool {
        displayedParameters.duotoneAmount < 1 && displayedParameters.tintOpacity < 1
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if mode == .studio {
                    studioControls
                } else {
                    deepControls
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
    }

    private var deepControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Picker("Deep Filter", selection: filterSelection) {
                    Section(header: Text("Focus")) {
                        ForEach(DeepFilter.focusPresets) { filter in
                            Text(filter.name).tag(filter.id)
                        }
                    }
                    Section(header: Text("Presentation")) {
                        ForEach(DeepFilter.presentationPresets) { filter in
                            Text(filter.name).tag(filter.id)
                        }
                    }
                    Section {
                        Text("Custom").tag(DeepFilter.customID)
                    }
                }
                Text("Focus filters remove more attention-capturing detail. Presentation filters prioritize a polished shared screen.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Blur Radius: \(Int(effectiveBlurRadius))")
                    .font(.body)
                Slider(value: blurRadiusBinding, in: basePreset.minimumBlurRadius...48, step: 1)
                    .accessibilityLabel("Blur Radius")
                Text("A minimum blur keeps background text unreadable. Adjusting a slider creates a Custom filter.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Filter Saturation: \(Int(DeepSettings.sanitizedSaturation(saturationBinding.wrappedValue) * 100))%")
                    .font(.body)
                Slider(value: saturationBinding, in: 0...1, step: 0.05)
                    .disabled(!usesSourceColors)
                    .accessibilityLabel("Filter Saturation")
                Text(usesSourceColors
                     ? "Adjusting a slider creates a Custom filter without changing the original preset."
                     : "This filter replaces source colors, so saturation has no effect.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Picker("Background Updates", selection: $temporalMode) {
                    ForEach(TemporalMode.allCases) { mode in
                        Text(mode.displayName).tag(mode.rawValue)
                    }
                }
                Text(currentTemporalMode.subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Capture Rate Limit: \(DeepSettings.sanitizedFramesPerSecond(blurFPS)) FPS")
                    .font(.body)
                Slider(value: Binding(
                    get: { Double(DeepSettings.sanitizedFramesPerSecond(blurFPS)) },
                    set: { blurFPS = DeepSettings.sanitizedFramesPerSecond(Int($0)) }
                ), in: 1...30, step: 1)
                    .disabled(currentTemporalMode == .frozen)
                    .accessibilityLabel("Capture Rate Limit")
                Text(currentTemporalMode == .frozen
                     ? "Frozen holds a still image and manages capture automatically. Switch to Live or Settled to adjust this limit."
                     : "Maximum capture rate, not visible updates per second. Lower limits save energy; power and thermal limits may reduce it further.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

        }
    }

    private var studioControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Studio Saturation: \(Int(studioSaturationBinding.wrappedValue * 100))%")
                    .font(.body)
                Slider(value: studioSaturationBinding, in: 0...1, step: 0.05)
                    .accessibilityLabel("Studio Saturation")
                Text("Reduce background color without capturing your screen.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            ColorPicker("Studio Dim Color", selection: $selectedTint, supportsOpacity: false)
            Text("Studio uses a fixed dim strength; this changes its color only.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private func selectFilter(_ id: String) {
        if id == DeepFilter.customID {
            if deepFilterID != DeepFilter.customID {
                forkToCustom()
            }
            return
        }

        guard let preset = DeepFilter.withID(id) else { return }
        deepFilterID = preset.id
        filterOverrides = nil
    }

    private func forkToCustom() {
        let custom = CustomFilter(baseID: basePreset.id, parameters: displayedParameters)
        saveCustom(custom)
    }

    private func saveCustom(_ custom: CustomFilter) {
        filterOverrides = try? JSONEncoder().encode(custom)
        deepFilterID = DeepFilter.customID
    }
}

// MARK: - Exclusions Tab

struct ExclusionsTab: View {
    @AppStorage("excludedApps") private var excludedAppsData: Data = Data()
    @State private var isShowingRunningAppPicker = false

    private var excludedApps: [String] {
        (try? JSONDecoder().decode([String].self, from: excludedAppsData)) ?? []
    }

    var body: some View {
        Form {
            Text("Pause the effect while one of these apps is frontmost:")
                .font(.body)

            List {
                ForEach(excludedApps, id: \.self) { app in
                    Text(app)
                }
                .onDelete { indexSet in
                    var apps = excludedApps
                    apps.remove(atOffsets: indexSet)
                    save(apps)
                }
            }

            Button("Add Running App...") {
                isShowingRunningAppPicker = true
            }

            Spacer()
        }
        .padding()
        .sheet(isPresented: $isShowingRunningAppPicker) {
            RunningApplicationPicker(excludedBundleIdentifiers: excludedApps) { bundleIdentifier in
                guard !excludedApps.contains(bundleIdentifier) else { return }
                save((excludedApps + [bundleIdentifier]).sorted())
            }
        }
    }


    private func save(_ apps: [String]) {
        if let data = try? JSONEncoder().encode(apps) {
            excludedAppsData = data
        }
    }
}

private struct RunningApplicationPicker: View {
    struct Application: Identifiable {
        let bundleIdentifier: String
        let name: String

        var id: String { bundleIdentifier }
    }

    let excludedBundleIdentifiers: [String]
    let onSelect: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    private var applications: [Application] {
        let applications = NSWorkspace.shared.runningApplications.compactMap { app -> Application? in
            guard app.activationPolicy == .regular,
                  let bundleIdentifier = app.bundleIdentifier
            else { return nil }
            return Application(
                bundleIdentifier: bundleIdentifier,
                name: app.localizedName ?? bundleIdentifier
            )
        }

        return Dictionary(
            applications.map { ($0.bundleIdentifier, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        .values
        .filter { !excludedBundleIdentifiers.contains($0.bundleIdentifier) }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose an App to Exclude")
                .font(.headline)

            if applications.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "app.dashed")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text("No eligible running apps")
                        .font(.headline)
                    Text("Launch an app first, then return here.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(applications) { app in
                    Button {
                        onSelect(app.bundleIdentifier)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(app.name)
                            Text(app.bundleIdentifier)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
            }
        }
        .padding()
        .frame(width: 400, height: 360)
    }
}

// MARK: - Displays Tab

struct DisplaysTab: View {
    @State private var screens: [NSScreen] = []
    @AppStorage("perDisplaySettings") private var perDisplayData: Data = Data()

    private var settings: [String: DisplaySetting] {
        let decoded = (try? JSONDecoder().decode([DisplaySetting].self, from: perDisplayData)) ?? []
        return Dictionary(
            normalizedDisplaySettings(decoded).map { ($0.id, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
    }

    var body: some View {
        let currentSettings = settings
        return Form {
            Text("Choose which displays receive the focus effect")
                .font(.headline)

            List(screens, id: \.displayID) { screen in
                let key = String(screen.displayID)
                HStack {
                    Text(screen.localizedName)
                    Spacer()
                    Toggle("Enabled", isOn: Binding(
                        get: { currentSettings[key]?.enabled ?? true },
                        set: { newValue in
                            var updated = settings
                            var setting = updated[key] ?? DisplaySetting(
                                id: key,
                                displayName: screen.localizedName,
                                enabled: newValue
                            )
                            setting.enabled = newValue
                            updated[key] = setting
                            if let data = try? JSONEncoder().encode(Array(updated.values)) {
                                perDisplayData = data
                            }
                        }
                    ))
                    .accessibilityLabel("Apply focus effect to \(screen.localizedName)")
                }
            }

            Spacer()
        }
        .padding()
        .onAppear {
            screens = NSScreen.screens
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            screens = NSScreen.screens
        }
    }

}

