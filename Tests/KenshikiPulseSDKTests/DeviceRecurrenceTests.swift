import XCTest
@testable import KenshikiPulseSDK

final class DeviceRecurrenceTests: XCTestCase {
    private let saltA = Data(repeating: 0xA1, count: 32)
    private let saltB = Data(repeating: 0xB2, count: 32)
    private let tenantA = "tenant_acme"
    private let tenantB = "tenant_lender"
    // A fixed instant so epoch math is reproducible.
    private let now = Date(timeIntervalSince1970: 1_750_000_000)

    // MARK: - token()

    func testTokenIsDeterministicForSameSaltScopeAndEpoch() {
        // Recurrence property: the same device/tenant/window always produces the same token, so a
        // relying party can recognise a returning device by equality.
        XCTAssertEqual(DeviceRecurrence.token(salt: saltA, scope: tenantA, epoch: 7),
                       DeviceRecurrence.token(salt: saltA, scope: tenantA, epoch: 7))
    }

    func testDifferentTenantsCannotBeCorrelated() {
        // Tenant-scoping: the SAME device presents a different token to each tenant → tenants cannot
        // collude to link a device across companies.
        XCTAssertNotEqual(DeviceRecurrence.token(salt: saltA, scope: tenantA, epoch: 7),
                          DeviceRecurrence.token(salt: saltA, scope: tenantB, epoch: 7))
    }

    func testDifferentDevicesCannotBeCorrelated() {
        // Per-install salt: same tenant + window hashes differently on two devices → no cross-device link.
        XCTAssertNotEqual(DeviceRecurrence.token(salt: saltA, scope: tenantA, epoch: 7),
                          DeviceRecurrence.token(salt: saltB, scope: tenantA, epoch: 7))
    }

    func testDifferentEpochsProduceDifferentTokens() {
        // Rotation: a new window yields a new token (forward privacy across long gaps).
        XCTAssertNotEqual(DeviceRecurrence.token(salt: saltA, scope: tenantA, epoch: 7),
                          DeviceRecurrence.token(salt: saltA, scope: tenantA, epoch: 8))
    }

    func testTokenIsBase64URLAndCarriesNoRawScope() {
        let token = DeviceRecurrence.token(salt: saltA, scope: tenantA, epoch: 7)
        XCTAssertFalse(token.contains("+"))
        XCTAssertFalse(token.contains("/"))
        XCTAssertFalse(token.contains("="))
        XCTAssertFalse(token.contains(tenantA))   // irreversible: raw tenant id never appears
        XCTAssertEqual(token.count, 43)            // HMAC-SHA256 → 32 bytes → 43 base64url chars
    }

    // MARK: - epoch()

    func testEpochIsFloorOfNowOverWindow() {
        let rotationDays = 90
        let window = Double(rotationDays * 86_400)
        let expected = Int((now.timeIntervalSince1970 / window).rounded(.down))
        XCTAssertEqual(DeviceRecurrence.epoch(now: now, rotationDays: rotationDays), expected)
    }

    func testEpochIsStableWithinAWindowAndAdvancesAcrossIt() {
        let rotationDays = 90
        let window = TimeInterval(rotationDays * 86_400)
        let base = DeviceRecurrence.epoch(now: now, rotationDays: rotationDays)
        // Anchor to this window's start so the boundary math is exact regardless of where `now` falls.
        let windowStart = Date(timeIntervalSince1970: Double(base) * window)
        XCTAssertEqual(DeviceRecurrence.epoch(now: windowStart, rotationDays: rotationDays), base)
        XCTAssertEqual(DeviceRecurrence.epoch(now: windowStart.addingTimeInterval(window - 1),
                                              rotationDays: rotationDays), base)
        XCTAssertEqual(DeviceRecurrence.epoch(now: windowStart.addingTimeInterval(window),
                                              rotationDays: rotationDays), base + 1)
    }

    // MARK: - scopeValue()

    func testScopeFallsBackToInstallMarkerWithoutTenant() {
        XCTAssertEqual(DeviceRecurrence.scopeValue(for: nil), DeviceRecurrence.installScopeMarker)
        XCTAssertEqual(DeviceRecurrence.scopeValue(for: ""), DeviceRecurrence.installScopeMarker)
        XCTAssertEqual(DeviceRecurrence.scopeValue(for: tenantA), tenantA)
    }

    // MARK: - derive()

    func testDerivePreviousChainsToTheCurrentOfTheLastWindow() {
        // The {current, previous} overlap: this window's `previous` must equal last window's `current`,
        // so a relying party can bridge a rotation boundary.
        let thisWindow = DeviceRecurrence.derive(salt: saltA, tenantId: tenantA, rotationDays: 90, now: now)
        let lastWindow = DeviceRecurrence.derive(
            salt: saltA,
            tenantId: tenantA,
            rotationDays: 90,
            now: now.addingTimeInterval(-Double(90 * 86_400))
        )
        XCTAssertEqual(thisWindow.previous, lastWindow.current)
        XCTAssertNotEqual(thisWindow.current, thisWindow.previous)
    }

    func testDeriveMarksTenantVersusInstallScope() {
        let tenantReceipt = DeviceRecurrence.derive(salt: saltA, tenantId: tenantA, rotationDays: 90, now: now)
        let installReceipt = DeviceRecurrence.derive(salt: saltA, tenantId: nil, rotationDays: 90, now: now)
        XCTAssertEqual(tenantReceipt.scope, "tenant")
        XCTAssertEqual(installReceipt.scope, "install")
        XCTAssertEqual(tenantReceipt.schemaVersion, KenshikiPulseConstants.deviceRecurrenceSchemaVersion)
    }

    func testDeriveClampsRotationDaysToAtLeastOne() {
        let receipt = DeviceRecurrence.derive(salt: saltA, tenantId: tenantA, rotationDays: 0, now: now)
        XCTAssertEqual(receipt.rotationDays, 1)
    }
}
