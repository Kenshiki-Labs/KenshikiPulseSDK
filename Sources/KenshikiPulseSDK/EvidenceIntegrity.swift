import CryptoKit
import Foundation
import Security

#if os(iOS) && canImport(DeviceCheck)
import DeviceCheck
#endif

public enum EvidenceIntegrity {
    public static func verify(_ envelope: DeviceEvidenceEnvelope) -> Bool {
        guard let receipt = envelope.receipt,
              let publicKeyData = Data(base64URLEncoded: receipt.deviceSigning.publicKey),
              let signature = Data(base64URLEncoded: receipt.deviceSigning.signature)
        else { return false }

        var unsignedEnvelope = envelope
        unsignedEnvelope.receipt = nil

        do {
            let payloadData = try CanonicalJSON.encode(unsignedEnvelope)
            let payloadHashData = SHA256.digestData(payloadData)
            guard payloadHashData.base64URLEncodedString() == receipt.payloadHash else { return false }

            let leafHash = MerkleLedger.leafHash(payloadHashData)
            guard leafHash.base64URLEncodedString() == receipt.leafHash else { return false }

            let signingPayload = EvidenceSigningPayload(
                receiptSchemaVersion: receipt.schemaVersion,
                signedAt: receipt.signedAt,
                payloadHash: receipt.payloadHash,
                leafHash: receipt.leafHash,
                previousMerkleRoot: receipt.previousMerkleRoot,
                merkleRoot: receipt.merkleRoot,
                merkleLeafIndex: receipt.merkleLeafIndex,
                merkleLeafCount: receipt.merkleLeafCount,
                platformProvider: receipt.platformAttestation.provider,
                platformState: receipt.platformAttestation.state,
                platformKeyIdentifierHash: receipt.platformAttestation.keyIdentifierHash,
                platformClientDataHash: receipt.platformAttestation.clientDataHash
            )
            let signedData = try CanonicalJSON.encode(signingPayload)
            return DeviceEvidenceSigner.verify(
                signature: signature,
                signedData: signedData,
                publicKeyData: publicKeyData
            )
        } catch {
            return false
        }
    }

    /// Erase the local integrity state this SDK created: signing key, Merkle leaves, and App Attest key IDs.
    public static func eraseLocalState(appAttestEnvironments: [String] = ["development", "production"]) {
        DeviceEvidenceSigner.deletePersistentKey()
        MerkleLedger().clear()

        let environments = Set(appAttestEnvironments + ["development", "production"])
        for environment in environments {
            UserDefaults.standard.removeObject(
                forKey: "com.kenshiki.device.appattest.key-id.\(environment).v1"
            )
        }
    }
}

