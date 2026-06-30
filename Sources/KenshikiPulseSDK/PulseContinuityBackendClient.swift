// swiftlint:disable file_length
import Foundation
import CryptoKit
import Security
#if os(iOS) && canImport(DeviceCheck)
import DeviceCheck
#endif

public enum PulseContinuityBackendMode: String, Codable, Sendable {
    case devSimulator
    case appAttest
}

public struct PulseContinuityBackendConfiguration: Equatable, Sendable {
    public static let kenshikiProduction = PulseContinuityBackendConfiguration(
        baseURL: URL(string: "https://kenshikilabs.com")!,
        mode: .appAttest,
        appAttestEnvironment: "production"
    )

    public let baseURL: URL
    public let mode: PulseContinuityBackendMode
    public let additionalHeaders: [String: String]
    public let appAttestEnvironment: String?

    public init(
        baseURL: URL,
        mode: PulseContinuityBackendMode,
        additionalHeaders: [String: String] = [:],
        appAttestEnvironment: String? = nil
    ) {
        self.baseURL = baseURL
        self.mode = mode
        self.additionalHeaders = additionalHeaders
        self.appAttestEnvironment = appAttestEnvironment
    }
}

public struct PulseContinuityCredentials: Codable, Equatable, Sendable {
    public let installationID: String
    public let clientInstallationID: String
    public let appAttestKeyID: String?
    public let token: String
    public let expiresAt: Date?
    public let backendBaseURL: URL?
    public let mode: PulseContinuityBackendMode?
    public let appAttestEnvironment: String?

    public init(
        installationID: String,
        clientInstallationID: String,
        appAttestKeyID: String? = nil,
        token: String,
        expiresAt: Date?,
        backendBaseURL: URL? = nil,
        mode: PulseContinuityBackendMode? = nil,
        appAttestEnvironment: String? = nil
    ) {
        self.installationID = installationID
        self.clientInstallationID = clientInstallationID
        self.appAttestKeyID = appAttestKeyID
        self.token = token
        self.expiresAt = expiresAt
        self.backendBaseURL = backendBaseURL
        self.mode = mode
        self.appAttestEnvironment = appAttestEnvironment
    }

    private enum CodingKeys: String, CodingKey {
        case installationID
        case clientInstallationID
        case appAttestKeyID
        case token
        case expiresAt
        case backendBaseURL
        case mode
        case appAttestEnvironment
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.installationID = try container.decode(String.self, forKey: .installationID)
        self.clientInstallationID = try container.decode(String.self, forKey: .clientInstallationID)
        self.appAttestKeyID = try container.decodeIfPresent(String.self, forKey: .appAttestKeyID)
        self.token = try container.decode(String.self, forKey: .token)
        self.expiresAt = try container.decodeIfPresent(Date.self, forKey: .expiresAt)
        self.backendBaseURL = try container.decodeIfPresent(URL.self, forKey: .backendBaseURL)
        self.mode = try container.decodeIfPresent(PulseContinuityBackendMode.self, forKey: .mode)
        self.appAttestEnvironment = try container.decodeIfPresent(String.self, forKey: .appAttestEnvironment)
    }

    fileprivate func matches(configuration: PulseContinuityBackendConfiguration) -> Bool {
        guard backendBaseURL == configuration.baseURL,
              mode == configuration.mode
        else { return false }
        if configuration.mode == .appAttest, appAttestKeyID?.isEmpty != false {
            return false
        }
        let storedEnvironment = normalizedEnvironment(appAttestEnvironment)
        let currentEnvironment = normalizedEnvironment(configuration.appAttestEnvironment)
        return storedEnvironment == currentEnvironment
    }
}

public protocol PulseContinuityCredentialStore: Sendable {
    func load() async throws -> PulseContinuityCredentials?
    func save(_ credentials: PulseContinuityCredentials) async throws
    func delete() async throws
}

actor InMemoryPulseContinuityCredentialStore: PulseContinuityCredentialStore {
    private var credentials: PulseContinuityCredentials?

    public init(credentials: PulseContinuityCredentials? = nil) {
        self.credentials = credentials
    }

    public func load() async throws -> PulseContinuityCredentials? { credentials }
    public func save(_ credentials: PulseContinuityCredentials) async throws { self.credentials = credentials }
    public func delete() async throws { credentials = nil }
}

public struct KeychainPulseContinuityCredentialStore: PulseContinuityCredentialStore {
    private let service: String
    private let account: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(service: String = "com.kenshiki.pulse.continuity", account: String = "installation") {
        self.service = service
        self.account = account
    }

