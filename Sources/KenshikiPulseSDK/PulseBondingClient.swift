import Foundation

public struct PulseBondRequest: Equatable, Sendable {
    public let sessionID: String
    public let nonce: String
    /// Where the user came from on the web, when the bond URL/QR carries it (`return_url`). Used only to
    /// **label** the origin and offer a "Return to …" affordance — never auto-followed without the
    /// server confirming it matches the session's allowed origin (a raw URL from a QR is an open-redirect
    /// / phishing vector). Always `https`; non-http(s) schemes are rejected at parse time.
    public let returnURL: URL?
    /// Worker/API base that minted this QR session, when the server includes it. The app uses this to keep
    /// passport nonce, passport verification, action commitments, and final attestation on the same Durable
    /// Object namespace. Only trusted Pulse origins are accepted from QR content.
    public let apiBaseURL: URL?
    public let actionCommitmentPayload: PulseMaterialActionPayload?

    public init(
        sessionID: String,
        nonce: String,
        returnURL: URL? = nil,
        apiBaseURL: URL? = nil,
        actionCommitmentPayload: PulseMaterialActionPayload? = nil
    ) {
        self.sessionID = sessionID
        self.nonce = nonce
        self.returnURL = returnURL
        self.apiBaseURL = apiBaseURL.flatMap(Self.normalizedTrustedAPIBaseURL)
        self.actionCommitmentPayload = actionCommitmentPayload
    }

    private static let allowedUniversalLinkHosts: Set<String> = [
        // Bond links are served by the Worker. The QR can use this HTTPS /bond bounce for native
        // camera compatibility, and the page immediately redirects into pulse:// with the same payload.
        "kenshiki-pulse-worker-production.pulsekenshikilabscom.workers.dev",
        "kenshiki-pulse-worker.pulsekenshikilabscom.workers.dev",
        "pulse.kenshikilabs.com",
    ]

    public init?(url: URL) {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let isCustomScheme = url.scheme == "pulse" && url.host == "bond"
        let isUniversalLink = url.scheme == "https" && url.path == "/bond" && Self.allowedUniversalLinkHosts.contains(url.host ?? "")

        guard isCustomScheme || isUniversalLink,
            let sessionID = components?.queryItems?.first(where: { $0.name == "session_id" })?.value,
            let nonce = components?.queryItems?.first(where: { $0.name == "nonce" })?.value,
            !sessionID.isEmpty,
            !nonce.isEmpty
        else {
            return nil
        }

        self.sessionID = sessionID
        self.nonce = nonce
        do {
            self.returnURL = Self.parseReturnURL(components?.queryItems)
            self.apiBaseURL = try Self.parseAPIBaseURL(components?.queryItems)
            self.actionCommitmentPayload = try Self.parseActionCommitmentPayload(components?.queryItems)
        } catch {
            return nil
        }
    }


    /// Optional generic Action Commitment payload. The value is base64url-encoded canonical JSON using
    /// `PulseMaterialActionPayload`'s wire keys. If present but malformed, the bond request is rejected:
    /// approving a hidden or unparsable material action would be worse than failing closed.
    private static func parseActionCommitmentPayload(_ items: [URLQueryItem]?) throws -> PulseMaterialActionPayload? {
        guard let raw = items?.first(where: { $0.name == "action_commitment" })?.value,
              !raw.isEmpty
        else { return nil }
        guard let data = Data(base64URLEncoded: raw) else {
            throw KenshikiPulseError.encodingFailed("Invalid action commitment payload encoding.")
        }
        return try JSONDecoder().decode(PulseMaterialActionPayload.self, from: data)
    }

    /// Accept `return_url` only when it's a well-formed absolute `https` URL. Anything else (missing,
    /// relative, `http`, `javascript:`, `pulse://`, garbage) collapses to `nil` — the app shows no origin
    /// rather than trusting an unsafe one. Final authority is still the server matching it to the session.
    private static func parseReturnURL(_ items: [URLQueryItem]?) -> URL? {
        guard let raw = items?.first(where: { $0.name == "return_url" })?.value,
              !raw.isEmpty,
              let url = URL(string: raw),
              url.scheme?.lowercased() == "https",
              url.host?.isEmpty == false
        else { return nil }
        return url
    }

