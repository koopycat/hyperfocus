import Foundation

/// Manages license validation for Pro features.
/// Supports Gumroad license keys, App Store IAP receipts, and 7-day free trial.
final class LicenseManager: ObservableObject {
    static let shared = LicenseManager()

    enum LicenseState {
        case free
        case trial(daysLeft: Int)
        case pro
    }

    @Published private(set) var state: LicenseState = .free

    private let trialDurationDays = 7
    private let trialStartKey = "com.hyperfocus.trialStartDate"
    private let hasStartedTrialKey = "com.hyperfocus.hasStartedTrial"
    private let proLicenseKey = "com.hyperfocus.proLicenseKey"

    private init() {
        state = hasStoredGumroadLicense ? .pro : checkTrialStatus()
    }

    // MARK: - Feature Gating

    var isProFeatureAvailable: Bool {
        if case .pro = state { return true }
        let refreshedState = checkTrialStatus()
        state = refreshedState
        if case .trial = refreshedState { return true }
        return false
    }

    // MARK: - Trial

    @discardableResult
    func startTrial() -> Bool {
        let currentState = checkTrialStatus()
        if case .trial = currentState {
            state = currentState
            return true
        }

        guard !UserDefaults.standard.bool(forKey: hasStartedTrialKey) else {
            state = .free
            return false
        }

        let now = Date()
        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: trialStartKey)
        UserDefaults.standard.set(true, forKey: hasStartedTrialKey)
        state = .trial(daysLeft: trialDurationDays)
        return true
    }

    func checkTrialStatus() -> LicenseState {
        guard let startTimestamp = UserDefaults.standard.value(forKey: trialStartKey) as? TimeInterval else {
            return .free
        }

        let start = Date(timeIntervalSince1970: startTimestamp)
        let elapsed = Calendar.current.dateComponents([.day], from: start, to: Date()).day ?? 0
        let remaining = trialDurationDays - elapsed

        if remaining <= 0 {
            UserDefaults.standard.removeObject(forKey: trialStartKey)
            return .free
        }

        return .trial(daysLeft: remaining)
    }

    // MARK: - Gumroad License Validation

    /// Validates a Gumroad license key locally via a checksum.
    /// This is an honor-system check: the key format is verified but
    /// there is no server-side activation. Gumroad API integration
    /// is deferred to post-MVP.
    func validateGumroadKey(_ key: String) -> Bool {
        let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isLocallyValidGumroadKey(normalizedKey) else { return false }

        UserDefaults.standard.set(normalizedKey, forKey: proLicenseKey)
        state = .pro
        return true
    }

    private var hasStoredGumroadLicense: Bool {
        guard let key = UserDefaults.standard.string(forKey: proLicenseKey) else { return false }
        guard isLocallyValidGumroadKey(key) else {
            UserDefaults.standard.removeObject(forKey: proLicenseKey)
            return false
        }
        return true
    }

    private func isLocallyValidGumroadKey(_ key: String) -> Bool {
        let components = key.components(separatedBy: "-")
        guard components.count == 4, components.allSatisfy({ !$0.isEmpty }) else { return false }
        let checksum = components.joined().utf8.reduce(0) { $0 + Int($1) }
        return checksum % 97 == 0
    }

    // MARK: - App Store IAP

    func validateAppStoreReceipt() -> Bool {
        guard let receiptURL = Bundle.main.appStoreReceiptURL else { return false }
        let receiptExists = FileManager.default.fileExists(atPath: receiptURL.path)
        if receiptExists { state = .pro }
        return receiptExists
    }
}