    public func load() async throws -> PulseContinuityCredentials? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw KenshikiPulseError.storageFailed("Keychain load failed: \(status)")
        }
        return try decoder.decode(PulseContinuityCredentials.self, from: data)
    }

    public func save(_ credentials: PulseContinuityCredentials) async throws {
        let data = try encoder.encode(credentials)
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery() as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return }
        if status != errSecItemNotFound {
            throw KenshikiPulseError.storageFailed("Keychain update failed: \(status)")
        }

        var query = baseQuery()
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KenshikiPulseError.storageFailed("Keychain add failed: \(addStatus)")
        }
    }

    public func delete() async throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KenshikiPulseError.storageFailed("Keychain delete failed: \(status)")
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

public protocol PulseContinuityHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionPulseContinuityHTTPTransport: PulseContinuityHTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw KenshikiPulseError.invalidHTTPResponse
        }
        return (data, http)
    }
}

public struct PulseContinuityPermissionSnapshot: Codable, Equatable, Sendable {
    public let motion: String
    public let location: String
    public let notifications: String
    public let focus: String
    public let bluetooth: String

    public init(
        motion: String = "notCollected",
        location: String = "notCollected",
        notifications: String = "notCollected",
        focus: String = "notCollected",
        bluetooth: String = "notCollected"
    ) {
        self.motion = motion
        self.location = location
        self.notifications = notifications
        self.focus = focus
        self.bluetooth = bluetooth
    }
}

public struct PulseContinuityAppMetadata: Codable, Equatable, Sendable {
    public let platform: String
    public let appVersion: String
    public let buildNumber: String
    public let sdkVersion: String
    public let locale: String?

    public init(appVersion: String, buildNumber: String, sdkVersion: String = KenshikiPulseConstants.sdkVersion, locale: String? = Locale.current.identifier) {
        self.platform = "ios"
        self.appVersion = appVersion
        self.buildNumber = buildNumber
        self.sdkVersion = sdkVersion
        self.locale = locale
    }
}

public struct PulseContinuityDeviceMetadata: Codable, Equatable, Sendable {
    public let deviceClass: String
    public let osMajorVersion: Int
    public let modelClass: String

    public init(osMajorVersion: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion) {
        self.deviceClass = "iPhone"
        self.osMajorVersion = osMajorVersion
        self.modelClass = "phone"
    }
}

public struct PulseContinuityUploadResponse: Codable, Equatable, Sendable {
    public let checkInId: String
    public let clientCheckInId: String
    public let acceptedAt: Date
    public let idempotency: PulseContinuityIdempotencyResponse
}

struct PulseAppAttestRegistrationFixture: Codable, Equatable, Sendable {
    public let schemaVersion: String
    public let capturedAt: Date
    public let backendBaseURL: URL
    public let appAttestEnvironment: String?
    public let clientInstallationId: String
    public let app: PulseContinuityAppMetadata
    public let device: PulseContinuityDeviceMetadata
    public let appAttest: PulseAppAttestRegistrationFixtureEvidence
}

struct PulseAppAttestRegistrationFixtureEvidence: Codable, Equatable, Sendable {
    public let keyId: String
    public let challenge: String
    public let challengeExpiresAt: Date
    public let clientDataHash: String
    public let attestationObject: String
}

public struct PulseContinuityIdempotencyResponse: Codable, Equatable, Sendable {
    public let replayed: Bool
}

public struct PulseContinuityBackendClient: Sendable {
    private static let registrationSchemaVersion = "pulse.installation-registration.v1"
    private static let challengeSchemaVersion = "pulse.app-attest-challenge.v1"
    private static let checkInSchemaVersion = "pulse.check-in.v1"