    private static func parseAPIBaseURL(_ items: [URLQueryItem]?) throws -> URL? {
        guard let raw = items?.first(where: { $0.name == "api_base_url" })?.value,
              !raw.isEmpty
        else { return nil }
        guard let url = URL(string: raw),
              let normalized = normalizedTrustedAPIBaseURL(url)
        else {
            throw KenshikiPulseError.encodingFailed("Invalid Pulse API base URL.")
        }
        return normalized
    }

    private static func normalizedTrustedAPIBaseURL(_ url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              !host.isEmpty
        else { return nil }

        #if DEBUG
        let localhostHosts: Set<String> = ["localhost", "127.0.0.1", "::1"]
        let isDevelopmentTunnel = host.hasSuffix(".trycloudflare.com")
        let isLocalhost = localhostHosts.contains(host)
        let allowedScheme = scheme == "https" || (scheme == "http" && isLocalhost)
        #else
        let isDevelopmentTunnel = false
        let isLocalhost = false
        let allowedScheme = scheme == "https"
        #endif

        guard allowedScheme,
              allowedAPIHosts.contains(host) || isDevelopmentTunnel || isLocalhost
        else { return nil }

        components.scheme = scheme
        components.host = host
        components.query = nil
        components.fragment = nil
        return components.url
    }

    private static let allowedAPIHosts: Set<String> = [
        "kenshiki-pulse-worker-production.pulsekenshikilabscom.workers.dev",
        "kenshiki-pulse-worker.pulsekenshikilabscom.workers.dev",
        "pulse.kenshikilabs.com",
    ]
}

private extension Data {
    init?(base64URLEncoded value: String) {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 { base64.append(String(repeating: "=", count: 4 - remainder)) }
        self.init(base64Encoded: base64)
    }
}

public struct PulseBondingConfiguration: Equatable, Sendable {
    public static let kenshikiProduction = PulseBondingConfiguration(
        attestationEndpoint: URL(string: "https://kenshiki-pulse-worker-production.pulsekenshikilabscom.workers.dev/attestations")!,
        channelWebSocketBaseURL: URL(string: "wss://kenshiki-pulse-worker-production.pulsekenshikilabscom.workers.dev")!
    )

    public let attestationEndpoint: URL
    public let channelWebSocketBaseURL: URL?
    public let apiKey: String?
    public let additionalHeaders: [String: String]

    public init(
        attestationEndpoint: URL,
        channelWebSocketBaseURL: URL? = nil,
        apiKey: String? = nil,
        additionalHeaders: [String: String] = [:]
    ) {
        self.attestationEndpoint = attestationEndpoint
        self.channelWebSocketBaseURL = channelWebSocketBaseURL
        self.apiKey = apiKey
        self.additionalHeaders = additionalHeaders
    }

    public init(
        workerBaseURL: URL,
        apiKey: String? = nil,
        additionalHeaders: [String: String] = [:]
    ) {
        self.init(
            attestationEndpoint: workerBaseURL.appendingPathComponent("attestations"),
            channelWebSocketBaseURL: Self.webSocketBaseURL(from: workerBaseURL),
            apiKey: apiKey,
            additionalHeaders: additionalHeaders
        )
    }

    private static func webSocketBaseURL(from workerBaseURL: URL) -> URL? {
        guard var components = URLComponents(url: workerBaseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        switch components.scheme?.lowercased() {
        case "https":
            components.scheme = "wss"
        case "http":
            components.scheme = "ws"
        case "wss", "ws":
            break
        default:
            return nil
        }
        components.query = nil
        components.fragment = nil
        return components.url
    }
}

public struct PulseAppAttestAssertion: Codable, Equatable, Sendable {
    public let keyID: String
    public let clientDataHash: String
    public let authenticatorData: String?
    public let signature: String?
    public let assertionObject: String?

    public init(keyID: String, clientDataHash: String, authenticatorData: String, signature: String) {
        self.keyID = keyID
        self.clientDataHash = clientDataHash
        self.authenticatorData = authenticatorData
        self.signature = signature
        self.assertionObject = nil
    }

    public init(keyID: String, clientDataHash: String, assertionObject: String) {
        self.keyID = keyID
        self.clientDataHash = clientDataHash
        self.authenticatorData = nil
        self.signature = nil
        self.assertionObject = assertionObject
    }

