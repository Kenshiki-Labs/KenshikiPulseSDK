import XCTest

@testable import KenshikiPulseSDK

final class PulsePassportIdentityClientTests: XCTestCase {
    func testProductionConfigurationUsesHostedPassportAPI() {
        let config = PulsePassportIdentityConfiguration.kenshikiProduction

        XCTAssertEqual(config.baseURL.absoluteString, "https://kenshiki-pulse-worker-production.pulsekenshikilabscom.workers.dev")
        XCTAssertEqual(config.baseURL.scheme, "https")
        XCTAssertEqual(config.baseURL.host, "kenshiki-pulse-worker-production.pulsekenshikilabscom.workers.dev")
        XCTAssertFalse(config.baseURL.absoluteString.contains("localhost"))
    }

    func testIssueNoncePostsWorkerContractShape() async throws {
        let baseURL = URL(string: "https://api.example/v1")!
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockPassportIdentityURLProtocol.self]
        let transport = URLSessionPulsePassportIdentityTransport(session: URLSession(configuration: sessionConfiguration))
        let responseData = """
        {
          "session_id": "sess_123",
          "nonce_id": "pn_123",
          "nonce": "nonce_passport",
          "expires_at": "2026-06-27T18:05:00.000Z",
          "iac_key_id": "iac_current",
          "workflow": "passport_identity",
          "payload_commitment_hash": "sha256:payload"
        }
        """.data(using: .utf8)!
        var capturedRequest: URLRequest?
        var capturedBody: Data?
        MockPassportIdentityURLProtocol.requestHandler = { request in
            capturedRequest = request
            capturedBody = Self.bodyData(from: request)
            return (
                HTTPURLResponse(url: baseURL, statusCode: 201, httpVersion: nil, headerFields: nil)!,
                responseData
            )
        }
        defer { MockPassportIdentityURLProtocol.requestHandler = nil }