    private let configuration: PulseContinuityBackendConfiguration
    private let credentials: PulseContinuityCredentialStore
    private let transport: PulseContinuityHTTPTransport
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        configuration: PulseContinuityBackendConfiguration,
        credentials: PulseContinuityCredentialStore = KeychainPulseContinuityCredentialStore(),
        transport: PulseContinuityHTTPTransport = URLSessionPulseContinuityHTTPTransport()
    ) {
        self.configuration = configuration
        self.credentials = credentials
        self.transport = transport
        self.encoder = Self.makeEncoder()
        self.decoder = Self.makeDecoder()
    }

    public func ensureDevSimulatorRegistration(
        app: PulseContinuityAppMetadata,
        device: PulseContinuityDeviceMetadata = PulseContinuityDeviceMetadata()
    ) async throws -> PulseContinuityCredentials {
        if let stored = try await loadUsableCredentials() { return stored }
        guard configuration.mode == .devSimulator else {
            throw KenshikiPulseError.invalidConfiguration("Dev simulator registration requires devSimulator mode.")
        }

        let clientInstallationID = Self.makeULID()
        let request = PulseInstallationRegistrationRequest(
            schemaVersion: Self.registrationSchemaVersion,
            mode: configuration.mode.rawValue,
            clientInstallationId: clientInstallationID,
            app: app,
            device: device
        )
        let response: PulseInstallationRegistrationResponse = try await post(
            path: "/api/v1/pulse/installations",
            schemaVersion: Self.registrationSchemaVersion,
            idempotencyKey: nil,
            bearerToken: nil,
            body: request
        )
        let stored = PulseContinuityCredentials(
            installationID: response.installationId,
            clientInstallationID: clientInstallationID,
            token: response.token,
            expiresAt: response.expiresAt,
            backendBaseURL: configuration.baseURL,
            mode: configuration.mode,
            appAttestEnvironment: configuration.appAttestEnvironment
        )
        try await credentials.save(stored)
        return stored
    }

    public func ensureRegistration(
        app: PulseContinuityAppMetadata,
        device: PulseContinuityDeviceMetadata = PulseContinuityDeviceMetadata()
    ) async throws -> PulseContinuityCredentials {
        if let stored = try await loadUsableCredentials() { return stored }
        switch configuration.mode {
        case .devSimulator:
            return try await ensureDevSimulatorRegistration(app: app, device: device)
        case .appAttest:
            return try await ensureAppAttestRegistration(app: app, device: device)
        }
    }

    /// Discard BOTH the persisted credentials and the stored App Attest key id, then register fresh.
    /// Recovery for a dead key: when a key id outlives its Secure Enclave key (the keychain survives
    /// an app delete/reinstall but the key is wiped), the stored id is structurally valid yet
    /// `generateAssertion` fails with a devicecheck error. Clearing both forces a brand-new key.
    public func reregisterWithFreshKey(
        app: PulseContinuityAppMetadata,
        device: PulseContinuityDeviceMetadata = PulseContinuityDeviceMetadata()
    ) async throws -> PulseContinuityCredentials {
        try? await credentials.delete()
        #if os(iOS) && canImport(DeviceCheck)
        try? PulseContinuityAppAttestKeyStore(environment: configuration.appAttestEnvironment).delete()
        #endif
        return try await ensureRegistration(app: app, device: device)
    }

    #if DEBUG
    func captureAppAttestRegistrationFixture(
        app: PulseContinuityAppMetadata,
        device: PulseContinuityDeviceMetadata = PulseContinuityDeviceMetadata()
    ) async throws -> PulseAppAttestRegistrationFixture {
        #if os(iOS) && canImport(DeviceCheck)
        guard #available(iOS 14.0, *) else {
            throw KenshikiPulseError.invalidConfiguration("App Attest requires iOS 14 or later.")
        }
        let service = DCAppAttestService.shared
        guard service.isSupported else {
            throw KenshikiPulseError.invalidConfiguration("App Attest is not supported on this device.")
        }

        let clientInstallationID = Self.makeULID()
        let keyStore = PulseContinuityAppAttestKeyStore(
            environment: "diagnostic-\(configuration.appAttestEnvironment ?? "unspecified")"
        )
        let keyID = try await keyStore.keyIdentifier(using: service, forceNew: true)
        let challenge = try Self.makeDiagnosticAppAttestChallenge()
        let clientDataHash = Data(SHA256.hash(data: Data(challenge.challenge.utf8)))
        let attestation = try await service.attestKeyAsync(keyID, clientDataHash: clientDataHash)
        return PulseAppAttestRegistrationFixture(
            schemaVersion: Self.registrationSchemaVersion,
            capturedAt: Date(),
            backendBaseURL: configuration.baseURL,
            appAttestEnvironment: configuration.appAttestEnvironment,
            clientInstallationId: clientInstallationID,
            app: app,
            device: device,
            appAttest: PulseAppAttestRegistrationFixtureEvidence(
                keyId: keyID,
                challenge: challenge.challenge,
                challengeExpiresAt: challenge.expiresAt,
                clientDataHash: clientDataHash.base64URLEncodedString(),
                attestationObject: attestation.base64URLEncodedString()
            )
        )
        #else
        throw KenshikiPulseError.invalidConfiguration("App Attest is only available on iOS.")
        #endif
    }
    #endif

    public func uploadOperationalCheckIn(
        _ checkIn: ContinuityCheckInResult,
        model: ContinuityModel.Result,
        app: PulseContinuityAppMetadata,
        device: PulseContinuityDeviceMetadata = PulseContinuityDeviceMetadata(),
        permissions: PulseContinuityPermissionSnapshot = PulseContinuityPermissionSnapshot(),
        localEvidence: PulseLocalEvidenceDiagnostics? = nil
    ) async throws -> PulseContinuityUploadResponse {
        let stored: PulseContinuityCredentials?
        if let current = try await loadUsableCredentials() {
            stored = current
        } else {
            stored = try await ensureRegistration(app: app, device: device)
        }
        guard let stored else {
            throw KenshikiPulseError.invalidConfiguration("Pulse continuity credentials are missing.")
        }

        return try await uploadOperationalCheckInAttempt(
            checkIn,
            model: model,
            app: app,
            device: device,
            permissions: permissions,
            localEvidence: localEvidence,
            stored: stored,
            allowCredentialRefresh: true
        )
    }

    private func uploadOperationalCheckInAttempt(
        _ checkIn: ContinuityCheckInResult,
        model: ContinuityModel.Result,
        app: PulseContinuityAppMetadata,
        device: PulseContinuityDeviceMetadata,
        permissions: PulseContinuityPermissionSnapshot,
        localEvidence: PulseLocalEvidenceDiagnostics?,
        stored: PulseContinuityCredentials,
        allowCredentialRefresh: Bool
    ) async throws -> PulseContinuityUploadResponse {
        let clientCheckInID = Self.makeULID()
        var payload = PulseCheckInRequest(
            schemaVersion: Self.checkInSchemaVersion,
            clientCheckInId: clientCheckInID,
            occurredAt: checkIn.envelope.generatedAt,
            collectedAt: checkIn.lastCheckIn,
            app: app,
            device: device,
            permissions: permissions,
            continuity: PulseCheckInContinuity(from: checkIn, model: model),
            lanes: PulseEvidenceLaneSnapshot.backendSnapshots(from: checkIn.evaluation.evidenceSnapshot),
            clientDiagnostics: PulseClientDiagnostics(
                engineVersion: "continuity-model-v2",
                traceReplayCompatible: true,
                localEvidence: localEvidence
            )
        )

        if configuration.mode == .appAttest {
            payload.appAttestAssertion = try await makeAppAttestAssertion(for: payload)
        }

        do {
            return try await post(
                path: "/api/v1/pulse/check-ins",
                schemaVersion: Self.checkInSchemaVersion,
                idempotencyKey: clientCheckInID,
                bearerToken: stored.token,
                body: payload
            )
        } catch let error as KenshikiPulseError
            where allowCredentialRefresh && configuration.mode == .appAttest && error.isForbiddenHTTPStatus {
            try await credentials.delete()
            #if os(iOS) && canImport(DeviceCheck)
            if #available(iOS 14.0, *) {
                try PulseContinuityAppAttestKeyStore(environment: configuration.appAttestEnvironment).delete()
            }
            #endif
            let refreshed = try await ensureRegistration(app: app, device: device)
            return try await uploadOperationalCheckInAttempt(
                checkIn,
                model: model,
                app: app,
                device: device,
                permissions: permissions,
                localEvidence: localEvidence,
                stored: refreshed,
                allowCredentialRefresh: false
            )
        }
    }

    private func loadUsableCredentials() async throws -> PulseContinuityCredentials? {
        guard let stored = try await credentials.load() else { return nil }
        guard stored.matches(configuration: configuration) else {
            try await credentials.delete()
            return nil
        }
        return stored
    }

    private func ensureAppAttestRegistration(
        app: PulseContinuityAppMetadata,
        device: PulseContinuityDeviceMetadata
    ) async throws -> PulseContinuityCredentials {
        #if os(iOS) && canImport(DeviceCheck)
        guard #available(iOS 14.0, *) else {
            throw KenshikiPulseError.invalidConfiguration("App Attest requires iOS 14 or later.")
        }
        let service = DCAppAttestService.shared
        guard service.isSupported else {
            throw KenshikiPulseError.invalidConfiguration("App Attest is not supported on this device.")
        }

        let keyStore = PulseContinuityAppAttestKeyStore(environment: configuration.appAttestEnvironment)
        let clientInstallationID = Self.makeULID()
        let registration: AppAttestRegistrationResult
        do {
            registration = try await postAppAttestRegistration(
                service: service,
                keyStore: keyStore,
                clientInstallationID: clientInstallationID,
                app: app,
                device: device,
                forceNewKey: false
            )
        } catch let error as KenshikiPulseError where error.isForbiddenHTTPStatus {
            try keyStore.delete()
            registration = try await postAppAttestRegistration(
                service: service,
                keyStore: keyStore,
                clientInstallationID: clientInstallationID,
                app: app,
                device: device,
                forceNewKey: true
            )
        }
        let stored = PulseContinuityCredentials(
            installationID: registration.response.installationId,
            clientInstallationID: clientInstallationID,
            appAttestKeyID: registration.keyID,
            token: registration.response.token,
            expiresAt: registration.response.expiresAt,
            backendBaseURL: configuration.baseURL,
            mode: configuration.mode,
            appAttestEnvironment: configuration.appAttestEnvironment
        )
        try await credentials.save(stored)
        return stored
        #else
        throw KenshikiPulseError.invalidConfiguration("App Attest is only available on iOS.")
        #endif
    }

    #if os(iOS) && canImport(DeviceCheck)
    @available(iOS 14.0, *)
    private func postAppAttestRegistration(
        service: DCAppAttestService,
        keyStore: PulseContinuityAppAttestKeyStore,
        clientInstallationID: String,
        app: PulseContinuityAppMetadata,
        device: PulseContinuityDeviceMetadata,
        forceNewKey: Bool
    ) async throws -> AppAttestRegistrationResult {
        let attested = try await makeAppAttestRegistrationEvidence(
            service: service,
            keyStore: keyStore,
            clientInstallationID: clientInstallationID,
            app: app,
            device: device,
            forceNewKey: forceNewKey
        )
        let registration = PulseInstallationRegistrationRequest(
            schemaVersion: Self.registrationSchemaVersion,
            mode: configuration.mode.rawValue,
            clientInstallationId: clientInstallationID,
            app: app,
            device: device,
            appAttest: PulseAppAttestRegistration(
                keyId: attested.keyID,
                challenge: attested.challenge.challenge,
                attestationObject: attested.attestation.base64URLEncodedString(),
                clientDataHash: attested.clientDataHash.base64URLEncodedString()
            )
        )
        let response: PulseInstallationRegistrationResponse = try await post(
            path: "/api/v1/pulse/installations",
            schemaVersion: Self.registrationSchemaVersion,
            idempotencyKey: nil,
            bearerToken: nil,
            body: registration
        )
        return AppAttestRegistrationResult(response: response, keyID: attested.keyID)
    }

    @available(iOS 14.0, *)
    private func makeAppAttestRegistrationEvidence(
        service: DCAppAttestService,
        keyStore: PulseContinuityAppAttestKeyStore,
        clientInstallationID: String,
        app: PulseContinuityAppMetadata,
        device: PulseContinuityDeviceMetadata,
        forceNewKey: Bool
    ) async throws -> PulseAppAttestRegistrationEvidence {
        let keyID = try await keyStore.keyIdentifier(using: service, forceNew: forceNewKey)
        let challengeRequest = PulseAppAttestChallengeRequest(
            schemaVersion: Self.challengeSchemaVersion,
            clientInstallationId: clientInstallationID,
            app: app,
            device: device
        )
        let challenge: PulseAppAttestChallengeResponse = try await post(
            path: "/api/v1/pulse/app-attest/challenge",
            schemaVersion: Self.challengeSchemaVersion,
            idempotencyKey: nil,
            bearerToken: nil,
            body: challengeRequest
        )
        let clientDataHash = Data(SHA256.hash(data: Data(challenge.challenge.utf8)))
        do {
            let attestation = try await service.attestKeyAsync(keyID, clientDataHash: clientDataHash)
            return PulseAppAttestRegistrationEvidence(
                keyID: keyID,
                challenge: challenge,
                clientDataHash: clientDataHash,
                attestation: attestation
            )
        } catch {
            guard !forceNewKey else { throw error }
            try keyStore.delete()
            return try await makeAppAttestRegistrationEvidence(
                service: service,
                keyStore: keyStore,
                clientInstallationID: clientInstallationID,
                app: app,
                device: device,
                forceNewKey: true
            )
        }
    }
    #endif

    private func makeAppAttestAssertion(for payload: PulseCheckInRequest) async throws -> PulseContinuityAppAttestAssertion {
        #if os(iOS) && canImport(DeviceCheck)
        guard #available(iOS 14.0, *) else {
            throw KenshikiPulseError.invalidConfiguration("App Attest requires iOS 14 or later.")
        }
        let service = DCAppAttestService.shared
        guard service.isSupported else {
            throw KenshikiPulseError.invalidConfiguration("App Attest is not supported on this device.")
        }
        let keyID = try await PulseContinuityAppAttestKeyStore(
            environment: configuration.appAttestEnvironment
        ).keyIdentifier(using: service)
        let clientDataHash = try Self.clientDataHash(for: payload, encoder: encoder)
        let assertion = try await service.generateAssertionAsync(keyID, clientDataHash: clientDataHash)
        return PulseContinuityAppAttestAssertion(
            keyId: keyID,
            assertionObject: assertion.base64URLEncodedString(),
            clientDataHash: clientDataHash.base64URLEncodedString()
        )
        #else
        throw KenshikiPulseError.invalidConfiguration("App Attest is only available on iOS.")
        #endif
    }

    private func post<RequestBody: Encodable, ResponseBody: Decodable>(
        path: String,
        schemaVersion: String,
        idempotencyKey: String?,
        bearerToken: String?,
        body: RequestBody
    ) async throws -> ResponseBody {
        let normalizedPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var request = URLRequest(url: configuration.baseURL.appendingPathComponent(normalizedPath))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(schemaVersion, forHTTPHeaderField: "X-Pulse-Schema-Version")
        request.setValue("KenshikiPulseSDK/\(KenshikiPulseConstants.sdkVersion)", forHTTPHeaderField: "User-Agent")
        if let idempotencyKey {
            request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        }
        if let bearerToken {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }
        for (header, value) in configuration.additionalHeaders {
            request.setValue(value, forHTTPHeaderField: header)
        }
        request.httpBody = try encoder.encode(body)

        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw KenshikiPulseError.httpStatus(response.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return try decoder.decode(ResponseBody.self, from: data)
    }
}

