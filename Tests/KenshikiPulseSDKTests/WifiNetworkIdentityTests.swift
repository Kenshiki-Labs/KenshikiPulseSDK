import XCTest
@testable import KenshikiPulseSDK

final class WifiNetworkIdentityTests: XCTestCase {
    private let saltA = Data(repeating: 0xA1, count: 32)
    private let saltB = Data(repeating: 0xB2, count: 32)
    private let bssid = "a4:5e:60:c1:2d:9f"

    func testHashIsDeterministicForSameNetworkAndSalt() {
        // The continuity property: the same network always produces the same token (so the server can
        // see "same Wi-Fi as last time").
        XCTAssertEqual(WifiNetworkIdentity.hash(bssid: bssid, salt: saltA),
                       WifiNetworkIdentity.hash(bssid: bssid, salt: saltA))
    }

    func testDifferentNetworksProduceDifferentTokens() {
        XCTAssertNotEqual(WifiNetworkIdentity.hash(bssid: bssid, salt: saltA),
                          WifiNetworkIdentity.hash(bssid: "00:11:22:33:44:55", salt: saltA))
    }

    func testDifferentDevicesCannotBeCorrelated() {
        // Per-install salt: the SAME physical network hashes differently on two devices → no cross-device linking.
        XCTAssertNotEqual(WifiNetworkIdentity.hash(bssid: bssid, salt: saltA),
                          WifiNetworkIdentity.hash(bssid: bssid, salt: saltB))
    }

    func testTokenIsBase64URLAndCarriesNoRawBSSID() {
        let token = WifiNetworkIdentity.hash(bssid: bssid, salt: saltA)
        XCTAssertFalse(token.contains("+"))
        XCTAssertFalse(token.contains("/"))
        XCTAssertFalse(token.contains("="))
        XCTAssertFalse(token.contains(bssid))        // irreversible: raw identifier never appears
        XCTAssertEqual(token.count, 43)              // SHA-256 → 32 bytes → 43 base64url chars
    }
}
