import Foundation
import CryptoKit
import Security
#if canImport(NetworkExtension)
import NetworkExtension
#endif

/// Privacy-preserving Wi-Fi **network-continuity token**.
///
/// We never store or transmit the raw BSSID/SSID. We emit a per-device *salted hash* so the registry
/// can observe "same Wi-Fi as prior check-ins" (home/work stability) **without learning which network**
/// — and without being able to correlate the same physical network across different devices, because
/// the salt is a per-install, device-only secret. A changed token is *not* a continuity break (people
/// legitimately change networks); it's a coherence/stability input, not a device/SIM swap.
///
/// Requires the `com.apple.developer.networking.wifi-info` entitlement **and** location authorization
/// on the host app; absent either, `currentHash()` returns `nil` (honest "no sample", not a fake value).
public enum WifiNetworkIdentity {
    /// Current network's familiarity band for live/UI/fusion use. **Read-only** — it does NOT record a
    /// visit (visits are recorded by the collector via `KnownNetworkStore.observe` on each sealed
    /// check-in, so the live path can't inflate the history just by being displayed).
    public static func currentFamiliarity() async -> NetworkFamiliarity {
        guard let token = await currentHash() else { return .unknown }
        return KnownNetworkStore.shared.familiarity(of: token)
    }

    /// Erase the device-only Wi-Fi continuity memory this SDK created.
    public static func eraseLocalState() {
        KnownNetworkStore.shared.reset()
        NetworkContinuitySalt.clear()
    }

    /// Pure, deterministic salted hash — factored out so it's directly unit-testable.
    static func hash(bssid: String, salt: Data) -> String {
        var data = salt
        data.append(Data(bssid.utf8))
        let digest = SHA256.hash(data: data)
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Current Wi-Fi network token, or `nil` when not on Wi-Fi / no entitlement / no location auth.
    static func currentHash() async -> String? {
        #if canImport(NetworkExtension) && os(iOS)
        guard let bssid = await currentBSSID(), !bssid.isEmpty, bssid != "00:00:00:00:00:00" else {
            return nil
        }
        return hash(bssid: bssid, salt: NetworkContinuitySalt.loadOrCreate())
        #else
        return nil
        #endif
    }

    #if canImport(NetworkExtension) && os(iOS)
    private static func currentBSSID() async -> String? {
        await withCheckedContinuation { continuation in
            NEHotspotNetwork.fetchCurrent { network in
                continuation.resume(returning: network?.bssid)
            }
        }
    }
    #endif
}

/// How familiar the current Wi-Fi network is, judged only from the device's own salted-token history.
/// This is the continuity-relevant *band* — a recurring (home/work) network is a stability anchor; a
/// brand-new one is neutral, not a break. The raw token never leaves; only this coarse band is exported.
public enum NetworkFamiliarity: String, Codable, Sendable {
    case unknown   // not on Wi-Fi, or no token (no entitlement / no location auth)
    case new       // first time this device has seen this network
    case known     // seen before, but not yet a recurring anchor
    case familiar  // recurring across several distinct days — a home/work footprint
}

/// One network's local visit record. Keyed by the salted token; carries no raw BSSID/SSID.
struct NetworkVisit: Codable, Equatable, Sendable {
    var firstSeen: Date
    var lastSeen: Date
    var visitCount: Int
    var distinctDays: Int
    /// Start-of-day of the last day we counted, so repeated check-ins on one day don't inflate `distinctDays`.
    var lastCountedDay: Date
}

/// Device-only memory of which Wi-Fi networks (by salted token) this device has seen, so the collector
/// can answer "is this a familiar network?" without ever storing a raw BSSID. Bounded + LRU-evicted so
/// it can't grow without limit. Lives beside the salt: derived, non-identifying, never egressed raw.
final class KnownNetworkStore: @unchecked Sendable {
    static let shared = KnownNetworkStore()

    /// Seen on at least this many distinct days ⇒ `.familiar` (a recurring anchor, not a one-off).
    static let familiarDayThreshold = 3
    /// Cap on tracked networks; least-recently-seen is evicted past this.
    static let maxNetworks = 64

    private let defaults: UserDefaults
    private let storeKey = "kenshiki.known_networks.v1"
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// Record a sighting of `token` and return how familiar it now is. `nil`/empty token ⇒ `.unknown`.
    func observe(token: String?, at now: Date = Date(), calendar: Calendar = .current) -> NetworkFamiliarity {
        guard let token, !token.isEmpty else { return .unknown }
        lock.lock(); defer { lock.unlock() }
        var all = load()
        let today = calendar.startOfDay(for: now)
        if var visit = all[token] {
            visit.visitCount += 1
            visit.lastSeen = now
            if today > visit.lastCountedDay {
                visit.distinctDays += 1
                visit.lastCountedDay = today
            }
            all[token] = visit
            evictIfNeeded(&all)
            save(all)
            return Self.classify(visit)
        }
        all[token] = NetworkVisit(firstSeen: now, lastSeen: now, visitCount: 1, distinctDays: 1, lastCountedDay: today)
        evictIfNeeded(&all)
        save(all)
        return .new
    }

    /// Read-only familiarity of a token from existing history — does not record a visit. A token with no
    /// recorded history yet reads as `.new` (we're on it, but haven't sealed a visit).
    func familiarity(of token: String) -> NetworkFamiliarity {
        lock.lock(); defer { lock.unlock() }
        guard let visit = load()[token] else { return .new }
        return Self.classify(visit)
    }

    /// Pure classification of a recorded visit — directly unit-testable.
    static func classify(_ visit: NetworkVisit, familiarDayThreshold: Int = familiarDayThreshold) -> NetworkFamiliarity {
        if visit.distinctDays >= familiarDayThreshold { return .familiar }
        if visit.visitCount >= 2 || visit.distinctDays >= 2 { return .known }
        return .new
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        defaults.removeObject(forKey: storeKey)
    }

    private func load() -> [String: NetworkVisit] {
        guard let data = defaults.data(forKey: storeKey),
              let decoded = try? JSONDecoder().decode([String: NetworkVisit].self, from: data) else { return [:] }
        return decoded
    }

    private func save(_ all: [String: NetworkVisit]) {
        if let data = try? JSONEncoder().encode(all) { defaults.set(data, forKey: storeKey) }
    }

    private func evictIfNeeded(_ all: inout [String: NetworkVisit]) {
        guard all.count > Self.maxNetworks else { return }
        let ordered = all.sorted { $0.value.lastSeen < $1.value.lastSeen }
        for (token, _) in ordered.prefix(all.count - Self.maxNetworks) { all.removeValue(forKey: token) }
    }
}

/// Per-install random salt for the network-continuity hash. Keychain-resident, device-only, never
/// egressed — the same accessibility class as the device signing key, so it does not migrate to a new
/// device (a replaced device legitimately starts a fresh network-continuity series).
enum NetworkContinuitySalt {
    private static let service = "com.kenshiki.device.network.salt.v1"
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