private struct PulseAppAttestRegistrationEvidence {
    let keyID: String
    let challenge: PulseAppAttestChallengeResponse
    let clientDataHash: Data
    let attestation: Data
}

private struct AppAttestRegistrationResult {
    let response: PulseInstallationRegistrationResponse
    let keyID: String
}

private struct PulseInstallationRegistrationRequest: Codable {
    let schemaVersion: String
    let mode: String
    let clientInstallationId: String
    let app: PulseContinuityAppMetadata
    let device: PulseContinuityDeviceMetadata
    let appAttest: PulseAppAttestRegistration?

    init(
        schemaVersion: String,
        mode: String,
        clientInstallationId: String,
        app: PulseContinuityAppMetadata,
        device: PulseContinuityDeviceMetadata,
        appAttest: PulseAppAttestRegistration? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.mode = mode
        self.clientInstallationId = clientInstallationId
        self.app = app
        self.device = device
        self.appAttest = appAttest
    }
}

private struct PulseAppAttestChallengeRequest: Codable {
    let schemaVersion: String
    let clientInstallationId: String
    let app: PulseContinuityAppMetadata
    let device: PulseContinuityDeviceMetadata
}

private struct PulseAppAttestChallengeResponse: Codable {
    let challenge: String
    let expiresAt: Date
}