    enum CodingKeys: String, CodingKey {
        case keyID = "key_id"
        case clientDataHash = "client_data_hash"
        case authenticatorData = "authenticator_data"
        case signature
        case assertionObject = "assertion_object"
    }
}

public struct VerifiedPulseEvidence: Codable, Equatable, Sendable {
    public let issuedAt: Date
    public let expiresAt: Date
    public let localAuth: PulseLocalAuthAttestation
    public let carrier: PulseCarrierAttestation
    public let sensorContinuity: PulseSensorContinuityAttestation
    public let signature: String

    public init(
        issuedAt: Date,
        expiresAt: Date,
        localAuth: PulseLocalAuthAttestation,
        carrier: PulseCarrierAttestation,
        sensorContinuity: PulseSensorContinuityAttestation,
        signature: String
    ) {
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.localAuth = localAuth
        self.carrier = carrier
        self.sensorContinuity = sensorContinuity
        self.signature = signature
    }

    enum CodingKeys: String, CodingKey {
        case issuedAt = "issued_at"
        case expiresAt = "expires_at"
        case localAuth = "local_auth"
        case carrier
        case sensorContinuity = "sensor_continuity"
        case signature
    }
}

public struct BondedPairAssertion: Codable, Equatable, Sendable {
    public let sessionID: String
    public let nonce: String
    public let deviceID: String
    public let subjectID: String
    public let issuedAt: Date
    public let appAttest: PulseAppAttestAssertion?
    public let verifiedEvidence: VerifiedPulseEvidence?
    public let attestations: PulseAssertionAttestations?
    public let signature: String?

    public init(
        sessionID: String,
        nonce: String,
        deviceID: String,
        subjectID: String,
        issuedAt: Date,
        appAttest: PulseAppAttestAssertion,
        verifiedEvidence: VerifiedPulseEvidence
    ) {
        self.sessionID = sessionID
        self.nonce = nonce
        self.deviceID = deviceID
        self.subjectID = subjectID
        self.issuedAt = issuedAt
        self.appAttest = appAttest
        self.verifiedEvidence = verifiedEvidence
        self.attestations = nil
        self.signature = nil
    }

    public init(
        sessionID: String,
        nonce: String,
        deviceID: String,
        subjectID: String,
        issuedAt: Date,
        attestations: PulseAssertionAttestations,
        signature: String
    ) {
        self.sessionID = sessionID
        self.nonce = nonce
        self.deviceID = deviceID
        self.subjectID = subjectID
        self.issuedAt = issuedAt
        self.appAttest = nil
        self.verifiedEvidence = nil
        self.attestations = attestations
        self.signature = signature
    }

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case nonce
        case deviceID = "device_id"
        case subjectID = "subject_id"
        case issuedAt = "issued_at"
        case appAttest = "app_attest"
        case verifiedEvidence = "verified_evidence"
        case attestations
        case signature
    }
}

public struct PulseAssertionAttestations: Codable, Equatable, Sendable {
    public let localAuth: PulseLocalAuthAttestation
    public let appIntegrity: PulseProviderResult
    public let carrier: PulseCarrierAttestation
    public let sensorContinuity: PulseSensorContinuityAttestation
    /// Present when the user attempted or skipped Wallet identity verification.
    /// Nil on builds where the feature flag is off or the OS is below iOS 16.
    public let walletIdentity: PulseWalletIdentityAttestation?
    /// Present when the user attempted NFC passport chip reading.
    /// Nil when the feature flag is off or the device doesn't support NFC.
    public let nfcPassport: PulseNFCPassportAttestation?

    public init(
        localAuth: PulseLocalAuthAttestation,
        appIntegrity: PulseProviderResult,
        carrier: PulseCarrierAttestation,
        sensorContinuity: PulseSensorContinuityAttestation,
        walletIdentity: PulseWalletIdentityAttestation? = nil,
        nfcPassport: PulseNFCPassportAttestation? = nil
    ) {
        self.localAuth = localAuth
        self.appIntegrity = appIntegrity
        self.carrier = carrier
        self.sensorContinuity = sensorContinuity
        self.walletIdentity = walletIdentity
        self.nfcPassport = nfcPassport
    }

    enum CodingKeys: String, CodingKey {
        case localAuth = "local_auth"
        case appIntegrity = "app_integrity"
        case carrier
        case sensorContinuity = "sensor_continuity"
        case walletIdentity = "wallet_identity"
        case nfcPassport = "nfc_passport"
    }
}

