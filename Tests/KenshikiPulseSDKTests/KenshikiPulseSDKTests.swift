import XCTest
import CryptoKit
@testable import KenshikiPulseSDK

final class KenshikiPulseSDKTests: XCTestCase {
    func testEvidenceEnvelopeEncodesPrivacyBoundary() throws {
        let envelope = Self.makeEnvelope()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let data = try encoder.encode(envelope)
        let json = try XCTUnwrap(String(bytes: data, encoding: .utf8))

        XCTAssertTrue(json.contains(KenshikiPulseConstants.evidenceSchemaVersion))
        XCTAssertTrue(json.contains(KenshikiPulseConstants.privacyBoundary))
        XCTAssertTrue(json.contains("battery"))
        XCTAssertTrue(json.contains("bluetooth"))
        XCTAssertTrue(json.contains("telephony"))
    }

    func testBluetoothSignalEncodesRadioStateWithoutIdentifiers() throws {
        let signal = BluetoothSignal(
            support: SignalSupport(status: .available),
            authorization: "allowed",
            radioState: "powered_on",
            scanAvailable: true,
            audioRouteClass: "bluetooth",
            audioRouteConnected: true,
            audioRouteChangeCount: 2
        )

        let data = try JSONEncoder().encode(signal)
        let json = try XCTUnwrap(String(bytes: data, encoding: .utf8))

        XCTAssertTrue(json.contains("authorization"))
        XCTAssertTrue(json.contains("radioState"))
        XCTAssertTrue(json.contains("scanAvailable"))
        XCTAssertTrue(json.contains("audioRouteClass"))
        XCTAssertTrue(json.contains("audioRouteChangeCount"))
        XCTAssertTrue(json.contains("bluetooth"))
        XCTAssertFalse(json.contains("peripheral"))
        XCTAssertFalse(json.contains("uuid"))
        XCTAssertFalse(json.contains("mac"))
        XCTAssertFalse(json.contains("AirPods"))
        XCTAssertEqual(try JSONDecoder().decode(BluetoothSignal.self, from: data), signal)
    }

    func testBluetoothRouteTrackerStoresOnlyCoarseRouteClassAndCount() throws {
        let suiteName = "kenshiki.bluetooth.route.tests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }

        let first = BluetoothRouteTracker.observe(routeClass: "none", defaults: suite)
        let same = BluetoothRouteTracker.observe(routeClass: "none", defaults: suite)
        let connected = BluetoothRouteTracker.observe(routeClass: "bluetooth", defaults: suite)
        let car = BluetoothRouteTracker.observe(routeClass: "car", defaults: suite)

        XCTAssertEqual(first, BluetoothRouteSnapshot(routeClass: "none", changeCount: 0))
        XCTAssertEqual(same, BluetoothRouteSnapshot(routeClass: "none", changeCount: 0))
        XCTAssertEqual(connected, BluetoothRouteSnapshot(routeClass: "bluetooth", changeCount: 1))
        XCTAssertEqual(car, BluetoothRouteSnapshot(routeClass: "car", changeCount: 2))
        XCTAssertFalse(suite.dictionaryRepresentation().values.contains { value in
            String(describing: value).contains("AirPods") || String(describing: value).contains("uuid")
        })
    }

    func testSignalChangeTrackerStoresOnlyBucketAndCount() throws {
        let suiteName = "kenshiki.signal.change.tests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }

        let first = SignalChangeTracker.observe(keyPrefix: "test.media.route", value: "speaker", defaults: suite)
        let same = SignalChangeTracker.observe(keyPrefix: "test.media.route", value: "speaker", defaults: suite)
        let changed = SignalChangeTracker.observe(keyPrefix: "test.media.route", value: "car", defaults: suite)

        XCTAssertEqual(first, SignalChangeSnapshot(value: "speaker", changeCount: 0))
        XCTAssertEqual(same, SignalChangeSnapshot(value: "speaker", changeCount: 0))
        XCTAssertEqual(changed, SignalChangeSnapshot(value: "car", changeCount: 1))
        XCTAssertFalse(suite.dictionaryRepresentation().values.contains { value in
            String(describing: value).contains("AirPods") || String(describing: value).contains("display name")
        })
    }

