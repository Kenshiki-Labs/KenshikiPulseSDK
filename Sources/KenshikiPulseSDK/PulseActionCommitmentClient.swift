import CryptoKit
import Foundation

public enum PulseActionEnvironment: String, Codable, Equatable, Sendable {
    case development
    case staging
    case production
}

public enum PulseActionValueTier: String, Codable, Equatable, Sendable {
    case low
    case standard
    case high
    case critical
}

public struct PulseMaterialActionPayload: Codable, Equatable, Sendable {
    public let tenantID: String
    public let environment: PulseActionEnvironment
    public let workflow: String
    public let action: String
    public let materialActionID: String
    public let sessionID: String
    public let subjectID: String
    public let deviceID: String
    public let valueTier: PulseActionValueTier
    public let materialFields: [String: String]
    public let createdAt: String
    public let expiresAt: String

    public init(
        tenantID: String,
        environment: PulseActionEnvironment,
        workflow: String,
        action: String,
        materialActionID: String,
        sessionID: String,
        subjectID: String,
        deviceID: String,
        valueTier: PulseActionValueTier,
        materialFields: [String: String],
        createdAt: String,
        expiresAt: String
    ) {
        self.tenantID = tenantID
        self.environment = environment
        self.workflow = workflow
        self.action = action
        self.materialActionID = materialActionID
        self.sessionID = sessionID
        self.subjectID = subjectID
        self.deviceID = deviceID
        self.valueTier = valueTier
        self.materialFields = materialFields
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }

    enum CodingKeys: String, CodingKey {
        case tenantID = "tenant_id"
        case environment
        case workflow
        case action
        case materialActionID = "material_action_id"
        case sessionID = "session_id"
        case subjectID = "subject_id"
        case deviceID = "device_id"
        case valueTier = "value_tier"
        case materialFields = "material_fields"
        case createdAt = "created_at"
        case expiresAt = "expires_at"
    }

    public func canonicalJSONData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public func canonicalJSONString() throws -> String {
        guard let string = String(data: try canonicalJSONData(), encoding: .utf8) else {
            throw KenshikiPulseError.encodingFailed("Material action payload is not valid UTF-8.")
        }
        return string
    }

    public func payloadHash() throws -> String {
        let digest = SHA256.hash(data: try canonicalJSONData())
        return "sha256:\(pulseActionBase64URLEncodedString(Data(digest)))"
    }
}

public struct PulseActionCommitmentChallengeRequest: Codable, Equatable, Sendable {
    public let sessionID: String
    public let tenantID: String
    public let workflow: String
    public let action: String
    public let materialActionID: String
    public let payloadHash: String
    public let valueTier: PulseActionValueTier
    public let deviceID: String
    public let subjectID: String

    public init(payload: PulseMaterialActionPayload) throws {
        self.sessionID = payload.sessionID
        self.tenantID = payload.tenantID
        self.workflow = payload.workflow
        self.action = payload.action
        self.materialActionID = payload.materialActionID
        self.payloadHash = try payload.payloadHash()
        self.valueTier = payload.valueTier
        self.deviceID = payload.deviceID
        self.subjectID = payload.subjectID
    }

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case tenantID = "tenant_id"
        case workflow
        case action
        case materialActionID = "material_action_id"
        case payloadHash = "payload_hash"
        case valueTier = "value_tier"
        case deviceID = "device_id"
        case subjectID = "subject_id"
    }
}

public struct PulseActionCommitmentChallengeResponse: Codable, Equatable, Sendable {
    public let challengeID: String
    public let nonce: String
    public let sessionID: String
    public let materialActionID: String
    public let payloadHash: String
    public let workflow: String
    public let action: String
    public let tenantID: String
    public let valueTier: PulseActionValueTier
    public let expiresAt: String
    public let signingProfile: String
    public let displayIntent: [String: String]

    public init(
        challengeID: String,
        nonce: String,
        sessionID: String,
        materialActionID: String,
        payloadHash: String,
        workflow: String,
        action: String,
        tenantID: String,
        valueTier: PulseActionValueTier,
        expiresAt: String,
        signingProfile: String,
        displayIntent: [String: String]
    ) {
        self.challengeID = challengeID
        self.nonce = nonce
        self.sessionID = sessionID
        self.materialActionID = materialActionID
        self.payloadHash = payloadHash
        self.workflow = workflow
        self.action = action
        self.tenantID = tenantID
        self.valueTier = valueTier
        self.expiresAt = expiresAt
        self.signingProfile = signingProfile
        self.displayIntent = displayIntent
    }