private struct PulseAppAttestRegistration: Codable {
    let keyId: String
    let challenge: String
    let attestationObject: String
    let clientDataHash: String
}

private struct PulseInstallationRegistrationResponse: Codable {
    let installationId: String
    let token: String
    let tokenType: String
    let expiresAt: Date?
}

private struct PulseCheckInRequest: Codable {
    let schemaVersion: String
    let clientCheckInId: String
    let occurredAt: Date
    let collectedAt: Date
    let app: PulseContinuityAppMetadata
    let device: PulseContinuityDeviceMetadata
    let permissions: PulseContinuityPermissionSnapshot
    let continuity: PulseCheckInContinuity
    let lanes: [PulseEvidenceLaneSnapshot]
    var appAttestAssertion: PulseContinuityAppAttestAssertion?
    let clientDiagnostics: PulseClientDiagnostics
}

private struct PulseContinuityAppAttestAssertion: Codable {
    let keyId: String
    let assertionObject: String
    let clientDataHash: String
}

private struct PulseCheckInContinuity: Codable {
    let result: String
    let trustScore: Double
    let confidence: Double
    let maturity: Double
    let breadth: Double
    let eligibleCoverage: Double
    let contradictionCount: Int
    let staleCount: Int
    let terms: PulseContinuityTerms