    func testLightMediaAndProjectionSignalsEncodeRhythmCounters() throws {
        let light = AmbientLightSignal(
            support: SignalSupport(status: .available),
            screenBrightnessLevel: 0.8,
            proxySource: "UIScreen.main.brightness",
            brightnessBand: "bright",
            brightnessBandChangeCount: 2
        )
        let media = MediaOutputSignal(
            support: SignalSupport(status: .available),
            routeClass: "car",
            external: true,
            otherAudioPlaying: true,
            routeChangeCount: 3,
            externalRouteChangeCount: 1
        )
        let projection = DisplayProjectionSignal(
            support: SignalSupport(status: .available),
            screenCaptured: true,
            externalDisplayCount: 1,
            projectionStatus: "mirrored_or_recorded",
            projectionChangeCount: 2,
            captureChangeCount: 1
        )

        let data = try JSONEncoder().encode([light, AmbientLightSignal(support: SignalSupport(status: .notCollected))])
        let lightJson = try XCTUnwrap(String(bytes: data, encoding: .utf8))
        XCTAssertTrue(lightJson.contains("brightnessBandChangeCount"))

        let mediaJson = try XCTUnwrap(String(bytes: try JSONEncoder().encode(media), encoding: .utf8))
        XCTAssertTrue(mediaJson.contains("routeChangeCount"))
        XCTAssertTrue(mediaJson.contains("externalRouteChangeCount"))
        XCTAssertFalse(mediaJson.contains("AirPods"))

        let projectionJson = try XCTUnwrap(String(bytes: try JSONEncoder().encode(projection), encoding: .utf8))
        XCTAssertTrue(projectionJson.contains("projectionChangeCount"))
        XCTAssertTrue(projectionJson.contains("captureChangeCount"))
        XCTAssertFalse(projectionJson.contains("screen contents"))
    }

    func testTelephonySignalEncodesRadioGenerations() throws {
        let lastCall = Date(timeIntervalSince1970: 1_700_000_100)
        let signal = TelephonySignal(
            support: SignalSupport(status: .available),
            simInserted: true,
            radioGenerations: ["4g", "5g"],
            serviceCount: 2,
            radioVisibility: "visible",
            cellularDataRestricted: "not_restricted",
            dataServiceAvailable: true,
            dataServiceChangeCount: 1,
            callEventCount: 3,
            lastCallEventAt: lastCall,
            activeCallCount: 1,
            connectedCallCount: 1,
            heldCallCount: 0,
            callObserverStartedAt: Date(timeIntervalSince1970: 1_700_000_000),
            callObserverCoverageSeconds: 100
        )
        let data = try JSONEncoder().encode(signal)
        let json = try XCTUnwrap(String(bytes: data, encoding: .utf8))
        XCTAssertTrue(json.contains("radioGenerations"))
        XCTAssertTrue(json.contains("serviceCount"))
        XCTAssertTrue(json.contains("radioVisibility"))
        XCTAssertTrue(json.contains("dataServiceChangeCount"))
        XCTAssertTrue(json.contains("callEventCount"))
        XCTAssertTrue(json.contains("connectedCallCount"))
        XCTAssertTrue(json.contains("heldCallCount"))
        XCTAssertTrue(json.contains("5g"))
        XCTAssertFalse(json.contains("service-a"))
        XCTAssertFalse(json.contains("310260"))
        XCTAssertEqual(try JSONDecoder().decode(TelephonySignal.self, from: data), signal)
    }