        let response = try await transport.issueNonce(
            PassportNonceRequest(
                sessionID: "sess_123",
                sessionNonce: "nonce_bond",
                deviceID: "device_123",
                attestationID: "attest_123",
                workflow: .passportIdentity,
                payloadCommitmentHash: "sha256:payload"
            ),
            configuration: PulsePassportIdentityConfiguration(baseURL: baseURL, apiKey: "secret")
        )

        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.url?.absoluteString, "https://api.example/v1/passport/nonce")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
        XCTAssertEqual(response.nonceID, "pn_123")
        XCTAssertEqual(response.iacKeyID, "iac_current")

        let body = try XCTUnwrap(capturedBody)
        let submitted = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(submitted["session_id"] as? String, "sess_123")
        XCTAssertEqual(submitted["session_nonce"] as? String, "nonce_bond")
        XCTAssertEqual(submitted["device_id"] as? String, "device_123")
        XCTAssertEqual(submitted["attestation_id"] as? String, "attest_123")
        XCTAssertEqual(submitted["workflow"] as? String, "passport_identity")
        XCTAssertEqual(submitted["payload_commitment_hash"] as? String, "sha256:payload")
    }

    func testVerifyPostsProofAndDecodesFailedValidationReceipt() async throws {
        let baseURL = URL(string: "https://api.example/v1")!
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockPassportIdentityURLProtocol.self]
        let transport = URLSessionPulsePassportIdentityTransport(session: URLSession(configuration: sessionConfiguration))
        let responseData = """
        {
          "session_id": "sess_123",
          "nonce_id": "pn_123",
          "status": "failed",
          "validation": {
            "result": "failed",
            "validator": "passport_validator",
            "receiptId": "receipt_123",
            "sodVerified": true,
            "dscVerified": true,
            "cscaVerified": false,
            "dataGroupHashesVerified": true,
            "chipAuthenticated": true,
            "crlChecked": true,
            "documentExpired": false,
            "failureReason": "passport_policy_failed:csca_chain"
          }
        }
        """.data(using: .utf8)!
        var capturedRequest: URLRequest?
        var capturedBody: Data?
        MockPassportIdentityURLProtocol.requestHandler = { request in
            capturedRequest = request
            capturedBody = Self.bodyData(from: request)
            return (
                HTTPURLResponse(url: baseURL, statusCode: 403, httpVersion: nil, headerFields: nil)!,
                responseData
            )
        }
        defer { MockPassportIdentityURLProtocol.requestHandler = nil }

        let response = try await transport.verify(
            PassportVerifyRequest(
                nonce: Self.nonceResponse(),
                deviceID: "device_123",
                walletIdentity: PassportWalletProof(encryptedDocument: "wallet_document"),
                nfcPassport: PassportNfcProof(
                    sod: "sod",
                    documentSigningCertificate: "dsc",
                    dataGroups: ["DG1": "dg1"],
                    activeAuthentication: PassportChipProof(challenge: "challenge", signature: "signature")
                )
            ),
            configuration: PulsePassportIdentityConfiguration(baseURL: baseURL)
        )

        XCTAssertFalse(response.isVerified)
        XCTAssertEqual(response.validation.failureReason, "passport_policy_failed:csca_chain")
        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.url?.absoluteString, "https://api.example/v1/passport/verify")

        let body = try XCTUnwrap(capturedBody)
        let submitted = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(submitted["session_id"] as? String, "sess_123")
        XCTAssertEqual(submitted["nonce_id"] as? String, "pn_123")
        XCTAssertEqual(submitted["nonce"] as? String, "nonce_passport")
        XCTAssertEqual(submitted["iac_key_id"] as? String, "iac_current")
        XCTAssertNotNil(submitted["wallet_identity"] as? [String: Any])
        XCTAssertNotNil(submitted["nfc_passport"] as? [String: Any])
    }

    func testNfcProofEncodesRawEvidenceAndStripsDG2() throws {
        let chipData = PassportChipData(
            documentNumber: "A12345678",
            surname: "DOE",
            givenNames: "JANE",
            nationality: "USA",
            issuingState: "USA",
            dateOfBirth: "900101",
            expiryDate: "310101",
            gender: "F",
            personalNumber: nil,
            authLevel: .activeAuthenticated,
            cscaVerified: true,
            documentSigningCertVerified: true,
            documentSigningCertificate: Data([0x30, 0x82]),
            activeAuthChallenge: Data([0xfb, 0xff]),
            activeAuthSignature: Data([0x01, 0x02, 0x03]),
            securityObject: Data([0x77, 0x88]),
            dataGroups: [
                "SOD": Data([0x77, 0x88]),
                "DG1": Data([0x11, 0x22]),
                "DG2": Data([0x33, 0x44]),
                "DG15": Data([0x55, 0x66])
            ]
        )

        let proof = try PassportNfcProof(chipData: chipData)

        XCTAssertEqual(proof.sod, Data([0x77, 0x88]).base64EncodedString())
        XCTAssertEqual(proof.documentSigningCertificate, Data([0x30, 0x82]).base64EncodedString())
        XCTAssertEqual(proof.dataGroups["DG1"], Data([0x11, 0x22]).base64EncodedString())
        XCTAssertEqual(proof.dataGroups["DG15"], Data([0x55, 0x66]).base64EncodedString())
        XCTAssertNil(proof.dataGroups["SOD"])
        XCTAssertNil(proof.dataGroups["DG2"])
        XCTAssertEqual(proof.activeAuthentication?.challenge, "-_8")
        XCTAssertEqual(proof.activeAuthentication?.signature, "AQID")
    }

    func testNfcProofAllowsPassiveEvidenceWithoutNonceBoundActiveAuthentication() throws {
        let chipData = PassportChipData(
            documentNumber: "A12345678",
            surname: "DOE",
            givenNames: "JANE",
            nationality: "USA",
            issuingState: "USA",
            dateOfBirth: "900101",
            expiryDate: "310101",
            gender: "F",
            personalNumber: nil,
            authLevel: .chipAuthenticated,
            cscaVerified: true,
            documentSigningCertVerified: true,
            documentSigningCertificate: Data([0x30, 0x82]),
            securityObject: Data([0x77, 0x88]),
            dataGroups: ["SOD": Data([0x77, 0x88]), "DG1": Data([0x11, 0x22])]
        )

        let proof = try PassportNfcProof(chipData: chipData)

        XCTAssertEqual(proof.sod, Data([0x77, 0x88]).base64EncodedString())
        XCTAssertEqual(proof.documentSigningCertificate, Data([0x30, 0x82]).base64EncodedString())
        XCTAssertEqual(proof.dataGroups["DG1"], Data([0x11, 0x22]).base64EncodedString())
        XCTAssertNil(proof.activeAuthentication)
    }

    private static func nonceResponse() -> PassportNonceResponse {
        PassportNonceResponse(
            sessionID: "sess_123",
            nonceID: "pn_123",
            nonce: "nonce_passport",
            expiresAt: "2026-06-27T18:05:00.000Z",
            iacKeyID: "iac_current",
            workflow: .passportIdentity,
            payloadCommitmentHash: nil
        )
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
}

private final class MockPassportIdentityURLProtocol: URLProtocol {
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
