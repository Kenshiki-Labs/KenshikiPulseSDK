import XCTest

@testable import KenshikiPulseSDK

final class PulseActionCommitmentClientTests: XCTestCase {
    func testPayloadHashIsStableAndMaterialFieldSensitive() throws {
        let payload = Self.payload()
        let hash = try payload.payloadHash()
        XCTAssertTrue(hash.hasPrefix("sha256:"))
        XCTAssertEqual(hash.count, 50)
        XCTAssertEqual(hash, try Self.payload().payloadHash())
        XCTAssertNotEqual(hash, try Self.payload(materialFields: ["amount": "100000.00", "currency": "USD"]).payloadHash())
    }


    func testMatchesWorkerCanonicalPayloadVector() throws {
        let payload = Self.workerVectorPayload()
        XCTAssertEqual(
            try payload.canonicalJSONString(),
            "{\"action\":\"submit_application\",\"created_at\":\"2026-06-28T15:00:00.000Z\",\"device_id\":\"dev_123\",\"environment\":\"production\",\"expires_at\":\"2026-06-28T15:05:00.000Z\",\"material_action_id\":\"act_10000\",\"material_fields\":{\"address_ref\":\"addr_ref_456\",\"applicant_identity_ref\":\"identity_ref_123\",\"currency\":\"USD\",\"declared_income_band\":\"75000-99999\",\"product_type\":\"personal_loan\",\"requested_amount\":\"10000.00\"},\"session_id\":\"sess_action\",\"subject_id\":\"sub_123\",\"tenant_id\":\"tenant_meridian\",\"value_tier\":\"high\",\"workflow\":\"credit_application\"}"  // swiftlint:disable:this line_length
        )
        XCTAssertEqual(try payload.payloadHash(), "sha256:gNaGQGon0oMBMvXiPIcnp_yaiFOlJG29KJu9Rv18pvQ")
    }

    func testSigningInputMatchesWorkerVectorAndFeedsSigner() async throws {
        let payload = Self.workerVectorPayload()
        let challenge = PulseActionCommitmentChallengeResponse(
            challengeID: "ac_123",
            nonce: "nonce_action_commitment",
            sessionID: payload.sessionID,
            materialActionID: payload.materialActionID,
            payloadHash: try payload.payloadHash(),
            workflow: payload.workflow,
            action: payload.action,
            tenantID: payload.tenantID,
            valueTier: payload.valueTier,
            expiresAt: payload.expiresAt,
            signingProfile: "pulse_action_commitment_v1",
            displayIntent: ["title": "Submit application", "amount": "$10,000"]
        )
        let localAuth = PulseActionCommitmentLocalAuth(
            method: "face_id",
            verifiedAt: "2026-06-28T15:00:59.000Z"
        )
        let signingInput = PulseActionCommitmentSigningInput(
            challenge: challenge,
            issuedAt: "2026-06-28T15:01:00.000Z",
            localAuth: localAuth
        )
        XCTAssertEqual(
            try signingInput.canonicalJSONString(),
            "{\"action\":\"submit_application\",\"challenge_id\":\"ac_123\",\"issued_at\":\"2026-06-28T15:01:00.000Z\",\"local_auth\":{\"method\":\"face_id\",\"result\":\"verified\",\"verified_at\":\"2026-06-28T15:00:59.000Z\"},\"material_action_id\":\"act_10000\",\"nonce\":\"nonce_action_commitment\",\"payload_hash\":\"sha256:gNaGQGon0oMBMvXiPIcnp_yaiFOlJG29KJu9Rv18pvQ\",\"session_id\":\"sess_action\",\"tenant_id\":\"tenant_meridian\",\"value_tier\":\"high\",\"workflow\":\"credit_application\"}"  // swiftlint:disable:this line_length
        )
        XCTAssertEqual(try signingInput.clientDataHash(), "lK_S49fd2uCbFV24fTJSXRgAE0J4S4GYfX0n0TmGRZU")

        let signer = MockActionCommitmentSigner()
        let client = PulseActionCommitmentClient(
            configuration: PulsePassportIdentityConfiguration(baseURL: URL(string: "https://api.example")!),
            transport: MockActionCommitmentTransport()
        )
        let commitment = try await client.buildCommitment(
            challenge: challenge,
            issuedAt: signingInput.issuedAt,
            localAuth: localAuth,
            signer: signer
        )
        XCTAssertEqual(signer.lastInput, signingInput)
        XCTAssertEqual(commitment.workflow, "credit_application")
        XCTAssertEqual(commitment.appAttest?.clientDataHash, "lK_S49fd2uCbFV24fTJSXRgAE0J4S4GYfX0n0TmGRZU")
        XCTAssertEqual(commitment.appAttest?.assertionObject, "raw_assertion_object")
        XCTAssertNil(commitment.appAttest?.authenticatorData)
        XCTAssertNil(commitment.appAttest?.signature)
    }

