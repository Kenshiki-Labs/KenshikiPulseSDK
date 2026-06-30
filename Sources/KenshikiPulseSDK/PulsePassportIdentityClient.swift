import Foundation

public enum PassportIdentityWorkflow: String, Codable, Equatable, Sendable {
    case nfcPassport = "nfc_passport"
    case appleWallet = "apple_wallet"
    case passportIdentity = "passport_identity"
}

public enum PassportIdentityValidationResult: String, Codable, Equatable, Sendable {
    case verified
    case failed
}

public struct PulsePassportIdentityConfiguration: Equatable, Sendable {
    public static let kenshikiProduction = PulsePassportIdentityConfiguration(
        baseURL: URL(string: "https://kenshiki-pulse-worker-production.pulsekenshikilabscom.workers.dev")!
    )

    public let baseURL: URL
    public let apiKey: String?
    public let additionalHeaders: [String: String]

    public init(
        baseURL: URL,
        apiKey: String? = nil,
        additionalHeaders: [String: String] = [:]
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.additionalHeaders = additionalHeaders
    }
}

public struct PassportNonceRequest: Codable, Equatable, Sendable {
    public let sessionID: String
    public let sessionNonce: String
    public let deviceID: String
    public let attestationID: String?
    public let workflow: PassportIdentityWorkflow
    public let payloadCommitmentHash: String?

    public init(
        sessionID: String,
        sessionNonce: String,
        deviceID: String,
        attestationID: String? = nil,
        workflow: PassportIdentityWorkflow,
        payloadCommitmentHash: String? = nil
    ) {
        self.sessionID = sessionID
        self.sessionNonce = sessionNonce
        self.deviceID = deviceID
        self.attestationID = attestationID
        self.workflow = workflow
        self.payloadCommitmentHash = payloadCommitmentHash
    }

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case sessionNonce = "session_nonce"
        case deviceID = "device_id"
        case attestationID = "attestation_id"
        case workflow
        case payloadCommitmentHash = "payload_commitment_hash"
    }
}

public struct PassportNonceResponse: Codable, Equatable, Sendable {
    public let sessionID: String
    public let nonceID: String
    public let nonce: String
    public let expiresAt: String
    public let iacKeyID: String
    public let workflow: PassportIdentityWorkflow
    public let payloadCommitmentHash: String?

    public init(
        sessionID: String,
        nonceID: String,
        nonce: String,
        expiresAt: String,
        iacKeyID: String,
        workflow: PassportIdentityWorkflow,
        payloadCommitmentHash: String? = nil
    ) {
        self.sessionID = sessionID
        self.nonceID = nonceID
        self.nonce = nonce
        self.expiresAt = expiresAt
        self.iacKeyID = iacKeyID
        self.workflow = workflow
        self.payloadCommitmentHash = payloadCommitmentHash
    }

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case nonceID = "nonce_id"
        case nonce
        case expiresAt = "expires_at"
        case iacKeyID = "iac_key_id"
        case workflow
        case payloadCommitmentHash = "payload_commitment_hash"
    }
}

public struct PassportWalletProof: Codable, Equatable, Sendable {
    public let encryptedDocument: String
    public let requestID: String?
    public let signedResponse: String?

    public init(encryptedDocument: String, requestID: String? = nil, signedResponse: String? = nil) {
        self.encryptedDocument = encryptedDocument
        self.requestID = requestID
        self.signedResponse = signedResponse
    }

    enum CodingKeys: String, CodingKey {
        case encryptedDocument = "encrypted_document"
        case requestID = "request_id"
        case signedResponse = "signed_response"
    }
}

public struct PassportChipProof: Codable, Equatable, Sendable {
    public let challenge: String
    public let signature: String
    public let publicKey: String?

    public init(challenge: String, signature: String, publicKey: String? = nil) {
        self.challenge = challenge
        self.signature = signature
        self.publicKey = publicKey
    }

    enum CodingKeys: String, CodingKey {
        case challenge
        case signature
        case publicKey = "public_key"
    }
}