    func testConnectivitySignalEncodesPathClassWithoutIdentifiers() throws {
        let signal = ConnectivitySignal(
            support: SignalSupport(status: .available),
            pathStatus: "satisfied",
            unsatisfiedReason: nil,
            interfaceTypes: ["wifi", "cellular"],
            availableInterfaceTypes: ["wifi", "cellular", "other"],
            perInterfacePathStatuses: ["wifi": "satisfied", "cellular": "unsatisfied", "other": "requires_connection"],
            expensive: true,
            constrained: false,
            supportsDNS: true,
            supportsIPv4: true,
            supportsIPv6: true
        )

        let data = try JSONEncoder().encode(signal)
        let json = try XCTUnwrap(String(bytes: data, encoding: .utf8))

        XCTAssertTrue(json.contains("interfaceTypes"))
        XCTAssertTrue(json.contains("availableInterfaceTypes"))
        XCTAssertTrue(json.contains("perInterfacePathStatuses"))
        XCTAssertTrue(json.contains("wifi"))
        XCTAssertFalse(json.contains("ssid"))
        XCTAssertFalse(json.contains("bssid"))
        XCTAssertFalse(json.contains("ipAddress"))
        XCTAssertFalse(json.contains("en0"))
        XCTAssertFalse(json.contains("pdp_ip0"))
        XCTAssertEqual(try JSONDecoder().decode(ConnectivitySignal.self, from: data), signal)
    }

    func testTelephonyDataServiceTrackerStoresOnlyChangeCount() throws {
        let suiteName = "kenshiki.telephony.data.tests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }
        let salt = Data(repeating: 7, count: 32)

        let first = TelephonyDataServiceTracker.observe(identifier: "service-a", salt: salt, defaults: suite)
        let same = TelephonyDataServiceTracker.observe(identifier: "service-a", salt: salt, defaults: suite)
        let changed = TelephonyDataServiceTracker.observe(identifier: "service-b", salt: salt, defaults: suite)
        let absent = TelephonyDataServiceTracker.observe(identifier: nil, defaults: suite)

        XCTAssertEqual(first, TelephonyDataServiceSnapshot(available: true, changeCount: 0))
        XCTAssertEqual(same, TelephonyDataServiceSnapshot(available: true, changeCount: 0))
        XCTAssertEqual(changed, TelephonyDataServiceSnapshot(available: true, changeCount: 1))
        XCTAssertEqual(absent, TelephonyDataServiceSnapshot(available: false, changeCount: nil))

        XCTAssertFalse(suite.dictionaryRepresentation().values.contains { value in
            String(describing: value).contains("service-a") || String(describing: value).contains("service-b")
        })
    }

    func testMagnetometerSignalEncodesCalibrationAccuracy() throws {
        let signal = MagnetometerSignal(
            support: SignalSupport(status: .available),
            sampleCount: 1,
            fieldMagnitudeMicrotesla: 42.0,
            calibrationAccuracy: "high"
        )

        let data = try JSONEncoder().encode(signal)
        let json = try XCTUnwrap(String(bytes: data, encoding: .utf8))

        XCTAssertTrue(json.contains("calibrationAccuracy"))
        XCTAssertEqual(try JSONDecoder().decode(MagnetometerSignal.self, from: data), signal)
    }

    func testCallActivityRecorderStoresOnlyAggregateState() {
        CallActivityRecorder.resetForTesting()
        defer { CallActivityRecorder.resetForTesting() }

        XCTAssertNil(CallActivityRecorder.snapshot().activeCallCount)

        let started = Date(timeIntervalSince1970: 1_700_000_000)
        let observed = Date(timeIntervalSince1970: 1_700_000_060)
        CallActivityRecorder.markObserverStarted(at: started)
        CallActivityRecorder.recordOccurrence(
            at: observed,
            activeCallCount: 1,
            connectedCallCount: 1,
            heldCallCount: 0
        )

        let snapshot = CallActivityRecorder.snapshot()
        XCTAssertEqual(snapshot.eventCount, 1)
        XCTAssertEqual(snapshot.lastEventAt, observed)
        XCTAssertEqual(snapshot.activeCallCount, 1)
        XCTAssertEqual(snapshot.connectedCallCount, 1)
        XCTAssertEqual(snapshot.heldCallCount, 0)
        XCTAssertEqual(snapshot.observerStartedAt, started)
    }