    func testDisplayIntentSeparatesTitleSummaryFromMaterialFields() {
        let challenge = PulseActionCommitmentChallengeResponse(
            challengeID: "ac_123",
            nonce: "nonce_action",
            sessionID: "sess_123",
            materialActionID: "act_123",
            payloadHash: "sha256:payload",
            workflow: "credit_application",
            action: "submit_application",
            tenantID: "tenant_meridian",
            valueTier: .high,
            expiresAt: "2026-06-28T15:05:00.000Z",
            signingProfile: "pulse_action_commitment_v1",
            displayIntent: ["title": "Submit application", "summary": "Review before approving", "amount": "$10,000"]
        )
        let intent = PulseActionCommitmentDisplayIntent(challenge: challenge)
        XCTAssertEqual(intent.title, "Submit application")
        XCTAssertEqual(intent.summary, "Review before approving")
        XCTAssertEqual(intent.fields, ["amount": "$10,000"])
    }

    func testChallengeRequestPostsWorkerContractShape() async throws {
        let baseURL = URL(string: "https://api.example/v1")!
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockActionCommitmentURLProtocol.self]
        let transport = URLSessionPulseActionCommitmentTransport(session: URLSession(configuration: sessionConfiguration))
        let responseData = """
        {
          "challenge_id": "tc_123",
          "nonce": "nonce_action",
          "session_id": "sess_123",
          "material_action_id": "act_123",
          "payload_hash": "sha256:payload",
          "value_tier": "high",
          "workflow": "credit_application",
          "action": "submit_application",
          "tenant_id": "tenant_meridian",
          "expires_at": "2026-06-28T15:05:00.000Z",
          "signing_profile": "pulse_action_commitment_v1",
          "display_intent": { "amount": "$10,000" }
        }
        """.data(using: .utf8)!
        var capturedRequest: URLRequest?
        var capturedBody: Data?
        MockActionCommitmentURLProtocol.requestHandler = { request in
            capturedRequest = request
            capturedBody = Self.bodyData(from: request)
            return (
                HTTPURLResponse(url: baseURL, statusCode: 201, httpVersion: nil, headerFields: nil)!,
                responseData
            )
        }
        defer { MockActionCommitmentURLProtocol.requestHandler = nil }