public struct PassportNfcProof: Codable, Equatable, Sendable {
    public let sod: String
    public let documentSigningCertificate: String
    public let dataGroups: [String: String]
    public let activeAuthentication: PassportChipProof?
    public let chipAuthentication: PassportChipProof?

    public init(
        sod: String,
        documentSigningCertificate: String,
        dataGroups: [String: String],
        activeAuthentication: PassportChipProof? = nil,
        chipAuthentication: PassportChipProof? = nil
    ) {
        self.sod = sod
        self.documentSigningCertificate = documentSigningCertificate
        self.dataGroups = dataGroups
        self.activeAuthentication = activeAuthentication
        self.chipAuthentication = chipAuthentication
    }

    public init(chipData: PassportChipData) throws {
        guard let sod = chipData.securityObject ?? chipData.firstDataGroup(namedLike: "SOD") else {
            throw KenshikiPulseError.encodingFailed("Passport SOD is missing from the NFC proof.")
        }
        guard let dsc = chipData.documentSigningCertificate else {
            throw KenshikiPulseError.encodingFailed("Passport document signing certificate is missing from the NFC proof.")
        }

        var encodedGroups: [String: String] = [:]
        for (name, bytes) in chipData.dataGroups
            where !name.uppercased().contains("SOD") && name.uppercased() != "DG2" {
            encodedGroups[name] = bytes.base64EncodedString()
        }

        let aaProof: PassportChipProof?
        if let challenge = chipData.activeAuthChallenge, let signature = chipData.activeAuthSignature {
            aaProof = PassportChipProof(
                challenge: challenge.base64URLEncodedString(),
                signature: signature.base64URLEncodedString()
            )
        } else {
            aaProof = nil
        }

        self.init(
            sod: sod.base64EncodedString(),
            documentSigningCertificate: dsc.base64EncodedString(),
            dataGroups: encodedGroups,
            activeAuthentication: aaProof,
            chipAuthentication: nil
        )
    }

    enum CodingKeys: String, CodingKey {
        case sod
        case documentSigningCertificate = "document_signing_certificate"
        case dataGroups = "data_groups"
        case activeAuthentication = "active_authentication"
        case chipAuthentication = "chip_authentication"
    }
}

public struct PassportVerifyRequest: Codable, Equatable, Sendable {
    public let sessionID: String
    public let deviceID: String
    public let nonceID: String?
    public let nonce: String
    public let workflow: PassportIdentityWorkflow
    public let iacKeyID: String
    public let payloadCommitmentHash: String?
    public let walletIdentity: PassportWalletProof?
    public let nfcPassport: PassportNfcProof?
    public let developmentResult: PassportValidationSummary?

    public init(
        sessionID: String,
        deviceID: String,
        nonceID: String?,
        nonce: String,
        workflow: PassportIdentityWorkflow,
        iacKeyID: String,
        payloadCommitmentHash: String? = nil,
        walletIdentity: PassportWalletProof? = nil,
        nfcPassport: PassportNfcProof? = nil,
        developmentResult: PassportValidationSummary? = nil
    ) {
        self.sessionID = sessionID
        self.deviceID = deviceID
        self.nonceID = nonceID
        self.nonce = nonce
        self.workflow = workflow
        self.iacKeyID = iacKeyID
        self.payloadCommitmentHash = payloadCommitmentHash
        self.walletIdentity = walletIdentity
        self.nfcPassport = nfcPassport
        self.developmentResult = developmentResult
    }

