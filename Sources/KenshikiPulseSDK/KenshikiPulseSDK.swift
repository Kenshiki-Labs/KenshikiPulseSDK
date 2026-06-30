import Foundation

public final class KenshikiPulseSDK: @unchecked Sendable {
	public let configuration: KenshikiPulseConfiguration

	private let collector: DevicePhysicsCollecting
	private let verificationClient: ExistenceVerificationClient

	public init(
		configuration: KenshikiPulseConfiguration = KenshikiPulseConfiguration(),
		collector: DevicePhysicsCollecting? = nil,
		transport: ExistenceVerificationTransport = URLSessionExistenceVerificationTransport()
	) {
		self.configuration = configuration
		self.collector = collector ?? DefaultDevicePhysicsCollector(configuration: configuration)
		self.verificationClient = ExistenceVerificationClient(
			configuration: configuration,
			collector: self.collector,
			transport: transport
		)
	}

	public func collectDeviceEvidence(context: KenshikiSessionContext) async throws -> DeviceEvidenceEnvelope {
		let evidence = try await collector.collectEvidence(context: context)
		return try await EvidenceIntegrityIssuer.shared.signedEnvelope(
			from: evidence,
			configuration: configuration
		)
	}

	public func verifyExistence(context: KenshikiSessionContext) async throws -> ExistenceVerificationResult {
		try await verificationClient.verify(context: context)
	}

	/// Attest a passport identity capture (or any small claim) and return a device-signed,
	/// Merkle-chained receipt suitable for recording on the continuity claim ledger.
	///
	/// - Parameters:
	///   - payload: canonical key/value fields describing the capture (source, tier, field hashes,
	///     server result, key version). Encoded with the SDK's canonical JSON so the signed payload
	///     hash is reproducible.
	///   - challenge: a fresh server nonce (e.g. the passport identity nonce). When present, the
	///     receipt carries a real App Attest assertion bound to it; when `nil`, the receipt is
	///     device-signed only (App Attest reports `challenge_required`) — appropriate for data that
	///     never leaves the device, such as an MRZ document scan.
	public func attestIdentityClaim(
		payload: [String: String],
		challenge: Data? = nil
	) async throws -> EvidenceIntegrityReceipt {
		let canonical = try CanonicalJSON.encode(payload)
		return try await EvidenceIntegrityIssuer.shared.identityReceipt(
			canonicalPayload: canonical,
			challenge: challenge,
			configuration: configuration
		)
	}
}
