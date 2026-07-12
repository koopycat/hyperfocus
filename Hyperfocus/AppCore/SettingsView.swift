import SwiftUI
import UniformTypeIdentifiers

// MARK: - Settings Models

struct NamedGroup: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var bundleIdentifiers: [String]
}

struct DisplaySetting: Codable, Identifiable, Equatable {
    var id: String
    var displayName: String
    var enabled: Bool = true
    var customOpacity: Double?
}

/// Canonicalizes imported display settings before they touch SwiftUI state.
/// `Dictionary(uniqueKeysWithValues:)` traps on duplicate keys, so an import
/// must collapse duplicates even when it originated from a hand-edited file.
private func normalizedDisplaySettings(_ settings: [DisplaySetting]) -> [DisplaySetting] {
    var unique: [String: DisplaySetting] = [:]
    for var setting in settings where !setting.id.isEmpty {
        if let opacity = setting.customOpacity {
            setting.customOpacity = opacity.isFinite ? min(max(opacity, 0), 1) : nil
        }
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
    var appGroups: [NamedGroup]
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
            appGroups: (try? JSONDecoder().decode([NamedGroup].self, from: defaults.data(forKey: "appGroups") ?? Data())) ?? [],
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
        defaults.set(try? JSONEncoder().encode(appGroups), forKey: "appGroups")
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
    @AppStorage("launchAtLogin") private var launchAtLogin: Bool = false
    @AppStorage("excludedApps") private var excludedAppsData: Data?
    @AppStorage("appGroups") private var appGroupsData: Data?
    @AppStorage("perDisplaySettings") private var perDisplayData: Data?

    @State private var selectedTint: Color = .clear

    var body: some View {
        TabView {
            GeneralTab()
                .tabItem { Label("General", systemImage: "gearshape") }

            EffectsTab(
                blurRadius: $deepBlurRadius,
                saturation: $saturation,
                deepFilterID: $deepFilterID,
                temporalMode: $temporalMode,
                filterOverrides: $filterOverrides,
                selectedTint: $selectedTint
            )
            .tabItem { Label("Effects", systemImage: "camera.filters") }

            ExclusionsTab()
                .tabItem { Label("Exclusions", systemImage: "list.bullet.rectangle") }

            DisplaysTab()
                .tabItem { Label("Displays", systemImage: "display") }

            GroupsTab()
                .tabItem { Label("Groups", systemImage: "rectangle.3.group") }
        }
        .frame(width: 520, height: 540)
        .onAppear {
            DeepSettings.migrateIfNeeded()
            loadTintColor()
        }
        .onChange(of: selectedTint) { newValue in
            let color = NSColor(newValue)
            tintColorData = try? NSKeyedArchiver.archivedData(
                withRootObject: color,
                requiringSecureCoding: true
            )
        }
    }

    private func loadTintColor() {
        guard let tintColorData,
              let color = try? NSKeyedUnarchiver.unarchivedObject(
                  ofClass: NSColor.self,
                  from: tintColorData
              )
        else { return }
        selectedTint = Color(nsColor: color)
    }
}

// MARK: - General Tab

struct GeneralTab: View {
    @AppStorage("launchAtLogin") private var launchAtLogin: Bool = false
    @AppStorage("hyperfocusMode") private var focusMode: String = HyperfocusMode.studio.rawValue

    var body: some View {
        Form {
            Picker("Focus Mode", selection: $focusMode) {
                ForEach(HyperfocusMode.allCases) { mode in
                    Text(mode.displayName).tag(mode.rawValue)
                }
            }

            Toggle("Launch at Login", isOn: $launchAtLogin)

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

    var body: some View {
        Form {
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
                Text("A minimum blur is retained so background text stays unreadable.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Filter Saturation: \(Int(DeepSettings.sanitizedSaturation(saturationBinding.wrappedValue) * 100))%")
                    .font(.body)
                Slider(value: saturationBinding, in: 0...1, step: 0.05)
                Text("Adjusting a slider creates a Custom filter without changing the original preset.")
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
                Text("Blur Frame Rate: \(DeepSettings.sanitizedFramesPerSecond(blurFPS)) FPS")
                    .font(.body)
                Slider(value: Binding(
                    get: { Double(DeepSettings.sanitizedFramesPerSecond(blurFPS)) },
                    set: { blurFPS = DeepSettings.sanitizedFramesPerSecond(Int($0)) }
                ), in: 1...30, step: 1)
                Text("Lower = less GPU / more battery")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Studio Saturation: \(Int(studioSaturationBinding.wrappedValue * 100))%")
                    .font(.body)
                Slider(value: studioSaturationBinding, in: 0...1, step: 0.05)
                Text("Used only by the permission-free Studio mode.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            ColorPicker("Studio Dim Color", selection: $selectedTint)

            Spacer()
        }
        .padding()
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
    @AppStorage("excludedApps") private var excludedAppsData: Data?
    @State private var excludedApps: [String] = []
    @State private var isShowingRunningAppPicker = false

    var body: some View {
        Form {
            Text("Apps that should not trigger focus mode:")
                .font(.body)

            List {
                ForEach(excludedApps, id: \.self) { app in
                    Text(app)
                }
                .onDelete { indexSet in
                    excludedApps.remove(atOffsets: indexSet)
                    save()
                }
            }

            Button("Add Running App...") {
                isShowingRunningAppPicker = true
            }

            Spacer()
        }
        .padding()
        .onAppear(perform: load)
        .sheet(isPresented: $isShowingRunningAppPicker) {
            RunningApplicationPicker(excludedBundleIdentifiers: excludedApps) { bundleIdentifier in
                guard !excludedApps.contains(bundleIdentifier) else { return }
                excludedApps.append(bundleIdentifier)
                excludedApps.sort()
                save()
            }
        }
    }

    private func load() {
        guard let data = excludedAppsData,
              let decoded = try? JSONDecoder().decode([String].self, from: data)
        else { return }
        excludedApps = decoded
    }

    private func save() {
        excludedAppsData = try? JSONEncoder().encode(excludedApps)
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

// MARK: - Groups Tab

struct GroupsTab: View {
    @AppStorage("appGroups") private var appGroupsData: Data?
    @State private var groups: [NamedGroup] = []
    @State private var editingGroup: NamedGroup?

    var body: some View {
        Form {
            List {
                ForEach(groups) { group in
                    HStack {
                        Text(group.name)
                        Spacer()
                        Text("\(group.bundleIdentifiers.count) apps")
                            .foregroundColor(.secondary)
                        Button("Edit") { editingGroup = group }
                    }
                }
                .onDelete { indexSet in
                    groups.remove(atOffsets: indexSet)
                    save()
                }
            }

            HStack {
                Button("Add Group") {
                    let newGroup = NamedGroup(name: "New Group", bundleIdentifiers: [])
                    groups.append(newGroup)
                    editingGroup = newGroup
                    save()
                }
                Spacer()
            }

            Spacer()
        }
        .padding()
        .onAppear(perform: load)
        .sheet(item: $editingGroup, onDismiss: save) { group in
            if let index = groups.firstIndex(where: { $0.id == group.id }) {
                GroupEditor(group: $groups[index])
            }
        }
    }

    private func load() {
        guard let data = appGroupsData,
              let decoded = try? JSONDecoder().decode([NamedGroup].self, from: data)
        else { return }
        groups = decoded
    }

    private func save() {
        appGroupsData = try? JSONEncoder().encode(groups)
    }
}

struct GroupEditor: View {
    @Binding var group: NamedGroup
    @State private var newIdentifier: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit Group").font(.headline)

            TextField("Group Name", text: $group.name)

            Text("Bundle Identifiers")
                .font(.subheadline)

            List {
                ForEach(group.bundleIdentifiers, id: \.self) { id in
                    Text(id)
                }
                .onDelete { indexSet in
                    group.bundleIdentifiers.remove(atOffsets: indexSet)
                }
            }

            HStack {
                TextField("com.example.app", text: $newIdentifier)
                Button("Add") {
                    guard !newIdentifier.isEmpty else { return }
                    group.bundleIdentifiers.append(newIdentifier)
                    newIdentifier = ""
                }
            }

            Spacer()
        }
        .padding()
        .frame(width: 360, height: 280)
    }
}

// MARK: - Displays Tab

struct DisplaysTab: View {
    @State private var screens: [NSScreen] = []
    @AppStorage("perDisplaySettings") private var perDisplayData: Data?
    @State private var settings: [String: DisplaySetting] = [:]

    var body: some View {
        Form {
            Text("Configure focus behavior per display")
                .font(.headline)

            List(screens, id: \.displayID) { screen in
                let key = String(screen.displayID)
                HStack {
                    Text(screen.localizedName)
                    Spacer()
                    Toggle("Enabled", isOn: Binding(
                        get: { settings[key]?.enabled ?? true },
                        set: { newValue in
                            var setting = settings[key] ?? DisplaySetting(
                                id: key,
                                displayName: screen.localizedName,
                                enabled: newValue
                            )
                            setting.enabled = newValue
                            settings[key] = setting
                            save()
                        }
                    ))
                }
            }

            Spacer()
        }
        .padding()
        .onAppear {
            screens = NSScreen.screens
            load()
        }
    }

    private func load() {
        guard let data = perDisplayData,
              let decoded = try? JSONDecoder().decode([DisplaySetting].self, from: data)
        else { return }
        settings = Dictionary(
            normalizedDisplaySettings(decoded).map { ($0.id, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
    }

    private func save() {
        perDisplayData = try? JSONEncoder().encode(Array(settings.values))
    }
}