    init(from checkIn: ContinuityCheckInResult, model: ContinuityModel.Result) {
        let snapshot = checkIn.evaluation.evidenceSnapshot
        self.result = Self.result(from: checkIn, model: model)
        self.trustScore = clamp(model.lowerBound)
        self.confidence = clamp(model.confidence)
        self.maturity = clamp(model.terms.maturity)
        self.breadth = clamp(snapshot.groupedEvidenceBreadth)
        self.eligibleCoverage = clamp(snapshot.groupedEligibleCoverage)
        self.contradictionCount = snapshot.contradictoryCount
        self.staleCount = snapshot.staleCount
        self.terms = PulseContinuityTerms(from: model, snapshot: snapshot)
    }

    private static func result(from checkIn: ContinuityCheckInResult, model: ContinuityModel.Result) -> String {
        let snapshot = checkIn.evaluation.evidenceSnapshot
        if snapshot.eligibleCount == 0 || snapshot.liveCount == 0 { return "insufficient_evidence" }
        if checkIn.breakReason != nil { return "fail" }
        if model.lowerBound >= 0.7 { return "pass" }
        return "review"
    }
}

private struct PulseContinuityTerms: Codable {
    let support: Double
    let breadth: Double
    let maturity: Double
    let freshness: Double
    let contradictionPenalty: Double
    let sparseEvidencePenalty: Double

    init(from model: ContinuityModel.Result, snapshot: ContinuityEvidenceSnapshot) {
        self.support = clamp(model.terms.signalAuthenticity)
        self.breadth = clamp(snapshot.groupedEvidenceBreadth)
        self.maturity = clamp(model.terms.maturity)
        self.freshness = clamp(model.terms.recency)
        self.contradictionPenalty = snapshot.contradictoryCount > 0 ? min(1, Double(snapshot.contradictoryCount) / 4) : 0
        self.sparseEvidencePenalty = clamp(1 - snapshot.groupedEvidenceBreadth)
    }
}