    enum CodingKeys: String, CodingKey {
        case challengeID = "challenge_id"
        case nonce
        case sessionID = "session_id"
        case materialActionID = "material_action_id"
        case payloadHash = "payload_hash"
        case workflow
        case action
        case tenantID = "tenant_id"
        case valueTier = "value_tier"
        case expiresAt = "expires_at"
        case signingProfile = "signing_profile"
        case displayIntent = "display_intent"
    }
}

public struct PulseActionCommitment: Codable, Equatable, Sendable {
    public let challengeID: String
    public let nonce: String
    public let sessionID: String
    public let materialActionID: String
    public let tenantID: String
    public let valueTier: PulseActionValueTier
    public let workflow: String
    public let action: String
    public let payloadHash: String
    public let issuedAt: String
    public let localAuth: PulseActionCommitmentLocalAuth?
    public let appAttest: PulseAppAttestAssertion?

    public init(
        challenge: PulseActionCommitmentChallengeResponse,
        issuedAt: String,
        localAuth: PulseActionCommitmentLocalAuth? = nil,
        appAttest: PulseAppAttestAssertion? = nil
    ) {
        self.init(
            signingInput: PulseActionCommitmentSigningInput(challenge: challenge, issuedAt: issuedAt, localAuth: localAuth),
            appAttest: appAttest
        )
    }

    public init(signingInput: PulseActionCommitmentSigningInput, appAttest: PulseAppAttestAssertion? = nil) {
        self.challengeID = signingInput.challengeID
        self.nonce = signingInput.nonce
        self.sessionID = signingInput.sessionID
        self.materialActionID = signingInput.materialActionID
        self.tenantID = signingInput.tenantID
        self.valueTier = signingInput.valueTier
        self.workflow = signingInput.workflow
        self.action = signingInput.action
        self.payloadHash = signingInput.payloadHash
        self.issuedAt = signingInput.issuedAt
        self.localAuth = signingInput.localAuth
        self.appAttest = appAttest
    }

    enum CodingKeys: String, CodingKey {
        case challengeID = "challenge_id"
        case nonce
        case sessionID = "session_id"
        case materialActionID = "material_action_id"
        case tenantID = "tenant_id"
        case valueTier = "value_tier"
        case workflow
        case action
        case payloadHash = "payload_hash"
        case issuedAt = "issued_at"
        case localAuth = "local_auth"
        case appAttest = "app_attest"
    }
}

public struct PulseActionCommitmentLocalAuth: Codable, Equatable, Sendable {
    public let method: String
    public let result: String
    public let verifiedAt: String

    public init(method: String, result: String = "verified", verifiedAt: String) {
        self.method = method
        self.result = result
        self.verifiedAt = verifiedAt
    }

    enum CodingKeys: String, CodingKey {
        case method
        case result
        case verifiedAt = "verified_at"
    }
}

public struct PulseActionCommitmentDisplayIntent: Equatable, Sendable {
    public let title: String
    public let summary: String?
    public let fields: [String: String]

    public init(title: String, summary: String? = nil, fields: [String: String]) {
        self.title = title
        self.summary = summary
        self.fields = fields
    }

    public init(challenge: PulseActionCommitmentChallengeResponse) {
        self.title = challenge.displayIntent["title"] ?? challenge.action
        self.summary = challenge.displayIntent["summary"]
        self.fields = challenge.displayIntent.filter { key, _ in key != "title" && key != "summary" }
    }
}

public struct PulseActionCommitmentSigningInput: Codable, Equatable, Sendable {
    public static let domainSeparator = "pulse:action-commitment:v1"

    public let challengeID: String
    public let nonce: String
    public let sessionID: String
    public let tenantID: String
    public let valueTier: PulseActionValueTier
    public let workflow: String
    public let action: String
    public let materialActionID: String
    public let payloadHash: String
    public let issuedAt: String
    public let localAuth: PulseActionCommitmentLocalAuth?