actor EvidenceIntegrityIssuer {
    static let shared = EvidenceIntegrityIssuer()

    private let signer: DeviceEvidenceSigner
    private let ledger: MerkleLedger
    private let platformAttestor: PlatformAttesting

    init(
        signer: DeviceEvidenceSigner = DeviceEvidenceSigner(),
        ledger: MerkleLedger = MerkleLedger(),
        platformAttestor: PlatformAttesting = AppleAppAttestProvider()
    ) {
        self.signer = signer
        self.ledger = ledger
        self.platformAttestor = platformAttestor
    }

    func signedEnvelope(
        from envelope: DeviceEvidenceEnvelope,
        configuration: KenshikiPulseConfiguration
    ) async throws -> DeviceEvidenceEnvelope {
        guard configuration.signEvidence else { return envelope }

        var unsignedEnvelope = envelope
        unsignedEnvelope.receipt = nil

        let payloadData = try CanonicalJSON.encode(unsignedEnvelope)
        let payloadHashData = SHA256.digestData(payloadData)
        let platformReceipt = await platformAttestor.attestationReceipt(
            envelope: unsignedEnvelope,
            payloadHashData: payloadHashData,
            configuration: configuration
        )
        let receipt = try assembleReceipt(payloadHashData: payloadHashData, platformReceipt: platformReceipt)

        var signedEnvelope = unsignedEnvelope
        signedEnvelope.receipt = receipt
        return signedEnvelope
    }

    /// Attest an arbitrary canonical payload (e.g. a passport identity capture) and return a signed,
    /// Merkle-chained receipt. `challenge` (a server nonce) yields a real App Attest assertion;
    /// `nil` ⇒ local device signature only (platform attestation reports `challenge_required`).
    func identityReceipt(
        canonicalPayload: Data,
        challenge: Data?,
        configuration: KenshikiPulseConfiguration
    ) async throws -> EvidenceIntegrityReceipt {
        let payloadHashData = SHA256.digestData(canonicalPayload)
        let platformReceipt = await platformAttestor.attestationReceipt(
            challenge: challenge,
            payloadHashData: payloadHashData,
            configuration: configuration
        )
        return try assembleReceipt(payloadHashData: payloadHashData, platformReceipt: platformReceipt)
    }

    /// Merkle-append + device-sign a payload hash into an `EvidenceIntegrityReceipt`. Shared by the
    /// check-in envelope path and the identity-claim path so both produce identical receipt shapes.
    private func assembleReceipt(
        payloadHashData: Data,
        platformReceipt: PlatformAttestationReceipt
    ) throws -> EvidenceIntegrityReceipt {
        let payloadHash = payloadHashData.base64URLEncodedString()
        let append = try ledger.append(payloadHashData: payloadHashData)
        let signedAt = Date()
        let signingPayload = EvidenceSigningPayload(
            receiptSchemaVersion: KenshikiPulseConstants.evidenceReceiptSchemaVersion,
            signedAt: signedAt,
            payloadHash: payloadHash,
            leafHash: append.leafHash,
            previousMerkleRoot: append.previousRoot,
            merkleRoot: append.root,
            merkleLeafIndex: append.leafIndex,
            merkleLeafCount: append.leafCount,
            platformProvider: platformReceipt.provider,
            platformState: platformReceipt.state,
            platformKeyIdentifierHash: platformReceipt.keyIdentifierHash,
            platformClientDataHash: platformReceipt.clientDataHash
        )
        let signedData = try CanonicalJSON.encode(signingPayload)
        let signature = try signer.sign(signedData)
        return EvidenceIntegrityReceipt(
            signedAt: signedAt,
            payloadHash: payloadHash,
            leafHash: append.leafHash,
            previousMerkleRoot: append.previousRoot,
            merkleRoot: append.root,
            merkleLeafIndex: append.leafIndex,
            merkleLeafCount: append.leafCount,
            deviceSigning: signature,
            platformAttestation: platformReceipt
        )
    }
}

struct EvidenceSigningPayload: Codable, Equatable {
    var receiptSchemaVersion: String
    var signedAt: Date
    var payloadHash: String
    var leafHash: String
    var previousMerkleRoot: String?
    var merkleRoot: String
    var merkleLeafIndex: Int
    var merkleLeafCount: Int
    var platformProvider: String
    var platformState: String
    var platformKeyIdentifierHash: String?
    var platformClientDataHash: String?
}

enum CanonicalJSON {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Self.iso8601Millis(date))
        }
        return try encoder.encode(value)
    }

    private static func iso8601Millis(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
}

final class DeviceEvidenceSigner: @unchecked Sendable {
    private static let defaultKeyTag = "com.kenshiki.device.evidence.signing-key.v1"

    private let keyTag: Data
    private let persistent: Bool
    private let preferSecureEnclave: Bool

    init(
        keyTag: String = DeviceEvidenceSigner.defaultKeyTag,
        persistent: Bool = true,
        preferSecureEnclave: Bool = true
    ) {
        self.keyTag = Data(keyTag.utf8)
        self.persistent = persistent
        self.preferSecureEnclave = preferSecureEnclave
    }

