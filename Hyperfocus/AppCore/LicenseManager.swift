import Foundation
import Security

/// Manages license validation for Pro features.
/// Supports Gumroad license keys, App Store IAP receipts, and 7-day free trial.
final class LicenseManager: ObservableObject {
    static let shared = LicenseManager()

    enum LicenseState {
        case free          // Studio mode only
        case trial(daysLeft: Int)  // Pro features, temporary
        case pro           // Purchased
    }

    @Published private(set) var state: LicenseState = .free

    private let trialDurationDays = 7
    private let trialStartKey = "com.hyperfocus.trialStartDate"
    private let hasStartedTrialKey = "com.hyperfocus.hasStartedTrial"

    /// A license is per Mac and must not be copied to another device via an
    /// iCloud Keychain sync or a backup restore.
    private let keychainService = "com.hyperfocus.app.license"
    private let keychainAccount = "gumroad-license"

    private init() {
        state = hasStoredGumroadLicense ? .pro : checkTrialStatus()
    }

    // MARK: - Feature Gating

    var isProFeatureAvailable: Bool {
        if case .pro = state {
            return true
        }

        let refreshedState = checkTrialStatus()
        state = refreshedState
        if case .trial = refreshedState {
            return true
        }
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

    func validateGumroadKey(_ key: String) -> Bool {
        let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isLocallyValidGumroadKey(normalizedKey), storeGumroadLicense(normalizedKey) else {
            return false
        }

        state = .pro
        return true
    }

    private var hasStoredGumroadLicense: Bool {
        guard let key = storedGumroadLicense() else { return false }
        guard isLocallyValidGumroadKey(key) else {
            removeStoredGumroadLicense()
            return false
        }
        return true
    }

    private func isLocallyValidGumroadKey(_ key: String) -> Bool {
        // Gumroad uses four hyphen-separated key segments. This local checksum
        // is a development placeholder until validation is performed by Gumroad.
        let components = key.components(separatedBy: "-")
        guard components.count == 4, components.allSatisfy({ !$0.isEmpty }) else { return false }

        let checksum = components.joined().utf8.reduce(0) { $0 + Int($1) }
        return checksum % 97 == 0
    }

    // MARK: - Keychain persistence

    private func storedGumroadLicense() -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: keychainAccount,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]

        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }

        return String(data: data, encoding: .utf8)
    }

    private func storeGumroadLicense(_ key: String) -> Bool {
        guard let data = key.data(using: .utf8) else { return false }

        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: keychainAccount
        ]
        let attributes: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else { return false }

        var newItem = query
        for (attribute, value) in attributes {
            newItem[attribute] = value
        }
        return SecItemAdd(newItem as CFDictionary, nil) == errSecSuccess
    }

    private func removeStoredGumroadLicense() {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: keychainAccount
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - App Store IAP

    func validateAppStoreReceipt() -> Bool {
        // Production: Validate receipt with App Store using Bundle.main.appStoreReceiptURL
        // For now, check if receipt exists
        guard let receiptURL = Bundle.main.appStoreReceiptURL else { return false }
        let receiptExists = FileManager.default.fileExists(atPath: receiptURL.path)

        if receiptExists {
            state = .pro
        }
        return receiptExists
    }
}
