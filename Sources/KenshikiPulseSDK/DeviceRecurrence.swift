import CryptoKit
import Foundation
import Security

/// Privacy-preserving **device recurrence token** — a salted, tenant-scoped, rotating pseudonym that
/// lets a relying party answer "have I seen this device before?" *without* any raw device identifier,
/// and without two tenants being able to correlate the same device.
///
/// Construction (rotation policy "B"): `HMAC-SHA256(key: installSalt, message: domain | scope | epoch)`,
/// base64url-encoded. Three deliberate properties:
///
/// 1. **Salted & install-local.** The HMAC key is a 32-byte CSPRNG salt minted once per install and
///    held in the Keychain (`...AfterFirstUnlockThisDeviceOnly` — the same accessibility class as the
///    device signing key and the Wi-Fi continuity salt). It is never egressed and cannot be reversed
///    to a hardware identifier. Because it lives in the Keychain it survives app delete + reinstall on
///    the same device, so a returning device stays recognizable; it does **not** migrate to a new
///    device.
/// 2. **Tenant-scoped.** Folding the tenant id into the HMAC message means the same physical device
///    presents a *different* token to each tenant — one tenant can spot a returning device in its own
///    data, but tenants cannot collude (or be breached) to link a device across companies. When no
///    tenant id is supplied the token is install-scoped (`scope == "install"`): fine for a
///    single-tenant integration, but pass a tenant id in any multi-tenant deployment.
/// 3. **Rotating with overlap.** `epoch = floor(now / rotationDays)`. Each receipt carries the
///    `current` token and the `previous` (`epoch − 1`) token so a relying party can chain across a
///    rotation boundary, while an absence longer than one window breaks the link → forward privacy.
///
/// The receipt is embedded in the signed `DeviceEvidenceEnvelope`, so it is tamper-evident for free.
public enum DeviceRecurrence {
    static let domainSeparator = "kenshiki.device.recurrence.v1"
    static let installScopeMarker = "__install__"
    static let algorithm = "hmac-sha256-tenant-epoch-v1"
    static let secondsPerDay = 86_400

    /// Derive the recurrence receipt for this device, tenant, and moment. Pure and deterministic given
    /// the salt, so it is directly unit-testable via ``token(salt:scope:epoch:)``.
    public static func derive(
        tenantId: String?,
        rotationDays: Int = 90,
        now: Date = Date()
    ) -> DeviceRecurrenceReceipt {
        derive(
            salt: DeviceRecurrenceSalt.loadOrCreate(),
            tenantId: tenantId,
            rotationDays: rotationDays,
            now: now
        )
    }

    /// Salt-injecting core — pure and deterministic, so the rotation/scoping invariants are testable
    /// without touching the Keychain.
    static func derive(
        salt: Data,
        tenantId: String?,
        rotationDays: Int,
        now: Date
    ) -> DeviceRecurrenceReceipt {
        let safeRotationDays = max(1, rotationDays)
        let scope = scopeValue(for: tenantId)
        let epoch = self.epoch(now: now, rotationDays: safeRotationDays)
        return DeviceRecurrenceReceipt(
            algorithm: algorithm,
            scope: tenantId?.isEmpty == false ? "tenant" : "install",
            epoch: epoch,
            rotationDays: safeRotationDays,
            current: token(salt: salt, scope: scope, epoch: epoch),
            previous: token(salt: salt, scope: scope, epoch: epoch - 1)
        )
    }

    /// Erase the device-only recurrence salt this SDK created. After this, the device derives a fresh,
    /// unlinkable series (the "forget me" lever).
    public static func eraseLocalState() {
        DeviceRecurrenceSalt.clear()
    }

    static func epoch(now: Date, rotationDays: Int) -> Int {
        let windowSeconds = Double(max(1, rotationDays) * secondsPerDay)
        return Int((now.timeIntervalSince1970 / windowSeconds).rounded(.down))
    }

    static func scopeValue(for tenantId: String?) -> String {
        guard let tenantId, !tenantId.isEmpty else { return installScopeMarker }
        return tenantId
    }

    /// Pure, deterministic salted HMAC — factored out so it is directly unit-testable.
    static func token(salt: Data, scope: String, epoch: Int) -> String {
        let message = "\(domainSeparator)|\(scope)|\(epoch)"
        let code = HMAC<SHA256>.authenticationCode(
            for: Data(message.utf8),
            using: SymmetricKey(data: salt)
        )
        return Data(code).base64URLEncodedString()
    }
}

/// Per-install random salt for the device-recurrence HMAC. Keychain-resident, device-only, never
/// egressed — the same accessibility class as the device signing key, so it does not migrate to a new
/// device (a replaced device legitimately starts a fresh recurrence series).
enum DeviceRecurrenceSalt {
    private static let service = "com.kenshiki.device.recurrence.salt.v1"
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
        SecItemDelete(baseQuery() as CFDictionary)   // idempotent re-create
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func clear() {
        SecItemDelete(baseQuery() as CFDictionary)
    }

    private static func randomSalt() -> Data {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        if SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes) != errSecSuccess {
            // Fall back to a CryptoKit symmetric key's bytes — still CSPRNG-backed.
            return SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        }
        return Data(bytes)
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
