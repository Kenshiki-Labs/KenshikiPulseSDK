import CryptoKit
import Foundation
import Security

struct TelephonyDataServiceSnapshot: Equatable, Sendable {
    var available: Bool
    var changeCount: Int?
}

/// Tracks only changes in CoreTelephony's opaque data-service key. The key itself is never persisted
/// or exported; UserDefaults stores a per-install salted token plus a cumulative local count.
enum TelephonyDataServiceTracker {
    private enum Key {
        static let token = "kenshiki.telephony.dataService.token.v1"
        static let changeCount = "kenshiki.telephony.dataService.changeCount.v1"
    }

    static func observe(identifier: String?, defaults: UserDefaults = .standard) -> TelephonyDataServiceSnapshot {
        guard let identifier, !identifier.isEmpty else {
            return TelephonyDataServiceSnapshot(available: false, changeCount: nil)
        }

        return observe(identifier: identifier, salt: TelephonyDataServiceSalt.loadOrCreate(), defaults: defaults)
    }

    static func observe(identifier: String, salt: Data, defaults: UserDefaults) -> TelephonyDataServiceSnapshot {
        let nextToken = token(for: identifier, salt: salt)
        let priorToken = defaults.string(forKey: Key.token)
        var changeCount = max(0, defaults.integer(forKey: Key.changeCount))

        if priorToken == nil {
            defaults.set(nextToken, forKey: Key.token)
        } else if priorToken != nextToken {
            changeCount += 1
            defaults.set(changeCount, forKey: Key.changeCount)
            defaults.set(nextToken, forKey: Key.token)
        }

        return TelephonyDataServiceSnapshot(available: true, changeCount: changeCount)
    }

    static func reset(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: Key.token)
        defaults.removeObject(forKey: Key.changeCount)
    }

    static func resetForTesting(defaults: UserDefaults = .standard) {
        reset(defaults: defaults)
    }

    private static func token(for identifier: String, salt: Data) -> String {
        var data = salt
        data.append(Data(identifier.utf8))
        let digest = SHA256.hash(data: data)
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

enum TelephonyDataServiceSalt {
    private static let service = "com.kenshiki.device.telephony.data-service.salt.v1"
    private static let account = "default"
    private static let byteCount = 32

    static func loadOrCreate() -> Data {
        if let existing = load() { return existing }
        let salt = randomSalt()
        store(salt)
        return salt
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func load() -> Data? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, data.count == byteCount else {
            return nil
        }
        return data
    }

    private static func store(_ salt: Data) {
        var attributes = baseQuery()
        attributes[kSecValueData as String] = salt
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemDelete(baseQuery() as CFDictionary)
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func clear() {
        SecItemDelete(baseQuery() as CFDictionary)
    }

    private static func randomSalt() -> Data {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        if SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes) != errSecSuccess {
            return SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        }
        return Data(bytes)
    }
}