    func testHighLevelVerificationUsesCollectorAndTransport() async throws {
        let expected = ExistenceVerificationResult(
            requestId: "req_test",
            decision: "review",
            confidence: 0.82,
            reasons: ["synthetic_test"]
        )
        let sdk = KenshikiPulseSDK(
            configuration: KenshikiPulseConfiguration(
                endpoint: URL(string: "https://example.test/verify"),
                signEvidence: false,
                enablePlatformAttestation: false
            ),
            collector: StubCollector(envelope: Self.makeEnvelope()),
            transport: StubTransport(result: expected)
        )

        let result = try await sdk.verifyExistence(context: KenshikiSessionContext(sessionId: "session_test"))

        XCTAssertEqual(result, expected)
    }

    func testEvidenceIntegrityReceiptVerifiesSignedEnvelope() async throws {
        let suiteName = "kenshiki.integrity.tests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }
        let issuer = EvidenceIntegrityIssuer(
            signer: DeviceEvidenceSigner(keyTag: "test.\(UUID().uuidString)", persistent: false, preferSecureEnclave: false),
            ledger: MerkleLedger(defaults: suite),
            platformAttestor: StaticPlatformAttestor(state: "challenge_required")
        )

        let signed = try await issuer.signedEnvelope(
            from: Self.makeEnvelope(),
            configuration: KenshikiPulseConfiguration(signEvidence: true)
        )

        XCTAssertNotNil(signed.receipt)
        XCTAssertEqual(signed.receipt?.merkleLeafIndex, 0)
        XCTAssertEqual(signed.receipt?.merkleLeafCount, 1)
        XCTAssertTrue(EvidenceIntegrity.verify(signed))
    }

    func testEvidenceIntegrityReceiptFailsAfterPayloadTamper() async throws {
        let suiteName = "kenshiki.integrity.tests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }
        let issuer = EvidenceIntegrityIssuer(
            signer: DeviceEvidenceSigner(keyTag: "test.\(UUID().uuidString)", persistent: false, preferSecureEnclave: false),
            ledger: MerkleLedger(defaults: suite),
            platformAttestor: StaticPlatformAttestor(state: "challenge_required")
        )

        var signed = try await issuer.signedEnvelope(
            from: Self.makeEnvelope(),
            configuration: KenshikiPulseConfiguration(signEvidence: true)
        )
        signed.signals.battery.level = 0.01

        XCTAssertFalse(EvidenceIntegrity.verify(signed))
    }

    func testIdentityReceiptSignsArbitraryPayloadAndChainsMerkle() async throws {
        let suiteName = "kenshiki.integrity.tests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }
        let issuer = EvidenceIntegrityIssuer(
            signer: DeviceEvidenceSigner(keyTag: "test.\(UUID().uuidString)", persistent: false, preferSecureEnclave: false),
            ledger: MerkleLedger(defaults: suite),
            platformAttestor: StaticPlatformAttestor(state: "challenge_required")
        )
        let configuration = KenshikiPulseConfiguration(signEvidence: true)
        let payload = Data("identity.document_scan|USA|CITIZEN".utf8)

        let first = try await issuer.identityReceipt(canonicalPayload: payload, challenge: nil, configuration: configuration)
        XCTAssertEqual(first.merkleLeafIndex, 0)
        XCTAssertEqual(first.merkleLeafCount, 1)
        XCTAssertFalse(first.deviceSigning.signature.isEmpty)
        XCTAssertEqual(first.payloadHash, Self.base64URL(Data(SHA256.hash(data: payload))))
        XCTAssertEqual(first.platformAttestation.state, "challenge_required")

        // A second identity claim advances the same Merkle ledger (append-only).
        let second = try await issuer.identityReceipt(canonicalPayload: Data("second".utf8), challenge: nil, configuration: configuration)
        XCTAssertEqual(second.merkleLeafIndex, 1)
        XCTAssertEqual(second.previousMerkleRoot, first.merkleRoot)
    }