    func sign(_ data: Data) throws -> DeviceSigningReceipt {
        let key = try privateKey()
        let algorithm = SecKeyAlgorithm.ecdsaSignatureMessageX962SHA256
        guard SecKeyIsAlgorithmSupported(key.privateKey, .sign, algorithm) else {
            throw KenshikiPulseError.encodingFailed("Device signing key does not support ECDSA P-256 SHA-256.")
        }

        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(key.privateKey, algorithm, data as CFData, &error) as Data? else {
            throw error?.takeRetainedValue() ?? KenshikiPulseError.encodingFailed("Unable to sign evidence envelope.")
        }
        let publicKeyData = try Self.publicKeyData(from: key.privateKey)
        let publicKeyHash = SHA256.digestData(publicKeyData).base64URLEncodedString()

        return DeviceSigningReceipt(
            keyId: publicKeyHash,
            publicKey: publicKeyData.base64URLEncodedString(),
            publicKeyHash: publicKeyHash,
            secureHardware: key.secureHardware,
            signature: signature.base64URLEncodedString()
        )
    }

    private func privateKey() throws -> (privateKey: SecKey, secureHardware: Bool) {
        if persistent, let existing = Self.findPersistentKey(tag: keyTag) {
            return (existing, Self.isSecureEnclaveKey(existing))
        }

        if preferSecureEnclave, let secureKey = Self.createKey(tag: keyTag, persistent: persistent, secureEnclave: true) {
            return (secureKey, true)
        }
        if let softwareKey = Self.createKey(tag: keyTag, persistent: persistent, secureEnclave: false) {
            return (softwareKey, false)
        }
        throw KenshikiPulseError.encodingFailed("Unable to create an ECDSA P-256 device signing key.")
    }

    private static func findPersistentKey(tag: Data) -> SecKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecReturnRef as String: true
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let item else { return nil }
        // kSecReturnRef on a key class returns a SecKey on success; the cast is safe.
        return (item as! SecKey)   // swiftlint:disable:this force_cast
    }

    private static func createKey(tag: Data, persistent: Bool, secureEnclave: Bool) -> SecKey? {
        var privateAttributes: [String: Any] = [
            kSecAttrIsPermanent as String: persistent
        ]
        if persistent {
            privateAttributes[kSecAttrApplicationTag as String] = tag
            #if os(iOS)
            privateAttributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            #endif
        }

        var attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecPrivateKeyAttrs as String: privateAttributes
        ]
        if secureEnclave {
            attributes[kSecAttrTokenID as String] = kSecAttrTokenIDSecureEnclave
        }

        var error: Unmanaged<CFError>?
        return SecKeyCreateRandomKey(attributes as CFDictionary, &error)
    }

    private static func publicKeyData(from privateKey: SecKey) throws -> Data {
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw KenshikiPulseError.encodingFailed("Unable to derive device signing public key.")
        }
        var error: Unmanaged<CFError>?
        guard let data = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            throw error?.takeRetainedValue() ?? KenshikiPulseError.encodingFailed("Unable to export device signing public key.")
        }
        return data
    }

    private static func isSecureEnclaveKey(_ key: SecKey) -> Bool {
        guard let attributes = SecKeyCopyAttributes(key) as? [String: Any],
              let token = attributes[kSecAttrTokenID as String] as? String
        else { return false }
        return token == (kSecAttrTokenIDSecureEnclave as String)
    }

    static func deletePersistentKey(tag: String = defaultKeyTag) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: Data(tag.utf8),
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func verify(signature: Data, signedData: Data, publicKeyData: Data) -> Bool {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits as String: 256
        ]
        var keyError: Unmanaged<CFError>?
        guard let publicKey = SecKeyCreateWithData(publicKeyData as CFData, attributes as CFDictionary, &keyError) else {
            return false
        }
        let algorithm = SecKeyAlgorithm.ecdsaSignatureMessageX962SHA256
        guard SecKeyIsAlgorithmSupported(publicKey, .verify, algorithm) else { return false }
        var verifyError: Unmanaged<CFError>?
        return SecKeyVerifySignature(publicKey, algorithm, signedData as CFData, signature as CFData, &verifyError)
    }
}

