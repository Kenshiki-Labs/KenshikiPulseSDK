import XCTest

@testable import KenshikiPulseSDK

final class PulseBondingClientTests: XCTestCase {
    func testParsesCustomSchemeBondRequest() throws {
        let url = try XCTUnwrap(URL(string: "pulse://bond?session_id=sess_123&nonce=nonce_abc"))

        let request = try XCTUnwrap(PulseBondRequest(url: url))

        XCTAssertEqual(request.sessionID, "sess_123")
        XCTAssertEqual(request.nonce, "nonce_abc")
    }

    func testParsesUniversalLinkBondRequest() throws {
        let url = try XCTUnwrap(URL(string: "https://kenshiki-pulse-worker-production.pulsekenshikilabscom.workers.dev/bond?session_id=sess_123&nonce=nonce_abc"))

        let request = try XCTUnwrap(PulseBondRequest(url: url))

        XCTAssertEqual(request.sessionID, "sess_123")
        XCTAssertEqual(request.nonce, "nonce_abc")
    }

    func testParsesTrustedAPIBaseFromBondRequest() throws {
        let url = try XCTUnwrap(URL(string: "pulse://bond?session_id=sess_123&nonce=nonce_abc&api_base_url=https%3A%2F%2Fkenshiki-pulse-worker-production.pulsekenshikilabscom.workers.dev"))

        let request = try XCTUnwrap(PulseBondRequest(url: url))

        XCTAssertEqual(request.apiBaseURL?.absoluteString, "https://kenshiki-pulse-worker-production.pulsekenshikilabscom.workers.dev")
    }

    func testCustomSchemeAndUniversalLinkCarryEquivalentBondRequest() throws {
        let query = "session_id=sess_123&nonce=nonce_abc&api_base_url=https%3A%2F%2Fpulse.kenshikilabs.com"
        let customURL = try XCTUnwrap(URL(string: "pulse://bond?\(query)"))
        let universalURL = try XCTUnwrap(URL(string: "https://kenshiki-pulse-worker-production.pulsekenshikilabscom.workers.dev/bond?\(query)"))

        let customRequest = try XCTUnwrap(PulseBondRequest(url: customURL))
        let universalRequest = try XCTUnwrap(PulseBondRequest(url: universalURL))

        XCTAssertEqual(customRequest, universalRequest)
        XCTAssertEqual(customRequest.sessionID, "sess_123")
        XCTAssertEqual(customRequest.nonce, "nonce_abc")
        XCTAssertEqual(customRequest.apiBaseURL?.absoluteString, "https://pulse.kenshikilabs.com")
    }

    func testRejectsUntrustedAPIBaseFromBondRequest() {
        let url = URL(string: "pulse://bond?session_id=sess_123&nonce=nonce_abc&api_base_url=https%3A%2F%2Fevil.example")!

        XCTAssertNil(PulseBondRequest(url: url))
    }

    func testRejectsApexBondRequest() {
        let url = URL(string: "https://kenshikilabs.com/bond?session_id=sess_123&nonce=nonce_abc")!

        XCTAssertNil(PulseBondRequest(url: url))
    }

    func testRejectsLocalhostBondRequest() {
        let url = URL(string: "http://localhost:4322/bond?session_id=sess_123&nonce=nonce_abc")!

        XCTAssertNil(PulseBondRequest(url: url))
    }

    func testRejectsPrivateIPBondRequest() {
        let url = URL(string: "https://192.168.1.10:4322/bond?session_id=sess_123&nonce=nonce_abc")!

        XCTAssertNil(PulseBondRequest(url: url))
    }

    func testRejectsMalformedBondRequest() {
        let url = URL(string: "https://pulse.kenshikilabs.com/not-bond?session_id=sess_123&nonce=nonce_abc")!

        XCTAssertNil(PulseBondRequest(url: url))
    }


    func testParsesOptionalActionCommitmentPayload() throws {
        let payload = PulseMaterialActionPayload(
            tenantID: "tenant_meridian",
            environment: .production,
            workflow: "credit_application",
            action: "submit_application",
            materialActionID: "act_123",
            sessionID: "sess_123",
            subjectID: "sub_123",
            deviceID: "dev_123",
            valueTier: .high,
            materialFields: ["amount": "10000.00", "currency": "USD"],
            createdAt: "2026-06-28T16:00:00.000Z",
            expiresAt: "2026-06-28T16:05:00.000Z"
        )
        let data = try payload.canonicalJSONData()
        let encoded = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let url = URL(string: "https://kenshiki-pulse-worker-production.pulsekenshikilabscom.workers.dev/bond?session_id=sess_123&nonce=nonce_abc&action_commitment=\(encoded)")!

        let request = try XCTUnwrap(PulseBondRequest(url: url))

        XCTAssertEqual(request.actionCommitmentPayload, payload)
    }

