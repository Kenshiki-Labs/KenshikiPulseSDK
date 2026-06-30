import XCTest
@testable import KenshikiPulseSDK

final class PulseContinuityBackendClientTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    func testDevRegistrationStoresTokenInCredentialStore() async throws {
        let store = InMemoryPulseContinuityCredentialStore()
        let transport = RecordingContinuityTransport(responses: [
            #"{"installationId":"pulse_01J1R2X8N9JBNHPA2C1K1X4QV8","token":"pulse_test_token","tokenType":"Bearer","expiresAt":null,"attestation":{"mode":"devSimulator","verified":false,"productionReady":false}}"#
        ])
        let client = PulseContinuityBackendClient(
            configuration: PulseContinuityBackendConfiguration(baseURL: URL(string: "https://api.example")!, mode: .devSimulator),
            credentials: store,
            transport: transport
        )

        let credentials = try await client.ensureDevSimulatorRegistration(app: PulseContinuityAppMetadata(appVersion: "1.0", buildNumber: "42"))

        XCTAssertEqual(credentials.token, "pulse_test_token")
        XCTAssertEqual(credentials.backendBaseURL, URL(string: "https://api.example")!)
        XCTAssertEqual(credentials.mode, .devSimulator)
        let stored = try await store.load()
        XCTAssertEqual(stored?.installationID, "pulse_01J1R2X8N9JBNHPA2C1K1X4QV8")
        XCTAssertEqual(stored?.backendBaseURL, URL(string: "https://api.example")!)
        XCTAssertEqual(stored?.mode, .devSimulator)
        let capturedRegistrationRequest = await transport.firstRequest()
        let request = try XCTUnwrap(capturedRegistrationRequest)
        XCTAssertEqual(request.url?.absoluteString, "https://api.example/api/v1/pulse/installations")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Pulse-Schema-Version"), "pulse.installation-registration.v1")
    }

    func testRegistrationDiscardsCredentialFromDifferentBackendModeOrEnvironment() async throws {
        let store = InMemoryPulseContinuityCredentialStore(credentials: PulseContinuityCredentials(
            installationID: "stale_installation",
            clientInstallationID: "01J1R2X8N9JBNHPA2C1K1X4QV8",
            token: "stale_token",
            expiresAt: nil,
            backendBaseURL: URL(string: "https://old.example")!,
            mode: .appAttest,
            appAttestEnvironment: "development"
        ))
        let transport = RecordingContinuityTransport(responses: [
            #"{"installationId":"fresh_installation","token":"fresh_token","tokenType":"Bearer","expiresAt":null,"attestation":{"mode":"devSimulator","verified":false,"productionReady":false}}"#
        ])
        let client = PulseContinuityBackendClient(
            configuration: PulseContinuityBackendConfiguration(
                baseURL: URL(string: "https://api.example")!,
                mode: .devSimulator,
                appAttestEnvironment: "production"
            ),
            credentials: store,
            transport: transport
        )

        let credentials = try await client.ensureRegistration(app: PulseContinuityAppMetadata(appVersion: "1.0", buildNumber: "42"))

        XCTAssertEqual(credentials.installationID, "fresh_installation")
        XCTAssertEqual(credentials.token, "fresh_token")
        XCTAssertEqual(credentials.backendBaseURL, URL(string: "https://api.example")!)
        XCTAssertEqual(credentials.mode, .devSimulator)
        XCTAssertEqual(credentials.appAttestEnvironment, "production")
        let requestCount = await transport.requestCount()
        XCTAssertEqual(requestCount, 1)
    }

    func testLegacyCredentialsDecodeWithoutScopeAndAreNotReusable() throws {
        let json = #"{"installationID":"legacy","clientInstallationID":"01J1R2X8N9JBNHPA2C1K1X4QV8","token":"legacy_token","expiresAt":null}"#
        let credentials = try JSONDecoder().decode(PulseContinuityCredentials.self, from: Data(json.utf8))

        XCTAssertEqual(credentials.installationID, "legacy")
        XCTAssertNil(credentials.backendBaseURL)
        XCTAssertNil(credentials.mode)
        XCTAssertNil(credentials.appAttestEnvironment)
        XCTAssertNil(credentials.appAttestKeyID)
    }

    func testAppAttestCredentialsWithoutKeyIDAreNotReusable() async throws {
        let store = InMemoryPulseContinuityCredentialStore(credentials: PulseContinuityCredentials(
            installationID: "legacy_app_attest_installation",
            clientInstallationID: "01J1R2X8N9JBNHPA2C1K1X4QV8",
            token: "legacy_token",
            expiresAt: nil,
            backendBaseURL: URL(string: "https://api.example")!,
            mode: .appAttest,
            appAttestEnvironment: "production"
        ))
        let client = PulseContinuityBackendClient(
            configuration: PulseContinuityBackendConfiguration(
                baseURL: URL(string: "https://api.example")!,
                mode: .appAttest,
                appAttestEnvironment: "production"
            ),
            credentials: store,
            transport: RecordingContinuityTransport(responses: [])
        )

        do {
            _ = try await client.ensureRegistration(app: PulseContinuityAppMetadata(appVersion: "1.0", buildNumber: "42"))
            XCTFail("Expected legacy App Attest credentials to be refreshed instead of reused.")
        } catch {
            XCTAssertFalse(String(describing: error).contains("legacy_token"))
        }
    }

    func testOperationalUploadSendsBoundedContinuitySummary() async throws {
        let store = InMemoryPulseContinuityCredentialStore(credentials: PulseContinuityCredentials(
            installationID: "pulse_installation",
            clientInstallationID: "01J1R2X8N9JBNHPA2C1K1X4QV8",
            token: "pulse_test_token",
            expiresAt: nil,
            backendBaseURL: URL(string: "https://api.example")!,
            mode: .devSimulator
        ))
        let transport = RecordingContinuityTransport(responses: [
            #"{"checkInId":"11111111-1111-4111-8111-111111111111","clientCheckInId":"01J1R2X8N9JBNHPA2C1K1X4QV8","acceptedAt":"2026-06-25T12:00:00.000Z","idempotency":{"replayed":false}}"#
        ])
        let client = PulseContinuityBackendClient(
            configuration: PulseContinuityBackendConfiguration(baseURL: URL(string: "https://api.example")!, mode: .devSimulator),
            credentials: store,
            transport: transport
        )
        let checkIn = makeCheckIn()
        let model = ContinuityModel.evaluate(
            snapshot: checkIn.evaluation.evidenceSnapshot,
            stateWeight: 1,
            lastCheckIn: t0,
            daysContinuous: 90,
            checkInCount: 90,
            now: t0
        )

        _ = try await client.uploadOperationalCheckIn(
            checkIn,
            model: model,
            app: PulseContinuityAppMetadata(appVersion: "1.0", buildNumber: "42"),
            permissions: PulseContinuityPermissionSnapshot(motion: "available", bluetooth: "denied"),
            localEvidence: PulseLocalEvidenceDiagnostics(
                directSensorRowCount: 9,
                compatibilityRowCount: 4,
                inputHash: String(repeating: "a", count: 64),
                windowStartAt: t0.addingTimeInterval(-600),
                windowEndAt: t0,
                latestDirectSensorRowAt: t0,
                directRowsBySensor: ["device_motion": 1, "battery": 1],
                unavailableRowsBySensor: ["bluetooth": 1]
            )
        )

        let capturedUploadRequest = await transport.firstRequest()
        let request = try XCTUnwrap(capturedUploadRequest)
        XCTAssertEqual(request.url?.absoluteString, "https://api.example/api/v1/pulse/check-ins")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer pulse_test_token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Pulse-Schema-Version"), "pulse.check-in.v1")
        XCTAssertNotNil(request.value(forHTTPHeaderField: "Idempotency-Key"))

        let capturedBody = await transport.firstJSONBody()
        let body = try XCTUnwrap(capturedBody)
        XCTAssertEqual(body["schemaVersion"] as? String, "pulse.check-in.v1")
        XCTAssertEqual((body["permissions"] as? [String: Any])?["bluetooth"] as? String, "denied")
        let lanes = try XCTUnwrap(body["lanes"] as? [[String: Any]])
        XCTAssertTrue(lanes.contains { $0["lane"] as? String == "motion" })
        XCTAssertTrue(lanes.contains { $0["lane"] as? String == "network" })
        let diagnostics = try XCTUnwrap(body["clientDiagnostics"] as? [String: Any])
        let localEvidence = try XCTUnwrap(diagnostics["localEvidence"] as? [String: Any])
        XCTAssertEqual(localEvidence["directSensorRowCount"] as? Int, 9)
        XCTAssertEqual(localEvidence["compatibilityRowCount"] as? Int, 4)
        XCTAssertEqual(localEvidence["inputHash"] as? String, String(repeating: "a", count: 64))
        XCTAssertEqual((localEvidence["directRowsBySensor"] as? [String: Any])?["device_motion"] as? Int, 1)
        XCTAssertEqual((localEvidence["unavailableRowsBySensor"] as? [String: Any])?["bluetooth"] as? Int, 1)
        XCTAssertNil(body["signals"])
        XCTAssertNil(body["raw"])
    }

    func testOperationalUploadMapsPressureToDeviceEnvironmentNotMovement() async throws {
        let store = InMemoryPulseContinuityCredentialStore(credentials: PulseContinuityCredentials(
            installationID: "pulse_installation",
            clientInstallationID: "01J1R2X8N9JBNHPA2C1K1X4QV8",
            token: "pulse_test_token",
            expiresAt: nil,
            backendBaseURL: URL(string: "https://api.example")!,
            mode: .devSimulator
        ))
        let transport = RecordingContinuityTransport(responses: [
            #"{"checkInId":"11111111-1111-4111-8111-111111111111","clientCheckInId":"01J1R2X8N9JBNHPA2C1K1X4QV8","acceptedAt":"2026-06-25T12:00:00.000Z","idempotency":{"replayed":false}}"#
        ])
        let client = PulseContinuityBackendClient(
            configuration: PulseContinuityBackendConfiguration(baseURL: URL(string: "https://api.example")!, mode: .devSimulator),
            credentials: store,
            transport: transport
        )
        let checkIn = makeCheckIn(signals: makePressureOnlySignals())
        let model = ContinuityModel.evaluate(
            snapshot: checkIn.evaluation.evidenceSnapshot,
            stateWeight: 1,
            lastCheckIn: t0,
            daysContinuous: 90,
            checkInCount: 90,
            now: t0
        )

        _ = try await client.uploadOperationalCheckIn(
            checkIn,
            model: model,
            app: PulseContinuityAppMetadata(appVersion: "1.0", buildNumber: "42")
        )

        let capturedBody = await transport.firstJSONBody()
        let body = try XCTUnwrap(capturedBody)
        let lanes = try XCTUnwrap(body["lanes"] as? [[String: Any]])
        let motion = try XCTUnwrap(lanes.first { $0["lane"] as? String == "motion" })
        let environment = try XCTUnwrap(lanes.first { $0["lane"] as? String == "environment" })

        XCTAssertEqual(motion["group"] as? String, "movement")
        XCTAssertEqual(motion["state"] as? String, "unavailable")
        XCTAssertEqual(environment["group"] as? String, "deviceEnvironment")
        XCTAssertEqual(environment["state"] as? String, "supporting")
        XCTAssertFalse(lanes.contains {
            $0["lane"] as? String == "motion" &&
                $0["group"] as? String == "movement" &&
                $0["state"] as? String == "supporting"
        })
    }

    private func makeCheckIn(signals: DeviceSignals? = nil) -> ContinuityCheckInResult {
        let envelope = makeEnvelope(signals: signals)
        let evaluation = ContinuityEvaluator.evaluate(signals: envelope.signals, previous: nil, collectedAt: t0, now: t0)
        return ContinuityCheckInResult(
            envelope: envelope,
            evaluation: evaluation,
            priorState: .notAttested,
            state: .attestedContinuous,
            lockedSince: t0,
            lastCheckIn: t0,
            checkInCount: 1,
            outcome: .firstCheckIn
        )
    }

    private func makeEnvelope(signals: DeviceSignals? = nil) -> DeviceEvidenceEnvelope {
        DeviceEvidenceEnvelope(
            generatedAt: t0,
            session: KenshikiSessionContext(sessionId: "s"),
            collection: DeviceEvidenceCollection(startedAt: t0, endedAt: t0, durationMilliseconds: 0, consentPolicy: .disabledForLocalTesting),
            signals: signals ?? DeviceSignals(
                battery: BatterySignal(support: SignalSupport(status: .available), level: 0.72),
                motion: MotionSignal(support: SignalSupport(status: .available), sampleCount: 1, userAccelerationMagnitude: 0.1),
                magnetometer: MagnetometerSignal(support: SignalSupport(status: .available), sampleCount: 1, fieldMagnitudeMicrotesla: 42),
                barometer: BarometerSignal(support: SignalSupport(status: .unavailable)),
                ambientLight: AmbientLightSignal(support: SignalSupport(status: .notSupportedByPlatform)),
                connectivity: ConnectivitySignal(support: SignalSupport(status: .available), pathStatus: "satisfied", interfaceTypes: ["wifi"], expensive: false, constrained: false, wifiNetworkHash: "wifi_token"),
                bluetooth: BluetoothSignal(support: SignalSupport(status: .unavailable)),
                deviceSurface: DeviceSurfaceSignal(support: SignalSupport(status: .available), platform: "iOS", systemName: "iOS", systemMajorVersion: 18, interfaceIdiom: "phone", simulator: true),
                telephony: TelephonySignal(support: SignalSupport(status: .available), simInserted: true, radioGenerations: ["4g"], callEventCount: 0, activeCallCount: 0)
            )
        )
    }

    private func makePressureOnlySignals() -> DeviceSignals {
        let unavailable = SignalSupport(status: .unavailable)
        return DeviceSignals(
            battery: BatterySignal(support: unavailable),
            motion: MotionSignal(support: unavailable),
            magnetometer: MagnetometerSignal(support: unavailable),
            barometer: BarometerSignal(support: SignalSupport(status: .available), pressureKilopascals: 101.2),
            ambientLight: AmbientLightSignal(support: unavailable),
            mediaOutput: MediaOutputSignal(support: unavailable),
            displayProjection: DisplayProjectionSignal(support: unavailable),
            connectivity: ConnectivitySignal(support: unavailable),
            bluetooth: BluetoothSignal(support: unavailable),
            deviceSurface: DeviceSurfaceSignal(
                support: unavailable,
                platform: "",
                systemName: "",
                simulator: false
            ),
            telephony: TelephonySignal(support: unavailable)
        )
    }
}

private actor RecordingContinuityTransport: PulseContinuityHTTPTransport {
    private(set) var requests: [URLRequest] = []
    private(set) var jsonBodies: [[String: Any]] = []
    private var responses: [String]

    init(responses: [String]) {
        self.responses = responses
    }

    func firstRequest() -> URLRequest? {
        requests.first
    }

    func firstJSONBody() -> [String: Any]? {
        jsonBodies.first
    }

    func requestCount() -> Int {
        requests.count
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        if let body = request.httpBody,
           let json = try JSONSerialization.jsonObject(with: body) as? [String: Any] {
            jsonBodies.append(json)
        }
        let payload = responses.removeFirst()
        let data = Data(payload.utf8)
        return (
            data,
            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        )
    }
}
