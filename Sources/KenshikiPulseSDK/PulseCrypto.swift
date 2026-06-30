import Foundation
import CryptoKit

private struct AssertionPayload: Encodable {
    let sessionID: String
    let nonce: String
    let deviceID: String
    let subjectID: String
    let issuedAt: Date
    let attestations: PulseAssertionAttestations

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case nonce
        case deviceID = "device_id"
        case subjectID = "subject_id"
        case issuedAt = "issued_at"
        case attestations
    }
}

public enum PulseCrypto {
    public static func developmentSignature(
        for assertion: BondedPairAssertion,
        deviceKeyId: String
    ) throws -> String {
        guard let attestations = assertion.attestations else {
            throw KenshikiPulseError.encodingFailed("Development signatures require legacy attestations.")
        }

        // 1. Map to payload without the signature field
        let payload = AssertionPayload(
            sessionID: assertion.sessionID,
            nonce: assertion.nonce,
            deviceID: assertion.deviceID,
            subjectID: assertion.subjectID,
            issuedAt: assertion.issuedAt,
            attestations: attestations
        )

        // 2. Canonical JSON encoding
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        // TypeScript `Date.toISOString()` includes milliseconds (e.g. 2024-06-23T16:00:00.000Z)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(formatter.string(from: date))
        }

        let jsonData = try encoder.encode(payload)

        // 3. Digest: SHA256("pulse:bonded-pair-assertion:v1" + "\0" + CanonicalJSON + "\0" + deviceKeyId)
        var hasher = SHA256()
        hasher.update(data: Data("pulse:bonded-pair-assertion:v1".utf8))
        hasher.update(data: Data([0]))
        hasher.update(data: jsonData)
        hasher.update(data: Data([0]))
        hasher.update(data: Data(deviceKeyId.utf8))

        let digest = hasher.finalize()

        // 4. Base64URL encode
        let base64 = Data(digest).base64EncodedString()
        let base64url = base64.replacingOccurrences(of: "+", with: "-")
                              .replacingOccurrences(of: "/", with: "_")
                              .replacingOccurrences(of: "=", with: "")

        return "devsig_\(base64url)"
    }
}