private struct PulseEvidenceLaneSnapshot: Codable {
    let lane: String
    let group: String
    let state: String
    let supportStatus: String
    let confidence: Double
    let ageSeconds: Double?
    let weight: Double?
    let reason: String

    static func backendSnapshots(from snapshot: ContinuityEvidenceSnapshot) -> [PulseEvidenceLaneSnapshot] {
        let grouped = Dictionary(grouping: snapshot.points, by: { BackendLane(from: $0.lane) })
        return grouped.compactMap { backend, points in
            guard let backend else { return nil }
            let selected = points.max { rank($0) < rank($1) }
            return selected.map { PulseEvidenceLaneSnapshot(backend: backend, point: $0) }
        }
        .sorted { $0.lane < $1.lane }
    }

    init(backend: BackendLane, point: ContinuityEvidencePoint) {
        self.lane = backend.rawValue
        self.group = backend.group
        self.supportStatus = backendSupportStatus(from: point.supportStatus)
        self.state = self.supportStatus == "available" ? backendState(from: point.state) : "unavailable"
        self.confidence = laneConfidence(for: point)
        self.ageSeconds = nil
        self.weight = nil
        self.reason = String((point.reason ?? defaultReason(for: point)).prefix(120))
    }

    private static func rank(_ point: ContinuityEvidencePoint) -> Int {
        switch point.state {
        case .contradictory: return 5
        case .observed: return 4
        case .stale: return 3
        case .empty: return 2
        case .unavailable: return 1
        }
    }
}

private enum BackendLane: String {
    case motion
    case network
    case telephony
    case power
    case attention
    case bluetooth
    case environment

    init?(from lane: ContinuityEvidenceLane) {
        switch lane {
        case .motion: self = .motion
        case .connectivity: self = .network
        case .telephony: self = .telephony
        case .battery: self = .power
        case .mediaOutput, .focus, .interaction: self = .attention
        case .bluetooth: self = .bluetooth
        case .barometer, .magnetometer, .ambientLight, .trustedBLEWitness, .displayProjection, .deviceSurface:
            self = .environment
        case .place: return nil
        }
    }

    var group: String {
        switch self {
        case .motion: return "movement"
        case .network, .telephony, .bluetooth: return "network"
        case .power: return "power"
        case .attention: return "attentionFocus"
        case .environment: return "deviceEnvironment"
        }
    }
}

public struct PulseLocalEvidenceDiagnostics: Codable, Equatable, Sendable {
    public let directSensorRowCount: Int
    public let compatibilityRowCount: Int
    public let inputHash: String?
    public let windowStartAt: Date
    public let windowEndAt: Date
    public let latestDirectSensorRowAt: Date?
    public let directRowsBySensor: [String: Int]
    public let unavailableRowsBySensor: [String: Int]

    public init(
        directSensorRowCount: Int,
        compatibilityRowCount: Int,
        inputHash: String?,
        windowStartAt: Date,
        windowEndAt: Date,
        latestDirectSensorRowAt: Date?,
        directRowsBySensor: [String: Int],
        unavailableRowsBySensor: [String: Int]
    ) {
        self.directSensorRowCount = directSensorRowCount
        self.compatibilityRowCount = compatibilityRowCount
        self.inputHash = inputHash
        self.windowStartAt = windowStartAt
        self.windowEndAt = windowEndAt
        self.latestDirectSensorRowAt = latestDirectSensorRowAt
        self.directRowsBySensor = directRowsBySensor
        self.unavailableRowsBySensor = unavailableRowsBySensor
    }
}

private struct PulseClientDiagnostics: Codable {
    let engineVersion: String
    let traceReplayCompatible: Bool
    let localEvidence: PulseLocalEvidenceDiagnostics?
}

private func backendSupportStatus(from status: SignalSupportStatus) -> String {
    switch status {
    case .available: return "available"
    case .notCollected: return "notCollected"
    case .disabledByConfiguration: return "unavailable"
    case .notSupportedByPlatform, .unavailable: return "unavailable"
    }
}

private func backendState(from state: ContinuityEvidenceState) -> String {
    switch state {
    case .observed: return "supporting"
    case .empty: return "weak"
    case .unavailable: return "unavailable"
    case .stale: return "stale"
    case .contradictory: return "contradicting"
    }
}

private func laneConfidence(for point: ContinuityEvidencePoint) -> Double {
    switch point.state {
    case .observed: return 0.75
    case .empty: return 0.25
    case .unavailable: return 0
    case .stale: return 0.15
    case .contradictory: return 0.8
    }
}