final class MerkleLedger: @unchecked Sendable {
    private let defaults: UserDefaults
    private let storageKey: String

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = KenshikiPulseConstants.evidenceMerkleLedgerDefaultsKey
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
    }

    func append(payloadHashData: Data) throws -> MerkleAppendResult {
        var leaves = storedLeaves()
        let previousRoot = try Self.root(for: leaves)?.base64URLEncodedString()
        let leafHash = Self.leafHash(payloadHashData)
        leaves.append(leafHash)
        defaults.set(leaves.map { $0.base64URLEncodedString() }, forKey: storageKey)

        guard let root = try Self.root(for: leaves) else {
            throw KenshikiPulseError.encodingFailed("Unable to compute evidence Merkle root.")
        }
        return MerkleAppendResult(
            leafHash: leafHash.base64URLEncodedString(),
            previousRoot: previousRoot,
            root: root.base64URLEncodedString(),
            leafIndex: leaves.count - 1,
            leafCount: leaves.count
        )
    }

    func clear() {
        defaults.removeObject(forKey: storageKey)
    }

    private func storedLeaves() -> [Data] {
        let strings = defaults.stringArray(forKey: storageKey) ?? []
        return strings.compactMap { Data(base64URLEncoded: $0) }
    }

    static func leafHash(_ payloadHashData: Data) -> Data {
        var data = Data("kenshiki:evidence:leaf:v1".utf8)
        data.append(payloadHashData)
        return SHA256.digestData(data)
    }

    private static func parentHash(_ left: Data, _ right: Data) -> Data {
        var data = Data("kenshiki:evidence:node:v1".utf8)
        data.append(left)
        data.append(right)
        return SHA256.digestData(data)
    }

    private static func root(for leaves: [Data]) throws -> Data? {
        guard !leaves.isEmpty else { return nil }
        var level = leaves
        while level.count > 1 {
            var next: [Data] = []
            var index = 0
            while index < level.count {
                let left = level[index]
                let right = index + 1 < level.count ? level[index + 1] : left
                next.append(parentHash(left, right))
                index += 2
            }
            level = next
        }
        return level[0]
    }
}

struct MerkleAppendResult: Equatable {
    var leafHash: String
    var previousRoot: String?
    var root: String
    var leafIndex: Int
    var leafCount: Int
}

/// Extract an App Attest challenge from session metadata (the check-in path's challenge source).
func appAttestChallenge(from metadata: [String: String]) -> Data? {
    guard let challenge = metadata[KenshikiPulseConstants.appAttestChallengeMetadataKey],
          !challenge.isEmpty
    else { return nil }
    return Data(base64Encoded: challenge) ?? Data(challenge.utf8)
}

protocol PlatformAttesting: Sendable {
    /// Attest `payloadHashData`, bound to an optional server `challenge` (required for a real App
    /// Attest assertion; `nil` ⇒ `challenge_required`, i.e. local-signed only).
    func attestationReceipt(
        challenge: Data?,
        payloadHashData: Data,
        configuration: KenshikiPulseConfiguration
    ) async -> PlatformAttestationReceipt
}

extension PlatformAttesting {
    /// Envelope-based convenience used by the evidence check-in path — derives the challenge from
    /// session metadata, preserving the original behavior.
    func attestationReceipt(
        envelope: DeviceEvidenceEnvelope,
        payloadHashData: Data,
        configuration: KenshikiPulseConfiguration
    ) async -> PlatformAttestationReceipt {
        await attestationReceipt(
            challenge: appAttestChallenge(from: envelope.session.metadata),
            payloadHashData: payloadHashData,
            configuration: configuration
        )
    }
}

struct AppleAppAttestProvider: PlatformAttesting {
    func attestationReceipt(
        challenge: Data?,
        payloadHashData: Data,
        configuration: KenshikiPulseConfiguration
    ) async -> PlatformAttestationReceipt {
        guard configuration.enablePlatformAttestation else {
            return PlatformAttestationReceipt(
                state: "disabled",
                environment: configuration.appAttestEnvironment,
                reason: "Platform attestation is disabled by SDK configuration."
            )
        }

        guard let challenge else {
            return PlatformAttestationReceipt(
                state: "challenge_required",
                environment: configuration.appAttestEnvironment,
                reason: "Apple App Attest requires a fresh server challenge. "
                    + "Add metadata[\(KenshikiPulseConstants.appAttestChallengeMetadataKey)]."
            )
        }

        #if os(iOS) && canImport(DeviceCheck)
        guard #available(iOS 14.0, *) else {
            return PlatformAttestationReceipt(
                state: "not_supported",
                environment: configuration.appAttestEnvironment,
                reason: "Apple App Attest requires iOS 14 or later."
            )
        }