public struct PulseNFCPassportAttestation: Codable, Equatable, Sendable {
    public let provider: String
    /// "verified" | "declined" | "unsupported" | "failed"
    public let result: String
    /// Strongest protocol: "none" | "basic_access_control" | "pace" | "active_authentication" | "chip_authentication"
    public let authLevel: String
    /// True if Active Authentication or Chip Authentication succeeded.
    public let chipAuthenticated: Bool
    /// True if the SOD signature validated to a trusted CSCA root.
    public let cscaVerified: Bool
    /// True if today's date is past the document expiry date. Nil when result is not "verified".
    public let documentExpired: Bool?
    /// ISO 3166-1 alpha-3 nationality code from DG1. Only present when result == "verified".
    public let nationality: String?
    /// ISO 3166-1 alpha-3 issuing state code from DG1. Only present when result == "verified".
    public let issuingState: String?
    /// Family name in ICAO MRZ encoding. Only present when result == "verified".
    public let surname: String?
    /// Given names in ICAO MRZ encoding. Only present when result == "verified".
    public let givenNames: String?
    /// Date of birth in YYMMDD format. Only present when result == "verified".
    public let dateOfBirth: String?
    /// Document number from MRZ. Only present when result == "verified".
    public let documentNumber: String?
    /// Base64-encoded DER-encoded Document Signing Certificate extracted from the SOD.
    /// Only present when result == "verified" and the library exposed the certificate bytes.
    /// The server should validate this against the ICAO PKD Master List to confirm the DSC
    /// was issued by a legitimate CSCA — completing Passive Authentication's trust chain.
    /// Nil does not mean the document is untrusted; it means server-side chain validation
    /// cannot be performed for this read and cscaVerified reflects DSC-level proof only.
    public let documentSigningCertificate: String?
    /// Human-readable failure description. Only present when result == "failed".
    public let failureReason: String?

    public init(
        provider: String,
        result: String,
        authLevel: String,
        chipAuthenticated: Bool,
        cscaVerified: Bool,
        documentExpired: Bool?,
        nationality: String?,
        issuingState: String?,
        surname: String?,
        givenNames: String?,
        dateOfBirth: String?,
        documentNumber: String?,
        documentSigningCertificate: String? = nil,
        failureReason: String?
    ) {
        self.provider = provider
        self.result = result
        self.authLevel = authLevel
        self.chipAuthenticated = chipAuthenticated
        self.cscaVerified = cscaVerified
        self.documentExpired = documentExpired
        self.nationality = nationality
        self.issuingState = issuingState
        self.surname = surname
        self.givenNames = givenNames
        self.dateOfBirth = dateOfBirth
        self.documentNumber = documentNumber
        self.documentSigningCertificate = documentSigningCertificate
        self.failureReason = failureReason
    }

    enum CodingKeys: String, CodingKey {
        case provider
        case result
        case authLevel = "auth_level"
        case chipAuthenticated = "chip_authenticated"
        case cscaVerified = "csca_verified"
        case documentExpired = "document_expired"
        case nationality
        case issuingState = "issuing_state"
        case surname
        case givenNames = "given_names"
        case dateOfBirth = "date_of_birth"
        case documentNumber = "document_number"
        case documentSigningCertificate = "document_signing_certificate"
        case failureReason = "failure_reason"
    }
}

public struct PulseWalletIdentityAttestation: Codable, Equatable, Sendable {
    public let provider: String
    /// "verified" | "declined" | "unsupported" | "unavailable"
    public let result: String
    /// Base64-encoded encrypted document payload from Apple Wallet.
    /// Only present when result == "verified". Must be decrypted server-side
    /// using the Identity Access Certificate — never readable on the client.
    public let encryptedDocument: String?

    public init(provider: String, result: String, encryptedDocument: String?) {
        self.provider = provider
        self.result = result
        self.encryptedDocument = encryptedDocument
    }

    enum CodingKeys: String, CodingKey {
        case provider
        case result
        case encryptedDocument = "encrypted_document"
    }
}

public struct PulseLocalAuthAttestation: Codable, Equatable, Sendable {
    public let method: String
    public let result: String

    public init(method: String, result: String) {
        self.method = method
        self.result = result
    }
}

public struct PulseProviderResult: Codable, Equatable, Sendable {
    public let provider: String
    public let result: String

    public init(provider: String, result: String) {
        self.provider = provider
        self.result = result
    }
}

public struct PulseCarrierAttestation: Codable, Equatable, Sendable {
    public let provider: String
    public let numberVerified: Bool
    public let simSwapRecent: Bool
    public let deviceStatus: String