        let response = try await transport.requestChallenge(
            PulseActionCommitmentChallengeRequest(payload: Self.payload()),
            configuration: PulsePassportIdentityConfiguration(baseURL: baseURL, apiKey: "secret")
        )

        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.url?.absoluteString, "https://api.example/v1/action-commitments/challenges")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
        XCTAssertEqual(response.challengeID, "tc_123")

        let body = try XCTUnwrap(capturedBody)
        let submitted = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(submitted["session_id"] as? String, "sess_123")
        XCTAssertEqual(submitted["tenant_id"] as? String, "tenant_meridian")
        XCTAssertEqual(submitted["material_action_id"] as? String, "act_123")
        XCTAssertEqual(submitted["action"] as? String, "submit_application")
        XCTAssertEqual(submitted["device_id"] as? String, "dev_123")
        XCTAssertEqual(submitted["subject_id"] as? String, "sub_123")
        XCTAssertEqual(submitted["value_tier"] as? String, "high")
        XCTAssertEqual(submitted["payload_hash"] as? String, try Self.payload().payloadHash())
    }

    func testAuthorizePostsPayloadAndDeviceCommitment() async throws {
        let baseURL = URL(string: "https://api.example/v1")!
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockActionCommitmentURLProtocol.self]
        let transport = URLSessionPulseActionCommitmentTransport(session: URLSession(configuration: sessionConfiguration))
        let payload = Self.payload()
        let challenge = PulseActionCommitmentChallengeResponse(
            challengeID: "tc_123",
            nonce: "nonce_action",
            sessionID: "sess_123",
            materialActionID: "act_123",
            payloadHash: try payload.payloadHash(),
            workflow: "credit_application",
            action: "submit_application",
            tenantID: "tenant_meridian",
            valueTier: .high,
            expiresAt: "2026-06-28T15:05:00.000Z",
            signingProfile: "pulse_action_commitment_v1",
            displayIntent: ["amount": "$10,000"]
        )
        let responseData = """
        {
          "material_action_id": "act_123",
          "status": "authorized",
          "payload_hash": "\(try payload.payloadHash())",
          "audit_artifact_id": "audit_123"
        }
        """.data(using: .utf8)!
        var capturedRequest: URLRequest?
        var capturedBody: Data?
        MockActionCommitmentURLProtocol.requestHandler = { request in
            capturedRequest = request
            capturedBody = Self.bodyData(from: request)
            return (
                HTTPURLResponse(url: baseURL, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                responseData
            )
        }
        defer { MockActionCommitmentURLProtocol.requestHandler = nil }

        let response = try await transport.authorize(
            PulseActionCommitmentAuthorizationRequest(
                payload: payload,
                commitment: PulseActionCommitment(
                    challenge: challenge,
                    issuedAt: "2026-06-28T15:01:00.000Z",
                    localAuth: PulseActionCommitmentLocalAuth(method: "face_id", verifiedAt: "2026-06-28T15:00:59.000Z")
                )
            ),
            configuration: PulsePassportIdentityConfiguration(baseURL: baseURL)
        )

        XCTAssertEqual(response.status, "authorized")
        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.url?.absoluteString, "https://api.example/v1/action-commitments/authorize")
        let body = try XCTUnwrap(capturedBody)
        let submitted = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertNotNil(submitted["payload"] as? [String: Any])
        let commitment = try XCTUnwrap(submitted["commitment"] as? [String: Any])
        XCTAssertEqual(commitment["challenge_id"] as? String, "tc_123")
        XCTAssertEqual(commitment["payload_hash"] as? String, try payload.payloadHash())
        XCTAssertEqual(commitment["value_tier"] as? String, "high")
        XCTAssertNotNil(commitment["local_auth"] as? [String: Any])
    }

    private static func payload(materialFields: [String: String] = ["amount": "10000.00", "currency": "USD"]) -> PulseMaterialActionPayload {
        PulseMaterialActionPayload(
            tenantID: "tenant_meridian",
            environment: .production,
            workflow: "credit_application",
            action: "submit_application",
            materialActionID: "act_123",
            sessionID: "sess_123",
            subjectID: "sub_123",
            deviceID: "dev_123",
            valueTier: .high,
            materialFields: materialFields,
            createdAt: "2026-06-28T15:00:00.000Z",
            expiresAt: "2026-06-28T15:05:00.000Z"
        )
    }


    private static func workerVectorPayload() -> PulseMaterialActionPayload {
        PulseMaterialActionPayload(
            tenantID: "tenant_meridian",
            environment: .production,
            workflow: "credit_application",
            action: "submit_application",
            materialActionID: "act_10000",
            sessionID: "sess_action",
            subjectID: "sub_123",
            deviceID: "dev_123",
            valueTier: .high,
            materialFields: [
                "applicant_identity_ref": "identity_ref_123",
                "declared_income_band": "75000-99999",
                "product_type": "personal_loan",
                "requested_amount": "10000.00",
                "currency": "USD",
                "address_ref": "addr_ref_456"
            ],
            createdAt: "2026-06-28T15:00:00.000Z",
            expiresAt: "2026-06-28T15:05:00.000Z"
        )
    }

    private static func bodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: bufferSize)
            if count > 0 { data.append(buffer, count: count) } else { break }
        }
        return data
    }
}


private final class MockActionCommitmentSigner: PulseActionCommitmentSigner, @unchecked Sendable {
    private(set) var lastInput: PulseActionCommitmentSigningInput?

    func signActionCommitment(_ input: PulseActionCommitmentSigningInput) async throws -> PulseAppAttestAssertion {
        lastInput = input
        return PulseAppAttestAssertion(
            keyID: "key_123",
            clientDataHash: try input.clientDataHash(),
            assertionObject: "raw_assertion_object"
        )
    }
}

private struct MockActionCommitmentTransport: PulseActionCommitmentTransport {
    func requestChallenge(
        _ request: PulseActionCommitmentChallengeRequest,
        configuration: PulsePassportIdentityConfiguration
    ) async throws -> PulseActionCommitmentChallengeResponse {
        PulseActionCommitmentChallengeResponse(
            challengeID: "unused",
            nonce: "unused",
            sessionID: request.sessionID,
            materialActionID: request.materialActionID,
            payloadHash: request.payloadHash,
            workflow: request.workflow,
            action: request.action,
            tenantID: request.tenantID,
            valueTier: request.valueTier,
            expiresAt: "2026-06-28T15:05:00.000Z",
            signingProfile: "pulse_action_commitment_v1",
            displayIntent: [:]
        )
    }

    func authorize(
        _ request: PulseActionCommitmentAuthorizationRequest,
        configuration: PulsePassportIdentityConfiguration
    ) async throws -> PulseActionCommitmentAuthorizationResponse {
        PulseActionCommitmentAuthorizationResponse(
            materialActionID: request.payload.materialActionID,
            status: "authorized_shadow",
            payloadHash: try request.payload.payloadHash(),
            auditArtifactID: nil
        )
    }
}

private final class MockActionCommitmentURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