        let service = DCAppAttestService.shared
        guard service.isSupported else {
            return PlatformAttestationReceipt(
                state: "not_supported",
                environment: configuration.appAttestEnvironment,
                reason: "Apple App Attest is unavailable on this device or simulator."
            )
        }

        do {
            let keyStore = AppAttestKeyIDStore(environment: configuration.appAttestEnvironment)
            let keyResult = try await keyStore.keyIdentifier(using: service)
            let clientDataHash = Self.clientDataHash(challenge: challenge, payloadHashData: payloadHashData)
            let keyHash = SHA256.digestData(Data(keyResult.keyIdentifier.utf8)).base64URLEncodedString()

            if keyResult.createdNewKey {
                let attestation = try await service.attestKeyAsync(
                    keyResult.keyIdentifier,
                    clientDataHash: clientDataHash
                )
                return PlatformAttestationReceipt(
                    state: "attestation_generated",
                    environment: configuration.appAttestEnvironment,
                    keyIdentifier: keyResult.keyIdentifier,
                    keyIdentifierHash: keyHash,
                    clientDataHash: clientDataHash.base64URLEncodedString(),
                    attestationObject: attestation.base64URLEncodedString()
                )
            } else {
                let assertion = try await service.generateAssertionAsync(
                    keyResult.keyIdentifier,
                    clientDataHash: clientDataHash
                )
                return PlatformAttestationReceipt(
                    state: "assertion_generated",
                    environment: configuration.appAttestEnvironment,
                    keyIdentifier: keyResult.keyIdentifier,
                    keyIdentifierHash: keyHash,
                    clientDataHash: clientDataHash.base64URLEncodedString(),
                    assertionObject: assertion.base64URLEncodedString()
                )
            }
        } catch {
            return PlatformAttestationReceipt(
                state: "failed",
                environment: configuration.appAttestEnvironment,
                reason: error.localizedDescription
            )
        }
        #else
        return PlatformAttestationReceipt(
            state: "not_supported",
            environment: configuration.appAttestEnvironment,
            reason: "Apple App Attest is only available to iOS apps with the App Attest entitlement."
        )
        #endif
    }

    private static func clientDataHash(challenge: Data, payloadHashData: Data) -> Data {
        var data = Data("kenshiki:app-attest:client-data:v1".utf8)
        data.append(challenge)
        data.append(payloadHashData)
        return SHA256.digestData(data)
    }
}

#if os(iOS) && canImport(DeviceCheck)
@available(iOS 14.0, *)
private final class AppAttestKeyIDStore: @unchecked Sendable {
    private let storageKey: String
    private let defaults: UserDefaults

    init(environment: String, defaults: UserDefaults = .standard) {
        self.storageKey = "com.kenshiki.device.appattest.key-id.\(environment).v1"
        self.defaults = defaults
    }

    func keyIdentifier(using service: DCAppAttestService) async throws -> (keyIdentifier: String, createdNewKey: Bool) {
        if let existing = defaults.string(forKey: storageKey), !existing.isEmpty {
            return (existing, false)
        }
        let keyIdentifier = try await service.generateKeyAsync()
        defaults.set(keyIdentifier, forKey: storageKey)
        return (keyIdentifier, true)
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

private extension SHA256 {
    static func digestData(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }
}

private extension Data {
    init?(base64URLEncoded string: String) {
        var base64 = string.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = base64.count % 4
        if padding > 0 {
            base64.append(String(repeating: "=", count: 4 - padding))
        }
        self.init(base64Encoded: base64)
    }

    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