    public init(provider: String, numberVerified: Bool, simSwapRecent: Bool, deviceStatus: String) {
        self.provider = provider
        self.numberVerified = numberVerified
        self.simSwapRecent = simSwapRecent
        self.deviceStatus = deviceStatus
    }

    enum CodingKeys: String, CodingKey {
        case provider
        case numberVerified = "number_verified"
        case simSwapRecent = "sim_swap_recent"
        case deviceStatus = "device_status"
    }
}

public struct PulseSensorContinuityAttestation: Codable, Equatable, Sendable {
    public let observationSeconds: Int
    public let motionPresent: Bool
    public let continuityScore: Double

    public init(observationSeconds: Int, motionPresent: Bool, continuityScore: Double) {
        self.observationSeconds = observationSeconds
        self.motionPresent = motionPresent
        self.continuityScore = continuityScore
    }

    enum CodingKeys: String, CodingKey {
        case observationSeconds = "observation_seconds"
        case motionPresent = "motion_present"
        case continuityScore = "continuity_score"
    }
}

public struct PulseBondedSessionResponse: Codable, Equatable, Sendable {
    public let id: String
    public let state: String
    public let deviceID: String?
    public let subjectID: String?
    public let webSocketURL: URL?

    enum CodingKeys: String, CodingKey {
        case id
        case state
        case deviceID = "device_id"
        case subjectID = "subject_id"
        case webSocketURL = "websocket_url"
    }
}

public struct PulseHeartbeat: Codable, Equatable, Sendable {
    public let sessionID: String
    public let deviceID: String
    public let sequence: Int
    public let issuedAt: Date
    public let continuityHash: String
    public let signature: String

    public init(
        sessionID: String,
        deviceID: String,
        sequence: Int,
        issuedAt: Date,
        continuityHash: String,
        signature: String
    ) {
        self.sessionID = sessionID
        self.deviceID = deviceID
        self.sequence = sequence
        self.issuedAt = issuedAt
        self.continuityHash = continuityHash
        self.signature = signature
    }

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case deviceID = "device_id"
        case sequence = "seq"
        case issuedAt = "issued_at"
        case continuityHash = "continuity_hash"
        case signature
    }
}

public protocol PulseAttestationTransport: Sendable {
    func submit(
        assertion: BondedPairAssertion,
        configuration: PulseBondingConfiguration
    ) async throws -> PulseBondedSessionResponse
}

public struct PulseBondingClient: Sendable {
    private let configuration: PulseBondingConfiguration
    private let transport: PulseAttestationTransport

    public init(
        configuration: PulseBondingConfiguration,
        transport: PulseAttestationTransport = URLSessionPulseAttestationTransport()
    ) {
        self.configuration = configuration
        self.transport = transport
    }

    public func submit(assertion: BondedPairAssertion) async throws -> PulseBondedSessionResponse {
        try await transport.submit(assertion: assertion, configuration: configuration)
    }

    public func webSocketURL(for sessionID: String) -> URL? {
        guard let base = configuration.channelWebSocketBaseURL else { return nil }
        var components = URLComponents(
            url:
                base
                .appendingPathComponent("sessions")
                .appendingPathComponent(sessionID), resolvingAgainstBaseURL: false)

        components?.queryItems = [URLQueryItem(name: "role", value: "mobile")]
        return components?.url
    }
}

public struct URLSessionPulseAttestationTransport: PulseAttestationTransport {
    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(session: URLSession = .shared) {
        self.session = session
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(formatter.string(from: date))
        }

        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let dateString = try container.decode(String.self)

            // Try with fractional seconds first
            if let date = formatter.date(from: dateString) { return date }

            // Fallback without fractional seconds
            let fallbackFormatter = ISO8601DateFormatter()
            if let date = fallbackFormatter.date(from: dateString) { return date }

            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date format: \(dateString)")
        }
    }

    public func submit(
        assertion: BondedPairAssertion,
        configuration: PulseBondingConfiguration
    ) async throws -> PulseBondedSessionResponse {
        var request = URLRequest(url: configuration.attestationEndpoint)
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
            request.httpBody = try encoder.encode(assertion)
        } catch {
            throw KenshikiPulseError.encodingFailed(error.localizedDescription)
        }

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

        guard (200..<300).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw KenshikiPulseError.httpStatus(httpResponse.statusCode, body)
        }

        do {
            return try decoder.decode(PulseBondedSessionResponse.self, from: data)
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