    public init(
        nonce: PassportNonceResponse,
        deviceID: String,
        walletIdentity: PassportWalletProof? = nil,
        nfcPassport: PassportNfcProof? = nil,
        developmentResult: PassportValidationSummary? = nil
    ) {
        self.init(
            sessionID: nonce.sessionID,
            deviceID: deviceID,
            nonceID: nonce.nonceID,
            nonce: nonce.nonce,
            workflow: nonce.workflow,
            iacKeyID: nonce.iacKeyID,
            payloadCommitmentHash: nonce.payloadCommitmentHash,
            walletIdentity: walletIdentity,
            nfcPassport: nfcPassport,
            developmentResult: developmentResult
        )
    }

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case deviceID = "device_id"
        case nonceID = "nonce_id"
        case nonce
        case workflow
        case iacKeyID = "iac_key_id"
        case payloadCommitmentHash = "payload_commitment_hash"
        case walletIdentity = "wallet_identity"
        case nfcPassport = "nfc_passport"
        case developmentResult = "development_result"
    }
}

public struct PassportValidationSummary: Codable, Equatable, Sendable {
    public let result: PassportIdentityValidationResult
    public let validator: String
    public let receiptID: String?
    public let sodVerified: Bool
    public let dscVerified: Bool
    public let cscaVerified: Bool
    public let dataGroupHashesVerified: Bool
    public let chipAuthenticated: Bool
    public let crlChecked: Bool
    public let documentExpired: Bool?
    public let failureReason: String?

    public init(
        result: PassportIdentityValidationResult,
        validator: String,
        receiptID: String?,
        sodVerified: Bool,
        dscVerified: Bool,
        cscaVerified: Bool,
        dataGroupHashesVerified: Bool,
        chipAuthenticated: Bool,
        crlChecked: Bool,
        documentExpired: Bool?,
        failureReason: String?
    ) {
        self.result = result
        self.validator = validator
        self.receiptID = receiptID
        self.sodVerified = sodVerified
        self.dscVerified = dscVerified
        self.cscaVerified = cscaVerified
        self.dataGroupHashesVerified = dataGroupHashesVerified
        self.chipAuthenticated = chipAuthenticated
        self.crlChecked = crlChecked
        self.documentExpired = documentExpired
        self.failureReason = failureReason
    }

    // The Pulse Worker serializes this summary in camelCase (the PassportValidationSummary
    // interface), so decode/encode MUST be camelCase — unlike the snake_case request envelopes.
    // The worker's request parser also accepts these camelCase keys for the development_result we
    // send. (Snake_case here silently fails to decode every verify response.)
    enum CodingKeys: String, CodingKey {
        case result
        case validator
        case receiptID = "receiptId"
        case sodVerified
        case dscVerified
        case cscaVerified
        case dataGroupHashesVerified
        case chipAuthenticated
        case crlChecked
        case documentExpired
        case failureReason
    }
}

public struct PassportValidationResponse: Codable, Equatable, Sendable {
    public let sessionID: String
    public let nonceID: String
    public let status: PassportIdentityValidationResult
    public let validation: PassportValidationSummary

    public var isVerified: Bool {
        status == .verified && validation.result == .verified
    }

    public init(
        sessionID: String,
        nonceID: String,
        status: PassportIdentityValidationResult,
        validation: PassportValidationSummary
    ) {
        self.sessionID = sessionID
        self.nonceID = nonceID
        self.status = status
        self.validation = validation
    }

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case nonceID = "nonce_id"
        case status
        case validation
    }
}

public protocol PulsePassportIdentityTransport: Sendable {
    func issueNonce(
        _ request: PassportNonceRequest,
        configuration: PulsePassportIdentityConfiguration
    ) async throws -> PassportNonceResponse

    func verify(
        _ request: PassportVerifyRequest,
        configuration: PulsePassportIdentityConfiguration
    ) async throws -> PassportValidationResponse
}

public struct PulsePassportIdentityClient: Sendable {
    private let configuration: PulsePassportIdentityConfiguration
    private let transport: PulsePassportIdentityTransport

    public init(
        configuration: PulsePassportIdentityConfiguration,
        transport: PulsePassportIdentityTransport = URLSessionPulsePassportIdentityTransport()
    ) {
        self.configuration = configuration
        self.transport = transport
    }