private func defaultReason(for point: ContinuityEvidencePoint) -> String {
    switch point.state {
    case .observed: return "\(point.lane.rawValue) observed"
    case .empty: return "\(point.lane.rawValue) available but empty"
    case .unavailable: return "\(point.lane.rawValue) unavailable"
    case .stale: return "\(point.lane.rawValue) stale"
    case .contradictory: return "\(point.lane.rawValue) contradictory"
    }
}

private func clamp(_ value: Double) -> Double {
    min(1, max(0, value))
}

private func normalizedEnvironment(_ value: String?) -> String {
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard let trimmed, !trimmed.isEmpty else { return "unspecified" }
    return trimmed
}

private func keychainSafeComponent(_ value: String) -> String {
    value
        .lowercased()
        .map { character in
            character.isLetter || character.isNumber ? character : "-"
        }
        .reduce(into: "") { result, character in
            if character == "-", result.last == "-" { return }
            result.append(character)
        }
}

private extension KenshikiPulseError {
    var isForbiddenHTTPStatus: Bool {
        if case .httpStatus(403, _) = self { return true }
        return false
    }
}

#if os(iOS) && canImport(DeviceCheck)
@available(iOS 14.0, *)
private final class PulseContinuityAppAttestKeyStore: @unchecked Sendable {
    private let service = "com.kenshiki.pulse.continuity.app-attest"
    private let account: String

    init(environment: String?) {
        let environment = keychainSafeComponent(normalizedEnvironment(environment))
        self.account = "key-id.v2.\(environment)"
    }

    func keyIdentifier(using service: DCAppAttestService, forceNew: Bool = false) async throws -> String {
        if !forceNew, let existing = try load(), !existing.isEmpty {
            return existing
        }
        if forceNew {
            try delete()
        }
        let generated = try await service.generateKeyAsync()
        try save(generated)
        return generated
    }

    private func load() throws -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw KenshikiPulseError.storageFailed("App Attest keychain load failed: \(status)")
        }
        return String(data: data, encoding: .utf8)
    }

    private func save(_ keyIdentifier: String) throws {
        let data = Data(keyIdentifier.utf8)
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery() as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return }
        if status != errSecItemNotFound {
            throw KenshikiPulseError.storageFailed("App Attest keychain update failed: \(status)")
        }

        var query = baseQuery()
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KenshikiPulseError.storageFailed("App Attest keychain add failed: \(addStatus)")
        }
    }

    func delete() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KenshikiPulseError.storageFailed("App Attest keychain delete failed: \(status)")
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

@available(iOS 14.0, *)
private extension DCAppAttestService {
    func generateKeyAsync() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            generateKey { keyIdentifier, error in
                if let keyIdentifier {
                    continuation.resume(returning: keyIdentifier)
                } else {
                    continuation.resume(throwing: error ?? KenshikiPulseError.networkFailed("App Attest key generation failed."))
                }
            }
        }
    }

    func attestKeyAsync(_ keyIdentifier: String, clientDataHash: Data) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            attestKey(keyIdentifier, clientDataHash: clientDataHash) { attestation, error in
                if let attestation {
                    continuation.resume(returning: attestation)
                } else {
                    continuation.resume(throwing: error ?? KenshikiPulseError.networkFailed("App Attest attestation failed."))
                }
            }
        }
    }

    func generateAssertionAsync(_ keyIdentifier: String, clientDataHash: Data) async throws -> Data {
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

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private extension PulseContinuityBackendClient {
    #if DEBUG
    static func makeDiagnosticAppAttestChallenge(now: Date = Date()) throws -> PulseAppAttestChallengeResponse {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw KenshikiPulseError.networkFailed("Unable to create diagnostic App Attest challenge.")
        }
        return PulseAppAttestChallengeResponse(
            challenge: Data(bytes).base64URLEncodedString(),
            expiresAt: now.addingTimeInterval(5 * 60)
        )
    }
    #endif

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Self.isoFormatter.string(from: date))
        }
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            if let date = isoFormatter.date(from: value) { return date }
            if let date = ISO8601DateFormatter().date(from: value) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO8601 date")
        }
        return decoder
    }

    static func clientDataHash<RequestBody: Encodable>(for body: RequestBody, encoder: JSONEncoder) throws -> Data {
        let encoded = try encoder.encode(body)
        let object = try JSONSerialization.jsonObject(with: encoded)
        let canonical = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        return Data(SHA256.hash(data: canonical))
    }

    static var isoFormatter: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    static func makeULID(now: Date = Date()) -> String {
        let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        var value = UInt64(now.timeIntervalSince1970 * 1000)
        var chars = Array(repeating: Character("0"), count: 26)
        for index in stride(from: 9, through: 0, by: -1) {
            chars[index] = alphabet[Int(value & 31)]
            value >>= 5
        }
        var random = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, random.count, &random)
        for index in 10..<26 {
            chars[index] = alphabet[Int(random[index - 10] & 31)]
        }
        return String(chars)
    }
}