    func testRejectsMalformedActionCommitmentPayload() throws {
        let url = URL(string: "https://kenshiki-pulse-worker-production.pulsekenshikilabscom.workers.dev/bond?session_id=sess_123&nonce=nonce_abc&action_commitment=not-json")!

        XCTAssertNil(PulseBondRequest(url: url))
    }

    func testReturnURLIsNilWhenAbsent() throws {
        let url = URL(string: "https://kenshiki-pulse-worker-production.pulsekenshikilabscom.workers.dev/bond?session_id=s&nonce=n")!
        let request = try XCTUnwrap(PulseBondRequest(url: url))
        XCTAssertNil(request.returnURL)
    }

    func testParsesHTTPSReturnURL() throws {
        let url = URL(string: "https://kenshiki-pulse-worker-production.pulsekenshikilabscom.workers.dev/bond?session_id=s&nonce=n"
            + "&return_url=https%3A%2F%2Fpartner.com%2Fcheckout")!
        let request = try XCTUnwrap(PulseBondRequest(url: url))
        XCTAssertEqual(request.returnURL, URL(string: "https://partner.com/checkout"))
    }

    func testRejectsNonHTTPSReturnURL() throws {
        // http, custom scheme, and javascript: must all collapse to nil — never a tappable unsafe URL.
        for bad in ["http%3A%2F%2Fpartner.com", "pulse%3A%2F%2Fbond", "javascript%3Aalert(1)", "%2Frelative%2Fpath"] {
            let url = URL(string: "https://kenshiki-pulse-worker-production.pulsekenshikilabscom.workers.dev/bond?session_id=s&nonce=n&return_url=\(bad)")!
            let request = try XCTUnwrap(PulseBondRequest(url: url))
            XCTAssertNil(request.returnURL, "expected nil returnURL for \(bad)")
        }
    }

    func testProductionConfigurationUsesHostedEndpoints() {
        let config = PulseBondingConfiguration.kenshikiProduction

        XCTAssertEqual(config.attestationEndpoint.absoluteString, "https://kenshiki-pulse-worker-production.pulsekenshikilabscom.workers.dev/attestations")
        XCTAssertEqual(config.attestationEndpoint.scheme, "https")
        XCTAssertEqual(config.attestationEndpoint.host, "kenshiki-pulse-worker-production.pulsekenshikilabscom.workers.dev")
        XCTAssertFalse(config.attestationEndpoint.absoluteString.contains("localhost"))
        XCTAssertEqual(config.channelWebSocketBaseURL?.scheme, "wss")
        XCTAssertFalse(config.channelWebSocketBaseURL?.absoluteString.contains("localhost") ?? true)
    }

    func testWorkerBaseConfigurationDerivesHTTPAndWebSocketEndpoints() throws {
        let config = PulseBondingConfiguration(workerBaseURL: URL(string: "https://api.example/v1")!)

        XCTAssertEqual(config.attestationEndpoint.absoluteString, "https://api.example/v1/attestations")
        XCTAssertEqual(config.channelWebSocketBaseURL?.absoluteString, "wss://api.example/v1")
    }

