import Foundation

public enum KenshikiPulseError: Error, Equatable, LocalizedError, Sendable {
    case missingEndpoint
    case invalidHTTPResponse
    case httpStatus(Int, String)
    case encodingFailed(String)
    case decodingFailed(String)
    case networkFailed(String)
    case storageFailed(String)
    case invalidConfiguration(String)

    public var errorDescription: String? {
        switch self {
        case .missingEndpoint:
            return "KenshikiPulseSDK requires an endpoint before submitting existence verification evidence."
        case .invalidHTTPResponse:
            return "The verification endpoint returned a non-HTTP response."
        case let .httpStatus(status, body):
            return "The verification endpoint returned HTTP \(status): \(body)."
        case let .encodingFailed(message):
            return "Failed to encode device evidence: \(message)."
        case let .decodingFailed(message):
            return "Failed to decode verification response: \(message)."
        case let .networkFailed(message):
            return "Verification request failed: \(message)."
        case let .storageFailed(message):
            return "On-device telemetry storage failed: \(message)."
        case let .invalidConfiguration(message):
            return "KenshikiPulseSDK configuration is invalid: \(message)."
        }
    }
}
