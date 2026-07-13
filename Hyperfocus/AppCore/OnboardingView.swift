import Cocoa
import SwiftUI

// MARK: - Hyperfocus Mode

/// The two focus modes available. Both are always free — no paywall.
enum HyperfocusMode: String, CaseIterable, Identifiable, Codable {
    case studio
    case deep

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .studio: return "Studio"
        case .deep: return "Deep"
        }
    }

    var headline: String {
        switch self {
        case .studio: return "Dim Background"
        case .deep: return "Full Blur"
        }
    }

    var detail: String {
        switch self {
        case .studio: return "Zero permissions needed"
        case .deep: return "Requires Screen Recording permission"
        }
    }

    var symbolName: String {
        switch self {
        case .studio: return "circle.lefthalf.filled"
        case .deep: return "drop.fill"
        }
    }
}

// MARK: - Onboarding View

/// First-launch onboarding for Hyperfocus. Lets the user pick a focus mode
/// (Studio or Deep). All features are free — no trial or license needed.
struct OnboardingView: View {
    @State private var selectedMode: HyperfocusMode = .studio
    @State private var hasFinished: Bool = false

    let onFinished: (HyperfocusMode) -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            modeSelector
            Divider()
            featuresPanel
            Divider()
            footer
        }
        .frame(width: 560, height: 580)
        .background(Color(NSColor.windowBackgroundColor))
        .onDisappear(perform: finish)
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "eye.slash.circle.fill")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.tint)
                .padding(.top, 4)

            Text("Welcome to Hyperfocus")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Distraction-free focus for your Mac")
                .font(.title3)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 28)
        .padding(.bottom, 22)
    }

    // MARK: - Mode Selector

    private var modeSelector: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose your focus mode")
                .font(.headline)

            HStack(spacing: 14) {
                ForEach(HyperfocusMode.allCases) { mode in
                    ModeCard(
                        mode: mode,
                        isSelected: selectedMode == mode,
                        onSelect: { selectedMode = mode }
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 28)
        .padding(.vertical, 22)
    }

    // MARK: - Features Panel

    private var featuresPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch selectedMode {
            case .studio:
                studioFeatures
            case .deep:
                deepFeatures
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 28)
        .padding(.vertical, 20)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private var studioFeatures: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: HyperfocusMode.studio.symbolName)
                    .foregroundStyle(.tint)
                Text("Studio Mode")
                    .font(.headline)
            }

            featureRow(icon: "moon.fill",
                       text: "Dim the background to reduce visual noise")
            featureRow(icon: "circle.lefthalf.filled",
                       text: "Use a neutral dim to reduce visual noise")
            featureRow(icon: "rectangle.dashed",
                       text: "Keep the active window clear and live")
            featureRow(icon: "display.2",
                       text: "Enable or disable the effect per display")
            featureRow(icon: "lock.shield.fill",
                       text: "No permissions required — starts instantly")
        }
    }

    private var deepFeatures: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: HyperfocusMode.deep.symbolName)
                    .foregroundStyle(.tint)
                Text("Deep Mode")
                    .font(.headline)
            }

            featureRow(icon: "drop.fill",
                       text: "Full Gaussian blur hides everything but your work")
            featureRow(icon: "wand.and.stars",
                       text: "Customizable blur radius, saturation, and tint")
            featureRow(icon: "rectangle.connected.to.line.below",
                       text: "Screen Recording permission required for live capture")
            featureRow(icon: "rectangle.dashed",
                       text: "Rounded cutout keeps the focused window clear")
            featureRow(icon: "lock.shield.fill",
                       text: "Screen Recording permission is used only for live blur")
        }
    }

    private func featureRow(icon: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon)
                .frame(width: 20, alignment: .center)
                .foregroundStyle(.tint)
            Text(text)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 10) {
            Button(action: finish) {
                Text("Get Started")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 2)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)

            Text("You can switch modes any time in Settings.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
    }

    // MARK: - Actions

    private func finish() {
        guard !hasFinished else { return }
        hasFinished = true
        onFinished(selectedMode)
    }
}

// MARK: - Mode Card

struct ModeCard: View {
    let mode: HyperfocusMode
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center) {
                    Image(systemName: mode.symbolName)
                        .font(.title2)
                        .foregroundStyle(.tint)
                    Spacer()
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundColor(isSelected ? .accentColor : .secondary)
                }

                Text(mode.displayName)
                    .font(.title3)
                    .fontWeight(.semibold)

                Text(mode.headline)
                    .font(.headline)

                Text(mode.detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(NSColor.controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        isSelected ? Color.accentColor : Color.gray.opacity(0.3),
                        lineWidth: isSelected ? 2 : 1
                    )
            )
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(mode.displayName), \(mode.detail)")
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}