    public init(
        challengeID: String,
        nonce: String,
        sessionID: String,
        tenantID: String,
        valueTier: PulseActionValueTier,
        workflow: String,
        action: String,
        materialActionID: String,
        payloadHash: String,
        issuedAt: String,
        localAuth: PulseActionCommitmentLocalAuth? = nil
    ) {
        self.challengeID = challengeID
        self.nonce = nonce
        self.sessionID = sessionID
        self.tenantID = tenantID
        self.valueTier = valueTier
        self.workflow = workflow
        self.action = action
        self.materialActionID = materialActionID
        self.payloadHash = payloadHash
        self.issuedAt = issuedAt
        self.localAuth = localAuth
    }

    public init(
        challenge: PulseActionCommitmentChallengeResponse,
        issuedAt: String,
        localAuth: PulseActionCommitmentLocalAuth? = nil
    ) {
        self.init(
            challengeID: challenge.challengeID,
            nonce: challenge.nonce,
            sessionID: challenge.sessionID,
            tenantID: challenge.tenantID,
            valueTier: challenge.valueTier,
            workflow: challenge.workflow,
            action: challenge.action,
            materialActionID: challenge.materialActionID,
            payloadHash: challenge.payloadHash,
            issuedAt: issuedAt,
            localAuth: localAuth
        )
    }

    enum CodingKeys: String, CodingKey {
        case challengeID = "challenge_id"
        case nonce
        case sessionID = "session_id"
        case tenantID = "tenant_id"
        case valueTier = "value_tier"
        case workflow
        case action
        case materialActionID = "material_action_id"
        case payloadHash = "payload_hash"
        case issuedAt = "issued_at"
        case localAuth = "local_auth"
    }

    public func canonicalJSONData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public func canonicalJSONString() throws -> String {
        guard let string = String(data: try canonicalJSONData(), encoding: .utf8) else {
            throw KenshikiPulseError.encodingFailed("Action commitment signing input is not valid UTF-8.")
        }
        return string
    }

    public func clientDataHashData() throws -> Data {
        var data = Data(Self.domainSeparator.utf8)
        data.append(0)
        data.append(try canonicalJSONData())
        return Data(SHA256.hash(data: data))
    }

    public func clientDataHash() throws -> String {
        pulseActionBase64URLEncodedString(try clientDataHashData())
    }
}

public protocol PulseActionCommitmentSigner: Sendable {
    func signActionCommitment(_ input: PulseActionCommitmentSigningInput) async throws -> PulseAppAttestAssertion
}


#if os(iOS) && canImport(DeviceCheck)
import DeviceCheck

@available(iOS 14.0, *)
public struct PulseAppAttestActionCommitmentSigner: PulseActionCommitmentSigner {
    public let keyID: String

    public init(keyID: String) {
        self.keyID = keyID
    }

    public func signActionCommitment(_ input: PulseActionCommitmentSigningInput) async throws -> PulseAppAttestAssertion {
        let service = DCAppAttestService.shared
        guard service.isSupported else {
            throw KenshikiPulseError.invalidConfiguration("App Attest is not supported on this device.")
        }
        let clientDataHash = try input.clientDataHashData()
        let assertion = try await service.generateActionCommitmentAssertionAsync(keyID, clientDataHash: clientDataHash)
        return PulseAppAttestAssertion(
            keyID: keyID,
            clientDataHash: pulseActionBase64URLEncodedString(clientDataHash),
            assertionObject: pulseActionBase64URLEncodedString(assertion)
        )
    }
}

@available(iOS 14.0, *)
private extension DCAppAttestService {
    func generateActionCommitmentAssertionAsync(_ keyIdentifier: String, clientDataHash: Data) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            generateAssertion(keyIdentifier, clientDataHash: clientDataHash) { assertion, error in
                if let assertion {
                    continuation.resume(returning: assertion)
                } else {
                    continuation.resume(throwing: error ?? KenshikiPulseError.networkFailed("App Attest assertion failed."))
                }
            }
        }
    }
}
#endif

public struct PulseActionCommitmentAuthorizationRequest: Codable, Equatable, Sendable {
    public let payload: PulseMaterialActionPayload
    public let commitment: PulseActionCommitment

    public init(payload: PulseMaterialActionPayload, commitment: PulseActionCommitment) {
        self.payload = payload
        self.commitment = commitment
    }
}

