import Foundation

public struct KenshikiPulseConfiguration: Equatable, Sendable {
    public var endpoint: URL?
    public var apiKey: String?
    public var captureDuration: TimeInterval
    public var includeBarometerAvailability: Bool
    public var consentPolicy: KenshikiConsentPolicy
    public var additionalHeaders: [String: String]
    public var signEvidence: Bool
    public var enablePlatformAttestation: Bool
    public var appAttestEnvironment: String
    /// Emit the salted, tenant-scoped, rotating device-recurrence pseudonym (see ``DeviceRecurrence``).
    /// Suppressed regardless of this flag when `consentPolicy == .disabledForLocalTesting`.
    public var enableDeviceRecurrence: Bool
    /// Rotation window for the recurrence token, in days. The receipt carries the current and previous
    /// window so a relying party can chain across a boundary; a longer absence unlinks (forward privacy).
    public var deviceRecurrenceRotationDays: Int

    public init(
        endpoint: URL? = nil,
        apiKey: String? = nil,
        captureDuration: TimeInterval = 1.5,
        includeBarometerAvailability: Bool = true,
        consentPolicy: KenshikiConsentPolicy = .hostApplicationManaged,
        additionalHeaders: [String: String] = [:],
        signEvidence: Bool = true,
        enablePlatformAttestation: Bool = true,
        appAttestEnvironment: String = "production",
        enableDeviceRecurrence: Bool = true,
        deviceRecurrenceRotationDays: Int = 90
    ) {
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.captureDuration = captureDuration
        self.includeBarometerAvailability = includeBarometerAvailability
        self.consentPolicy = consentPolicy
        self.additionalHeaders = additionalHeaders
        self.signEvidence = signEvidence
        self.enablePlatformAttestation = enablePlatformAttestation
        self.appAttestEnvironment = appAttestEnvironment
        self.enableDeviceRecurrence = enableDeviceRecurrence
        self.deviceRecurrenceRotationDays = deviceRecurrenceRotationDays
    }
}

public enum KenshikiConsentPolicy: String, Codable, Equatable, Sendable {
    case hostApplicationManaged = "host_application_managed"
    case requiredBeforeCollection = "required_before_collection"
    case disabledForLocalTesting = "disabled_for_local_testing"
}