    func testEvidenceMerkleLedgerAdvancesAcrossEnvelopes() async throws {
        let suiteName = "kenshiki.integrity.tests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }
        let issuer = EvidenceIntegrityIssuer(
            signer: DeviceEvidenceSigner(keyTag: "test.\(UUID().uuidString)", persistent: false, preferSecureEnclave: false),
            ledger: MerkleLedger(defaults: suite),
            platformAttestor: StaticPlatformAttestor(state: "challenge_required")
        )
        let configuration = KenshikiPulseConfiguration(signEvidence: true)

        let first = try await issuer.signedEnvelope(from: Self.makeEnvelope(), configuration: configuration)
        var secondEnvelope = Self.makeEnvelope()
        secondEnvelope.generatedAt = Date(timeIntervalSince1970: 1_700_000_030)
        let second = try await issuer.signedEnvelope(from: secondEnvelope, configuration: configuration)

        XCTAssertEqual(first.receipt?.merkleLeafIndex, 0)
        XCTAssertEqual(second.receipt?.merkleLeafIndex, 1)
        XCTAssertEqual(second.receipt?.merkleLeafCount, 2)
        XCTAssertEqual(second.receipt?.previousMerkleRoot, first.receipt?.merkleRoot)
        XCTAssertNotEqual(second.receipt?.merkleRoot, first.receipt?.merkleRoot)
        XCTAssertTrue(EvidenceIntegrity.verify(second))
    }

    private static func makeEnvelope() -> DeviceEvidenceEnvelope {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        return DeviceEvidenceEnvelope(
            generatedAt: date,
            session: KenshikiSessionContext(sessionId: "session_test", applicantId: "applicant_test"),
            collection: DeviceEvidenceCollection(
                startedAt: date,
                endedAt: date,
                durationMilliseconds: 0,
                consentPolicy: .disabledForLocalTesting
            ),
            signals: DeviceSignals(
                battery: BatterySignal(support: SignalSupport(status: .available), level: 0.72, state: "charging"),
                motion: MotionSignal(support: SignalSupport(status: .available), sampleCount: 1, userAccelerationMagnitude: 0.1),
                magnetometer: MagnetometerSignal(
                    support: SignalSupport(status: .available),
                    sampleCount: 1,
                    fieldMagnitudeMicrotesla: 42.0,
                    calibrationAccuracy: "high"
                ),
                barometer: BarometerSignal(support: SignalSupport(status: .unavailable)),
                ambientLight: AmbientLightSignal(support: SignalSupport(status: .notSupportedByPlatform)),
                bluetooth: BluetoothSignal(
                    support: SignalSupport(status: .available),
                    authorization: "allowed",
                    radioState: "powered_on",
                    scanAvailable: true,
                    audioRouteClass: "none",
                    audioRouteConnected: false,
                    audioRouteChangeCount: 0
                ),
                deviceSurface: DeviceSurfaceSignal(
                    support: SignalSupport(status: .available),
                    platform: "iOS",
                    systemName: "iOS",
                    systemMajorVersion: 18,
                    interfaceIdiom: "phone",
                    simulator: true
                ),
                telephony: TelephonySignal(
                    support: SignalSupport(status: .available),
                    radioGenerations: ["4g"],
                    serviceCount: 1,
                    radioVisibility: "visible",
                    callEventCount: 0,
                    activeCallCount: 0,
                    connectedCallCount: 0,
                    heldCallCount: 0
                )
            )
        )
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private struct StaticPlatformAttestor: PlatformAttesting {
    let state: String

    func attestationReceipt(
        challenge _: Data?,
        payloadHashData _: Data,
        configuration: KenshikiPulseConfiguration
    ) async -> PlatformAttestationReceipt {
        PlatformAttestationReceipt(
            state: state,
            environment: configuration.appAttestEnvironment,
            reason: "test"
        )
    }
}

private struct StubCollector: DevicePhysicsCollecting {
    let envelope: DeviceEvidenceEnvelope

    func collectEvidence(context _: KenshikiSessionContext) async throws -> DeviceEvidenceEnvelope {
        envelope
    }
}

private struct StubTransport: ExistenceVerificationTransport {
    let result: ExistenceVerificationResult

    func send(
        _ request: ExistenceVerificationRequest,
        configuration _: KenshikiPulseConfiguration
    ) async throws -> ExistenceVerificationResult {
        XCTAssertNil(request.evidence.receipt)
        return result
    }
}