public struct PulseActionCommitmentAuthorizationResponse: Codable, Equatable, Sendable {
    public let materialActionID: String
    public let status: String
    public let payloadHash: String
    public let auditArtifactID: String?

    public init(materialActionID: String, status: String, payloadHash: String, auditArtifactID: String? = nil) {
        self.materialActionID = materialActionID
        self.status = status
        self.payloadHash = payloadHash
        self.auditArtifactID = auditArtifactID
    }

    enum CodingKeys: String, CodingKey {
        case materialActionID = "material_action_id"
        case status
        case payloadHash = "payload_hash"
        case auditArtifactID = "audit_artifact_id"
    }
}

public protocol PulseActionCommitmentTransport: Sendable {
    func requestChallenge(
        _ request: PulseActionCommitmentChallengeRequest,
        configuration: PulsePassportIdentityConfiguration
    ) async throws -> PulseActionCommitmentChallengeResponse

    func authorize(
        _ request: PulseActionCommitmentAuthorizationRequest,
        configuration: PulsePassportIdentityConfiguration
    ) async throws -> PulseActionCommitmentAuthorizationResponse
}

public struct PulseActionCommitmentClient: Sendable {
    private let configuration: PulsePassportIdentityConfiguration
    private let transport: PulseActionCommitmentTransport

    public init(
        configuration: PulsePassportIdentityConfiguration,
        transport: PulseActionCommitmentTransport = URLSessionPulseActionCommitmentTransport()
    ) {
        self.configuration = configuration
        self.transport = transport
    }

    public func requestChallenge(for payload: PulseMaterialActionPayload) async throws -> PulseActionCommitmentChallengeResponse {
        try await transport.requestChallenge(PulseActionCommitmentChallengeRequest(payload: payload), configuration: configuration)
    }

    public func buildCommitment(
        challenge: PulseActionCommitmentChallengeResponse,
        issuedAt: String,
        localAuth: PulseActionCommitmentLocalAuth? = nil,
        signer: PulseActionCommitmentSigner
    ) async throws -> PulseActionCommitment {
        let signingInput = PulseActionCommitmentSigningInput(challenge: challenge, issuedAt: issuedAt, localAuth: localAuth)
        let appAttest = try await signer.signActionCommitment(signingInput)
        return PulseActionCommitment(signingInput: signingInput, appAttest: appAttest)
    }

    public func authorize(
        payload: PulseMaterialActionPayload,
        commitment: PulseActionCommitment
    ) async throws -> PulseActionCommitmentAuthorizationResponse {
        try await transport.authorize(
            PulseActionCommitmentAuthorizationRequest(payload: payload, commitment: commitment),
            configuration: configuration
        )
    }
}

public struct URLSessionPulseActionCommitmentTransport: PulseActionCommitmentTransport {
    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(session: URLSession = .shared) {
        self.session = session
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.sortedKeys]
        self.decoder = JSONDecoder()
    }

    public func requestChallenge(
        _ body: PulseActionCommitmentChallengeRequest,
        configuration: PulsePassportIdentityConfiguration
    ) async throws -> PulseActionCommitmentChallengeResponse {
        let request = try makeRequest(configuration: configuration, pathComponents: ["action-commitments", "challenges"], body: body)
        return try await send(request, decoding: PulseActionCommitmentChallengeResponse.self)
    }

    public func authorize(
        _ body: PulseActionCommitmentAuthorizationRequest,
        configuration: PulsePassportIdentityConfiguration
    ) async throws -> PulseActionCommitmentAuthorizationResponse {
        let request = try makeRequest(configuration: configuration, pathComponents: ["action-commitments", "authorize"], body: body)
        return try await send(request, decoding: PulseActionCommitmentAuthorizationResponse.self)
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

    private func send<Response: Decodable>(_ request: URLRequest, decoding responseType: Response.Type) async throws -> Response {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw KenshikiPulseError.networkFailed(error.localizedDescription)
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw KenshikiPulseError.invalidHTTPResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw KenshikiPulseError.httpStatus(httpResponse.statusCode, body)
        }
        do {
            return try decoder.decode(responseType, from: data)
        } catch {
            throw KenshikiPulseError.decodingFailed(error.localizedDescription)
        }
    }
}

private func pulseActionBase64URLEncodedString(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}