    func testURLSessionTransportPostsAssertionToConfiguredEndpoint() async throws {
        let endpoint = URL(string: "https://kenshikilabs.com/api/v1/attestations")!
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockPulseURLProtocol.self]
        let transport = URLSessionPulseAttestationTransport(session: URLSession(configuration: sessionConfiguration))
        let assertion = Self.makeAssertion()
        let responseData = #"{"id":"sess_123","state":"bonded","device_id":"device_123","subject_id":"user_123","websocket_url":"wss://pulse-channel.example/sessions/sess_123"}"#.data(using: .utf8)!
        var capturedRequest: URLRequest?
        var capturedBody: Data?
        MockPulseURLProtocol.requestHandler = { request in
            capturedRequest = request
            capturedBody = Self.bodyData(from: request)
            return (
                HTTPURLResponse(
                    url: endpoint,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                responseData
            )
        }
        defer { MockPulseURLProtocol.requestHandler = nil }

        let response = try await transport.submit(
            assertion: assertion,
            configuration: PulseBondingConfiguration(attestationEndpoint: endpoint)
        )

        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.url, endpoint)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(response.id, "sess_123")
        XCTAssertEqual(response.state, "bonded")
        let body = try XCTUnwrap(capturedBody)
        let submitted = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(submitted["session_id"] as? String, assertion.sessionID)
        XCTAssertEqual(submitted["nonce"] as? String, assertion.nonce)
        XCTAssertNotNil(submitted["app_attest"] as? [String: Any])
        XCTAssertNotNil(submitted["verified_evidence"] as? [String: Any])
        XCTAssertNil(submitted["attestations"])
        XCTAssertNil(submitted["signature"])
    }

    func testURLSessionTransportPreservesCancellation() async throws {
        let endpoint = URL(string: "https://kenshikilabs.com/api/v1/attestations")!
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockPulseURLProtocol.self]
        let transport = URLSessionPulseAttestationTransport(session: URLSession(configuration: sessionConfiguration))
        MockPulseURLProtocol.requestHandler = { _ in throw CancellationError() }
        defer { MockPulseURLProtocol.requestHandler = nil }

        do {
            _ = try await transport.submit(
                assertion: Self.makeAssertion(),
                configuration: PulseBondingConfiguration(attestationEndpoint: endpoint)
            )
            XCTFail("Expected cancellation to be preserved")
        } catch is CancellationError {
            // Expected: the app can treat local teardown as local teardown, not approval failure.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    func testSubmitSendsAssertionThroughTransport() async throws {
        let response = PulseBondedSessionResponse(
            id: "sess_123",
            state: "bonded",
            deviceID: "device_123",
            subjectID: "user_123",
            webSocketURL: URL(string: "wss://pulse-channel.example/ws/sessions/sess_123")
        )
        let transport = RecordingPulseTransport(response: response)
        let client = PulseBondingClient(
            configuration: PulseBondingConfiguration(
                attestationEndpoint: URL(string: "https://api.example/v1/attestations")!,
                channelWebSocketBaseURL: URL(string: "wss://pulse-channel.example")!
            ),
            transport: transport
        )
        let assertion = Self.makeAssertion()

        let submitted = try await client.submit(assertion: assertion)
        let submittedAssertion = await transport.submitted
        let submittedConfiguration = await transport.configuration

        XCTAssertEqual(submitted, response)
        XCTAssertEqual(submittedAssertion?.sessionID, assertion.sessionID)
        XCTAssertEqual(submittedConfiguration?.attestationEndpoint.absoluteString, "https://api.example/v1/attestations")
        XCTAssertEqual(client.webSocketURL(for: "sess_123")?.absoluteString, "wss://pulse-channel.example/sessions/sess_123?role=mobile")
    }

    func testHeartbeatEncodesServerPayloadShape() throws {
        let heartbeat = PulseHeartbeat(
            sessionID: "sess_123",
            deviceID: "device_123",
            sequence: 12,
            issuedAt: Date(timeIntervalSince1970: 1_700_000_000),
            continuityHash: "hash_placeholder",
            signature: "base64url_signature"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let json = try XCTUnwrap(String(bytes: try encoder.encode(heartbeat), encoding: .utf8))

        XCTAssertTrue(json.contains("\"session_id\":\"sess_123\""))
        XCTAssertTrue(json.contains("\"device_id\":\"device_123\""))
        XCTAssertTrue(json.contains("\"seq\":12"))
        XCTAssertTrue(json.contains("\"continuity_hash\":\"hash_placeholder\""))
    }

    private static func bodyData(from request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 1_024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }

    private static func makeAssertion() -> BondedPairAssertion {
        BondedPairAssertion(
            sessionID: "sess_123",
            nonce: "nonce_abc",
            deviceID: "device_123",
            subjectID: "user_123",
            issuedAt: Date(timeIntervalSince1970: 1_700_000_000),
            appAttest: PulseAppAttestAssertion(
                keyID: "app-attest-key-id",
                clientDataHash: "base64url_client_data_hash",
                authenticatorData: "base64url_authenticator_data",
                signature: "base64url_ecdsa_signature"
            ),
            verifiedEvidence: VerifiedPulseEvidence(
                issuedAt: Date(timeIntervalSince1970: 1_700_000_000),
                expiresAt: Date(timeIntervalSince1970: 1_700_000_300),
                localAuth: PulseLocalAuthAttestation(method: "face_id", result: "verified"),
                carrier: PulseCarrierAttestation(
                    provider: "vonage_camara",
                    numberVerified: true,
                    simSwapRecent: false,
                    deviceStatus: "active"
                ),
                sensorContinuity: PulseSensorContinuityAttestation(
                    observationSeconds: 300,
                    motionPresent: true,
                    continuityScore: 0.84
                ),
                signature: "hmac_base64url_signature"
            )
        )
    }
}

private final class MockPulseURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let requestHandler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try requestHandler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private actor RecordingPulseTransport: PulseAttestationTransport {
    private(set) var submitted: BondedPairAssertion?
    private(set) var configuration: PulseBondingConfiguration?
    private let response: PulseBondedSessionResponse

    init(response: PulseBondedSessionResponse) {
        self.response = response
    }

    func submit(
        assertion: BondedPairAssertion,
        configuration: PulseBondingConfiguration
    ) async throws -> PulseBondedSessionResponse {
        submitted = assertion
        self.configuration = configuration
        return response
    }
}
