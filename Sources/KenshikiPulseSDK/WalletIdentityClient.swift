import Foundation

/// The outcome of an Apple Wallet identity verification request.
public enum WalletIdentityResult: Sendable {
    /// The user approved. `encryptedDocument` must be forwarded to the server;
    /// the client cannot read identity fields — decryption requires the Identity Access Certificate.
    case verified(encryptedDocument: Data)
    /// The user tapped Cancel, or saw an empty wallet and dismissed.
    case declined
    /// The device/OS does not support Wallet identity, or the entitlement is not yet present.
    case unsupported
    /// The request failed for a non-user reason (network, unexpected error).
    case failed
}

extension WalletIdentityResult {
    public func asAttestation() -> PulseWalletIdentityAttestation {
        switch self {
        case .verified(let data):
            return PulseWalletIdentityAttestation(
                provider: "apple_wallet_passport",
                result: "verified",
                encryptedDocument: data.base64EncodedString())
        case .declined:
            return PulseWalletIdentityAttestation(
                provider: "apple_wallet_passport",
                result: "declined",
                encryptedDocument: nil)
        case .unsupported:
            return PulseWalletIdentityAttestation(
                provider: "apple_wallet_passport",
                result: "unsupported",
                encryptedDocument: nil)
        case .failed:
            return PulseWalletIdentityAttestation(
                provider: "apple_wallet_passport",
                result: "unavailable",
                encryptedDocument: nil)
        }
    }
}

#if os(iOS) && canImport(PassKit)
import PassKit

public struct WalletIdentityClient: Sendable {

    public init() {}

    /// Coarse, synchronous capability gate for UI affordances (show/hide the leg).
    /// The PassKit identity stack exists from iOS 16; this does *not* prove the device
    /// holds a document or that the app carries the Verify-with-Wallet entitlement —
    /// that precise check is async (`canRequestDocument`) and runs inside
    /// `requestVerification`, which returns `.unsupported` when it fails.
    public static var isSupported: Bool {
        if #available(iOS 16, *) { return true }
        return false
    }

    /// The document the user is asked to present. Passport / photo-ID presentment is
    /// only modeled by `PKIdentityPhotoIDDescriptor` (iOS 26+); on older systems the
    /// driver's-license descriptor is the available baseline for the spike.
    @available(iOS 16, *)
    private func makeDescriptor() -> any PKIdentityDocumentDescriptor {
        let elements: [PKIdentityElement] = [
            .givenName,
            .familyName,
            .dateOfBirth,
            .documentNumber,
        ]
        let intent = PKIdentityIntentToStore.willNotStore
        if #available(iOS 26, *) {
            let descriptor = PKIdentityPhotoIDDescriptor()
            descriptor.addElements(elements, intentToStore: intent)
            return descriptor
        }
        let descriptor = PKIdentityDriversLicenseDescriptor()
        descriptor.addElements(elements, intentToStore: intent)
        return descriptor
    }

    /// Request identity verification from a document in Apple Wallet.
    ///
    /// The encrypted response must be forwarded to the server for decryption using
    /// the Identity Access Certificate issued by Apple. The client never has access
    /// to plaintext identity fields.
    ///
    /// - Parameter nonce: A server-issued nonce binding this request to the session.
    @MainActor
    public func requestVerification(nonce: Data) async -> WalletIdentityResult {
        guard #available(iOS 16, *) else { return .unsupported }

        let descriptor = makeDescriptor()
        let controller = PKIdentityAuthorizationController()

        // Precise entitlement + on-device-document check. Without the Verify-with-Wallet
        // entitlement (Phase 0), this returns false and the leg reports unsupported.
        guard await controller.canRequestDocument(descriptor) else { return .unsupported }

        let request = PKIdentityRequest()
        request.nonce = nonce
        request.descriptor = descriptor

        do {
            let document = try await controller.requestDocument(request)
            return .verified(encryptedDocument: document.encryptedData)
        } catch let error as PKIdentityError {
            switch error.code {
            case .cancelled:
                return .declined
            case .notSupported:
                return .unsupported
            default:
                return .failed
            }
        } catch {
            return .failed
        }
    }
}
#else
public struct WalletIdentityClient: Sendable {
    public init() {}

    public static var isSupported: Bool { false }

    @MainActor
    public func requestVerification(nonce: Data) async -> WalletIdentityResult {
        .unsupported
    }
}
#endif
