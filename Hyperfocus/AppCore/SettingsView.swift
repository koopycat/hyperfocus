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

struct HyperfocusSettings: Codable {
    var blurRadius: Double
    var saturation: Double
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
            blurRadius: defaults.object(forKey: "blurRadius") as? Double ?? 20,
            saturation: defaults.object(forKey: "saturation") as? Double ?? 0,
            tintColorData: defaults.data(forKey: "tintColorData"),
            launchAtLogin: defaults.bool(forKey: "launchAtLogin"),
            focusMode: defaults.string(forKey: "hyperfocusMode"),
            blurFPS: defaults.integer(forKey: "blurFPS"),
            excludedApps: (try? JSONDecoder().decode([String].self, from: defaults.data(forKey: "excludedApps") ?? Data())) ?? [],
            appGroups: (try? JSONDecoder().decode([NamedGroup].self, from: defaults.data(forKey: "appGroups") ?? Data())) ?? [],
            perDisplay: (try? JSONDecoder().decode([DisplaySetting].self, from: defaults.data(forKey: "perDisplaySettings") ?? Data())) ?? []
        )
    }

    func apply() {
        let defaults = UserDefaults.standard
        defaults.set(blurRadius, forKey: "blurRadius")
        defaults.set(saturation, forKey: "saturation")
        defaults.set(tintColorData, forKey: "tintColorData")
        defaults.set(launchAtLogin, forKey: "launchAtLogin")
        defaults.set(focusMode, forKey: "hyperfocusMode")
        defaults.set(blurFPS, forKey: "blurFPS")
        defaults.set(try? JSONEncoder().encode(excludedApps), forKey: "excludedApps")
        defaults.set(try? JSONEncoder().encode(appGroups), forKey: "appGroups")
        defaults.set(try? JSONEncoder().encode(perDisplay), forKey: "perDisplaySettings")
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @AppStorage("blurRadius") private var blurRadius: Double = 20
    @AppStorage("saturation") private var saturation: Double = 0.0
    @AppStorage("tintColorData") private var tintColorData: Data?
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
                blurRadius: $blurRadius,
                saturation: $saturation,
                selectedTint: $selectedTint
            )
            .tabItem { Label("Effects", systemImage: "camera.filters") }

            ExclusionsTab()
                .tabItem { Label("Exclusions", systemImage: "list.bullet.rectangle") }

            DisplaysTab()
                .tabItem { Label("Displays", systemImage: "display") }

            LicenseTab()
                .tabItem { Label("License", systemImage: "key") }
        }
        .frame(width: 520, height: 380)
        .onAppear(perform: loadTintColor)
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
    @Binding var selectedTint: Color
    @AppStorage("blurFPS") private var blurFPS: Int = 10

    var body: some View {
        Form {
            VStack(alignment: .leading, spacing: 4) {
                Text("Blur Radius: \(Int(blurRadius))")
                    .font(.body)
                Slider(value: $blurRadius, in: 0...60, step: 1)
                Text("Higher = softer background")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Saturation: \(Int(saturation * 100))%")
                    .font(.body)
                Slider(value: $saturation, in: 0...1, step: 0.05)
                Text("0% = full grayscale background")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Blur Frame Rate: \(blurFPS) FPS")
                    .font(.body)
                Slider(value: Binding(
                    get: { Double(blurFPS) },
                    set: { blurFPS = Int($0) }
                ), in: 1...30, step: 1)
                Text("Lower = less GPU / more battery")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            ColorPicker("Studio Dim Color", selection: $selectedTint)

            Spacer()
        }
        .padding()
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
        settings = Dictionary(uniqueKeysWithValues: decoded.map { ($0.id, $0) })
    }

    private func save() {
        perDisplayData = try? JSONEncoder().encode(Array(settings.values))
    }
}

// MARK: - License Tab

struct LicenseTab: View {
    @StateObject private var licenseManager = LicenseManager.shared
    @AppStorage("hyperfocusMode") private var focusMode: String = HyperfocusMode.studio.rawValue
    @State private var licenseKey: String = ""
    @State private var message: String?

    private var licenseStatus: String {
        switch licenseManager.state {
        case .free:
            return "Free Tier: Studio Mode Active"
        case .trial(let daysLeft):
            return "Pro Trial: \(daysLeft) day\(daysLeft == 1 ? "" : "s") remaining"
        case .pro:
            return "Pro: Active"
        }
    }

    var body: some View {
        Form {
            Text(licenseStatus)
                .font(.headline)

            TextField("License Key", text: $licenseKey)
                .textFieldStyle(.roundedBorder)

            HStack {
                Button("Activate Pro") {
                    if licenseManager.validateGumroadKey(licenseKey) {
                        focusMode = HyperfocusMode.deep.rawValue
                        message = "Pro activated on this Mac."
                    } else {
                        message = "That license key could not be validated."
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(licenseKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button("Try Pro Free for 7 Days") {
                    if licenseManager.startTrial() {
                        focusMode = HyperfocusMode.deep.rawValue
                        message = "Your Pro trial is active."
                    } else {
                        message = "The free trial has already been used on this Mac."
                    }
                }
                .buttonStyle(.bordered)
            }

            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Divider()

            Text("Pro unlocks live blur. Screen Share, App Groups, and per-display blur overrides are not yet available.")
                .font(.caption)
                .foregroundColor(.secondary)

            Spacer()
        }
        .padding()
    }
}