    public func issueNonce(
        sessionID: String,
        sessionNonce: String,
        deviceID: String,
        attestationID: String? = nil,
        workflow: PassportIdentityWorkflow,
        payloadCommitmentHash: String? = nil
    ) async throws -> PassportNonceResponse {
        try await transport.issueNonce(
            PassportNonceRequest(
                sessionID: sessionID,
                sessionNonce: sessionNonce,
                deviceID: deviceID,
                attestationID: attestationID,
                workflow: workflow,
                payloadCommitmentHash: payloadCommitmentHash
            ),
            configuration: configuration
        )
    }

    public func verify(_ request: PassportVerifyRequest) async throws -> PassportValidationResponse {
        try await transport.verify(request, configuration: configuration)
    }
}

public struct URLSessionPulsePassportIdentityTransport: PulsePassportIdentityTransport {
    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(session: URLSession = .shared) {
        self.session = session
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
    }

    public func issueNonce(
        _ body: PassportNonceRequest,
        configuration: PulsePassportIdentityConfiguration
    ) async throws -> PassportNonceResponse {
        let request = try makeRequest(
            configuration: configuration,
            pathComponents: ["passport", "nonce"],
            body: body
        )
        return try await send(request, decoding: PassportNonceResponse.self, allowValidationFailure: false)
    }

    public func verify(
        _ body: PassportVerifyRequest,
        configuration: PulsePassportIdentityConfiguration
    ) async throws -> PassportValidationResponse {
        let request = try makeRequest(
            configuration: configuration,
            pathComponents: ["passport", "verify"],
            body: body
        )
        return try await send(request, decoding: PassportValidationResponse.self, allowValidationFailure: true)
    }

    private func makeRequest<Body: Encodable>(
        configuration: PulsePassportIdentityConfiguration,
        pathComponents: [String],
        body: Body
    ) throws -> URLRequest {
        var url = configuration.baseURL
        for component in pathComponents {
            url.appendPathComponent(component)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("KenshikiPulseSDK/\(KenshikiPulseConstants.sdkVersion)", forHTTPHeaderField: "User-Agent")

        if let apiKey = configuration.apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        for (header, value) in configuration.additionalHeaders {
            request.setValue(value, forHTTPHeaderField: header)
        }

        do {
            request.httpBody = try encoder.encode(body)
        } catch {
            throw KenshikiPulseError.encodingFailed(error.localizedDescription)
        }

        return request
    }

    private func send<Response: Decodable>(
        _ request: URLRequest,
        decoding responseType: Response.Type,
        allowValidationFailure: Bool
    ) async throws -> Response {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch where Self.isCancellation(error) {
            throw CancellationError()
        } catch {
            throw KenshikiPulseError.networkFailed(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw KenshikiPulseError.invalidHTTPResponse
        }

        let canDecode = (200..<300).contains(httpResponse.statusCode)
            || (allowValidationFailure && httpResponse.statusCode == 403)

        guard canDecode else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw KenshikiPulseError.httpStatus(httpResponse.statusCode, body)
        }

        do {
            return try decoder.decode(responseType, from: data)
        } catch {
            throw KenshikiPulseError.decodingFailed(error.localizedDescription)
        }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return true }
        return String(describing: error).contains("CancellationError")
            || error.localizedDescription.contains("CancellationError")
    }
}

public extension WalletIdentityResult {
    func passportWalletProof(requestID: String? = nil, signedResponse: String? = nil) -> PassportWalletProof? {
        guard case .verified(let encryptedDocument) = self else { return nil }
        return PassportWalletProof(
            encryptedDocument: encryptedDocument.base64EncodedString(),
            requestID: requestID,
            signedResponse: signedResponse
        )
    }
}

public extension NFCPassportResult {
    func passportNfcProof() throws -> PassportNfcProof? {
        guard case .verified(let chipData) = self else { return nil }
        return try PassportNfcProof(chipData: chipData)
    }
}

private extension PassportChipData {
    func firstDataGroup(namedLike needle: String) -> Data? {
        let uppercasedNeedle = needle.uppercased()
        return dataGroups.first { name, _ in
            name.uppercased().contains(uppercasedNeedle)
        }?.value
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
