import Foundation
import CryptoKit

// MARK: - Chip authentication level

/// The strongest authentication protocol that succeeded during a chip read.
/// Higher values represent stronger anti-clone guarantees.
public enum PassportAuthLevel: Int, Comparable, Sendable {
    /// No chip authentication performed (data read but chip identity unconfirmed).
    case none = 0
    /// Basic Access Control session — older symmetric 3DES protocol.
    case basicAccessControl = 1
    /// Password Authenticated Connection Establishment — modern EC-based session.
    case paceAuthenticated = 2
    /// Active Authentication (DG15): chip signed a nonce with its private key.
    case activeAuthenticated = 3
    /// Chip Authentication (DG14): strongest — proves chip hardware, not just the key.
    case chipAuthenticated = 4

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public var attestationString: String {
        switch self {
        case .none:               return "none"
        case .basicAccessControl: return "basic_access_control"
        case .paceAuthenticated:  return "pace"
        case .activeAuthenticated: return "active_authentication"
        case .chipAuthenticated:  return "chip_authentication"
        }
    }
}

// MARK: - Errors

/// Specific, actionable failure reasons from a passport chip read.
public enum NFCPassportError: Error, Sendable {
    /// The document number, date of birth, or expiry was entered incorrectly — the chip rejected the key.
    case badMRZKey
    /// A data group hash did not match its entry in the SOD — data may have been tampered with.
    case dataIntegrityFailure
    /// The issuing country's CSCA is not in the bundled trust store. The chip data may be genuine but
    /// cannot be verified against a known government root.
    case cscaNotFound
    /// The NFC session dropped mid-read. Usually transient — the user should try again.
    case connectionLost
    /// The chip established a session (PACE or BAC) but did not pass Active Authentication (DG15)
    /// or Chip Authentication (DG14). Session-only proofs do not exercise the chip's private key
    /// and do not satisfy the Tier A hardware-genuineness requirement.
    case chipAuthenticationRequired
    /// NFCPassportReader (github.com/AndyQ/NFCPassportReader) has not been added as an SPM dependency.
    case libraryNotLinked
    /// An error that does not fit the above categories.
    case unknown(String)
}

extension NFCPassportError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .badMRZKey:
            return "The passport details you entered don't match the chip. Check the document number, date of birth, and expiry date."
        case .dataIntegrityFailure:
            return "The chip data did not pass integrity checks. The document may have been altered."
        case .cscaNotFound:
            return "The issuing country's certificate is not in the trust store. Try updating the app."
        case .connectionLost:
            return "The NFC connection was lost. Hold the phone steady against the back cover and try again."
        case .chipAuthenticationRequired:
            return "This passport chip completed a session but could not prove its hardware key. Only passports with Active Authentication or Chip Authentication can be enrolled."
        case .libraryNotLinked:
            return "NFC passport reading is not available in this build."
        case .unknown(let msg):
            return msg
        }
    }
}

// MARK: - Chip data

/// The complete payload extracted from a passport's NFC chip after passive integrity checks.
/// All fields sourced from DG1 (MRZ), read through PACE/BAC when available, and
/// integrity-checked against the SOD before this struct is constructed. Server validation remains
/// authoritative for CSCA/CRL policy and nonce-bound chip proof.
public struct PassportChipData: Sendable {

    // MARK: DG1 / MRZ fields

    /// Document number as it appears in the MRZ (right-padded with '<' to 9 chars on chip).
    public let documentNumber: String
    /// Family name(s) in ICAO MRZ encoding (uppercase, '<'-delimited).
    public let surname: String
    /// Given name(s) in ICAO MRZ encoding.
    public let givenNames: String
    /// ISO 3166-1 alpha-3 nationality code.
    public let nationality: String
    /// ISO 3166-1 alpha-3 issuing state code.
    public let issuingState: String
    /// Date of birth in YYMMDD format.
    public let dateOfBirth: String
    /// Document expiry date in YYMMDD format.
    public let expiryDate: String
    /// "M", "F", or "<" (unspecified / non-binary).
    public let gender: String
    /// TD3 personal number field. Often filler ('<') for US passports.
    public let personalNumber: String?

    // MARK: Authentication

    /// The strongest authentication protocol that succeeded.
    public let authLevel: PassportAuthLevel
    /// True if the SOD signature validated to a trusted CSCA root.
    public let cscaVerified: Bool
    /// True if the Document Signing Certificate itself was verified (subset of cscaVerified chain).
    public let documentSigningCertVerified: Bool
    /// Raw DER-encoded Document Signing Certificate extracted from the SOD.
    /// Nil if the library did not expose the certificate bytes in this build.
    /// Forward to the server for CSCA chain validation against the ICAO PKD Master List —
    /// this is the preferred path: trust store management, CRL updates, and revocation
    /// belong server-side, not in a bundled PEM file that requires an app release to rotate.
    public let documentSigningCertificate: Data?

    // MARK: Active Authentication (anti-replay)

    /// The 8-byte AA challenge the chip signed (ISO 9303 RND.IFD). When the read was nonce-bound,
    /// this equals SHA-256(serverNonce)[0..<8]. Nil if AA did not run. Forward to the server.
    public let activeAuthChallenge: Data?
    /// The chip's AA signature over `activeAuthChallenge`, produced with the chip's private key.
    /// The server verifies it against the DG15 public key to prove this is a live, non-replayed
    /// read of genuine chip hardware. Nil if AA did not run. Forward to the server.
    public let activeAuthSignature: Data?

    // MARK: Raw evidence (server passive authentication)

    /// The raw Security Object Document (SOD/EF.SOD) bytes. The server verifies that each data
    /// group's hash matches the SOD, and that the SOD is signed by the DSC. Nil if not read.
    public let securityObject: Data?
    /// Raw data-group bytes keyed by ICAO name ("DG1", "DG14", "DG15", "COM", …). The server
    /// re-hashes these against the SOD; the AA public key is read from DG15 here. Excludes DG2
    /// (facial image) by policy. Empty if none captured.
    public let dataGroups: [String: Data]

    // MARK: Additional document details (DG11 / DG12 — chip-only, not in the MRZ)

    /// Date of issue (DG12). NOT present in the MRZ — chip-only. Format as parsed by the reader.
    public let dateOfIssue: String?
    /// Full issuing-authority name (DG12, e.g. "U.S. Department of State"). The MRZ only carries the
    /// 3-letter issuing-state code (`issuingState`); this is the human-readable authority.
    public let issuingAuthorityName: String?
    /// Place of birth (DG11). Chip-only; nil if DG11 absent.
    public let placeOfBirth: String?

    // MARK: Convenience

    /// Space-joined given names and surname, with MRZ '<' separators converted to spaces.
    public var fullName: String {
        let g = givenNames.replacingOccurrences(of: "<", with: " ").trimmingCharacters(in: .whitespaces)
        let s = surname.replacingOccurrences(of: "<", with: " ").trimmingCharacters(in: .whitespaces)
        return [g, s].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// True if the chip's active auth or chip auth succeeded — chip is not a data clone.
    public var chipAuthenticated: Bool { authLevel >= .activeAuthenticated }

    /// True if today's date is past the expiry date encoded in the chip.
    public var isExpired: Bool {
        guard expiryDate.count == 6,
              let yy = Int(expiryDate.prefix(2)),
              let mm = Int(expiryDate.dropFirst(2).prefix(2)),
              let dd = Int(expiryDate.suffix(2)) else { return false }
        let year = yy < 70 ? 2000 + yy : 1900 + yy
        var c = DateComponents(); c.year = year; c.month = mm; c.day = dd
        guard let expiry = Calendar.current.date(from: c) else { return false }
        return expiry < Date()
    }

    public init(
        documentNumber: String,
        surname: String,
        givenNames: String,
        nationality: String,
        issuingState: String,
        dateOfBirth: String,
        expiryDate: String,
        gender: String,
        personalNumber: String?,
        authLevel: PassportAuthLevel,
        cscaVerified: Bool,
        documentSigningCertVerified: Bool,
        documentSigningCertificate: Data? = nil,
        activeAuthChallenge: Data? = nil,
        activeAuthSignature: Data? = nil,
        securityObject: Data? = nil,
        dataGroups: [String: Data] = [:],
        dateOfIssue: String? = nil,
        issuingAuthorityName: String? = nil,
        placeOfBirth: String? = nil
    ) {
        self.dateOfIssue = dateOfIssue
        self.issuingAuthorityName = issuingAuthorityName
        self.placeOfBirth = placeOfBirth
        self.documentNumber = documentNumber
        self.surname = surname
        self.givenNames = givenNames
        self.nationality = nationality
        self.issuingState = issuingState
        self.dateOfBirth = dateOfBirth
        self.expiryDate = expiryDate
        self.gender = gender
        self.personalNumber = personalNumber
        self.authLevel = authLevel
        self.cscaVerified = cscaVerified
        self.documentSigningCertVerified = documentSigningCertVerified
        self.documentSigningCertificate = documentSigningCertificate
        self.activeAuthChallenge = activeAuthChallenge
        self.activeAuthSignature = activeAuthSignature
        self.securityObject = securityObject
        self.dataGroups = dataGroups
    }
}

// MARK: - Result

/// Outcome of an NFC passport chip read attempt.
public enum NFCPassportResult: Sendable {
    /// Chip read successfully. `chipData` contains captured evidence for server validation.
    case verified(chipData: PassportChipData)
    /// User cancelled the NFC scan sheet.
    case declined
    /// Device does not support NFC tag reading, or the entitlement is absent.
    case unsupported
    /// Read failed. The associated error describes the specific cause.
    case failed(NFCPassportError)
}

extension NFCPassportResult {
    public func asAttestation() -> PulseNFCPassportAttestation {
        switch self {
        case .verified(let data):
            return PulseNFCPassportAttestation(
                provider: "nfc_passport",
                result: "verified",
                authLevel: data.authLevel.attestationString,
                chipAuthenticated: data.chipAuthenticated,
                cscaVerified: data.cscaVerified,
                documentExpired: data.isExpired,
                nationality: data.nationality.isEmpty ? nil : data.nationality,
                issuingState: data.issuingState.isEmpty ? nil : data.issuingState,
                surname: data.surname.isEmpty ? nil : data.surname,
                givenNames: data.givenNames.isEmpty ? nil : data.givenNames,
                dateOfBirth: data.dateOfBirth.isEmpty ? nil : data.dateOfBirth,
                documentNumber: data.documentNumber.isEmpty ? nil : data.documentNumber,
                // base64EncodedString() with no options uses standard alphabet (+/) with no line breaks —
                // the server must decode as standard Base64 before feeding to an X.509 parser (not Base64URL).
                documentSigningCertificate: data.documentSigningCertificate?.base64EncodedString(),
                failureReason: nil)
        case .declined:
            return PulseNFCPassportAttestation(
                provider: "nfc_passport", result: "declined",
                authLevel: "none", chipAuthenticated: false, cscaVerified: false,
                documentExpired: nil, nationality: nil, issuingState: nil,
                surname: nil, givenNames: nil, dateOfBirth: nil, documentNumber: nil,
                documentSigningCertificate: nil, failureReason: nil)
        case .unsupported:
            return PulseNFCPassportAttestation(
                provider: "nfc_passport", result: "unsupported",
                authLevel: "none", chipAuthenticated: false, cscaVerified: false,
                documentExpired: nil, nationality: nil, issuingState: nil,
                surname: nil, givenNames: nil, dateOfBirth: nil, documentNumber: nil,
                documentSigningCertificate: nil, failureReason: nil)
        case .failed(let error):
            return PulseNFCPassportAttestation(
                provider: "nfc_passport", result: "failed",
                authLevel: "none", chipAuthenticated: false, cscaVerified: false,
                documentExpired: nil, nationality: nil, issuingState: nil,
                surname: nil, givenNames: nil, dateOfBirth: nil, documentNumber: nil,
                documentSigningCertificate: nil, failureReason: error.errorDescription)
        }
    }
}

// MARK: - Client

#if os(iOS) && canImport(CoreNFC) && canImport(NFCPassportReader)
import CoreNFC
import NFCPassportReader

/// Reads an e-passport NFC chip, establishes a PACE or BAC secure session, validates the
/// Document Security Object against bundled CSCA trust anchors, and performs Chip Authentication
/// (DG14) or Active Authentication (DG15) to prove the chip is genuine hardware.
///
/// Data groups read: DG1 (MRZ biographics), DG14 (CA keys), DG15 (AA public key).
/// DG2 (facial image) is intentionally excluded — biometric matching is out of scope.
///
/// Requires:
/// - `com.apple.developer.nfc.readersession.formats` entitlement → `TAG`
/// - `com.apple.developer.nfc.readersession.iso7816.select-identifiers` → `A0000002471001`
/// - NFCPassportReader package (github.com/AndyQ/NFCPassportReader ~> 2.3) linked by this package
public struct NFCPassportClient: Sendable {

    public static var isSupported: Bool {
        NFCTagReaderSession.readingAvailable
    }

    /// File URL of the bundled CSCA master list (PEM). Prefers `csca_all.pem` — the full ICAO PKD
    /// master list (570 CSCAs, ~98 countries) — and falls back to the US-only `csca_us.pem`.
    /// Passive authentication needs this as an OpenSSL CAFile — without it the library cannot
    /// build the SOD→DSC→CSCA chain, so `passportCorrectlySigned` stays false and the read fails.
    public static var bundledMasterListURL: URL? {
        Bundle.main.url(forResource: "csca_all", withExtension: "pem")
            ?? Bundle.main.url(forResource: "csca_us", withExtension: "pem")
    }

    /// PEM-encoded CSCA certificates bundled with the app (raw bytes).
    public static var bundledCSCACertificates: [Data] {
        guard let url = bundledMasterListURL, let pem = try? Data(contentsOf: url) else { return [] }
        return [pem]
    }

    private let masterListURL: URL?

    /// - Parameter masterListURL: CSCA master list PEM used for on-device passive authentication.
    ///   Defaults to the bundled `csca_us.pem`.
    public init(masterListURL: URL? = NFCPassportClient.bundledMasterListURL) {
        self.masterListURL = masterListURL
    }

    /// Back-compat: accept raw CSCA PEM bytes by materializing them to a temp CAFile for OpenSSL.
    public init(cscaCertificates: [Data]) {
        self.masterListURL = NFCPassportClient.materializeMasterList(cscaCertificates)
    }

    private static func materializeMasterList(_ certificates: [Data]) -> URL? {
        guard !certificates.isEmpty else { return nil }
        var joined = Data()
        for cert in certificates {
            joined.append(cert)
            if cert.last != 0x0A { joined.append(0x0A) }   // ensure PEM blocks stay separated
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kenshiki-csca-\(joined.hashValue).pem")
        try? joined.write(to: url)
        return url
    }

    /// ISO 9303 Active Authentication uses an 8-byte challenge (RND.IFD). Bind an arbitrary-length
    /// session nonce to it deterministically: challenge = SHA-256(nonce)[0..<8]. The server applies
    /// the identical derivation to verify the returned AA signature.
    static func deriveAAChallenge(from nonce: Data) -> [UInt8] {
        Array(SHA256.hash(data: nonce).prefix(8))
    }

    /// Read and cryptographically verify a passport chip.
    ///
    /// - Parameters:
    ///   - mrzKey: BAC key derived from the MRZ. Build with
    ///     `MRZKey.compute(documentNumber:dateOfBirth:expiryDate:)`.
    ///   - nonce: Optional server-issued session nonce to bind Active Authentication against
    ///     replay. The 8-byte AA challenge (ISO 9303 RND.IFD) is derived as the first 8 bytes of
    ///     SHA-256(nonce), so the chip signs *this* session. The server re-derives the same 8
    ///     bytes from the nonce and verifies the returned AA signature over them. Pass `nil` to let
    ///     the library use a random challenge (no session binding).
    @MainActor
    public func readPassport(mrzKey: String, nonce: Data? = nil) async -> NFCPassportResult {
        guard Self.isSupported else { return .unsupported }

        let reader = PassportReader(masterListURL: masterListURL)
        do {
            // skipSecureElements: false is mandatory — it drives the Active Authentication (DG15)
            // or Chip Authentication (DG14) challenge-response that exercises the chip's private
            // key. That challenge is the only proof the chip is genuine hardware, not cloned
            // plaintext. If it throws, the chip failed the proof; reject, do not retry without it.
            let aaChallenge = nonce.map { Self.deriveAAChallenge(from: $0) }
            // COM + SOD + the auth-bearing groups. SOD and the raw DG bytes are forwarded so the
            // server can re-hash the groups against the SOD and verify the DSC→SOD signature.
            // DG11 (place of birth) + DG12 (date of issue, full issuing authority) are chip-only
            // details absent from the MRZ — read them so enrollment shows issue date + authority.
            let passport = try await reader.readPassport(
                mrzKey: mrzKey,
                tags: [.COM, .DG1, .DG11, .DG12, .DG14, .DG15, .SOD],
                aaChallenge: aaChallenge,
                skipSecureElements: false)

            guard passport.passportCorrectlySigned else {
                return .failed(.dataIntegrityFailure)
            }

            // Prefer CA (DG14) > AA (DG15) > PACE session > BAC session.
            let authLevel: PassportAuthLevel
            switch (passport.chipAuthenticationStatus, passport.activeAuthenticationPassed, passport.PACEStatus) {
            case (.success, _, _): authLevel = .chipAuthenticated
            case (_, true, _):     authLevel = .activeAuthenticated
            case (_, _, .success): authLevel = .paceAuthenticated
            default:               authLevel = passport.BACStatus == .success ? .basicAccessControl : .none
            }

            // PACE and BAC prove an authenticated session — not chip hardware genuineness.
            // Only AA (DG15) and CA (DG14) exercise chip-held key material. Do not locally reject
            // session-only reads here: the app is only the collector, and the worker/validator is
            // the authoritative judge. A passport without nonce-bound AA evidence will be submitted
            // with active_authentication = null and rejected by server policy instead of being hidden
            // behind a local "try again" loop.

            // Passive authentication now runs on-device against the bundled CSCA master list
            // (PassportReader(masterListURL:)). Two distinct facts come out of it:
            //   passportCorrectlySigned          → DSC chains to a trusted CSCA root (the CSCA leg)
            //   documentSigningCertificateVerified → the DSC actually signed the SOD (the DSC leg)
            // Both still get re-verified server-side; on-device is the fast first gate, the server
            // is the tamper-resistant one (a hostile client can lie about either bool).
            //
            // Extract raw DER-encoded DSC bytes for server-side CSCA chain validation. This library
            // version (NFCPassportReader 2.x) exposes the DSC as an X509Wrapper whose only
            // serialization is certToPEM(); strip the PEM armor and Base64-decode the body back to
            // DER — the exact standard-Base64-of-DER the server decodes and chains against the PKD.
            let dsc: Data? = passport.documentSigningCertificate.flatMap { wrapper in
                let body = wrapper.certToPEM()
                    .split(separator: "\n")
                    .filter { !$0.hasPrefix("-----") }
                    .joined()
                return Data(base64Encoded: body)
            }

            // Active Authentication challenge + signature: the chip signed our nonce-derived
            // challenge with its private key. Forward both so the server can verify the signature
            // over SHA-256(nonce)[0..<8] and reject replays. Empty when AA didn't run.
            let aaChallengeData = passport.activeAuthenticationChallenge.isEmpty
                ? nil : Data(passport.activeAuthenticationChallenge)
            let aaSignatureData = passport.activeAuthenticationSignature.isEmpty
                ? nil : Data(passport.activeAuthenticationSignature)

            // Raw evidence for server-side passive authentication. SOD is pulled out by name;
            // DG2 (facial image) is dropped by policy — it isn't needed to verify identity and
            // is the most sensitive group. Keys use the ICAO short names (DG1, DG14, …).
            var dataGroups: [String: Data] = [:]
            for (id, group) in passport.dataGroupsRead where id != .DG2 {
                dataGroups[id.getName()] = Data(group.data)
            }
            let securityObject = dataGroups["SOD"]

            // The SOD is the keystone of server-side passive authentication: without it the server
            // cannot verify the DG hashes or the DSC→SOD signature. A "verified" read with no SOD
            // is unusable as proof — fail rather than silently submit nil. (DataGroupId.getName()
            // returns "SOD" for .SOD; this guard also catches any future rename of that mapping.)
            guard securityObject != nil else {
                return .failed(.dataIntegrityFailure)
            }

            // DG11/DG12 details, read off the data-group objects directly (DG12's issuing authority
            // uses a different element tag than the MRZ's 5F28, so `issuingState` stays the 3-letter
            // code). All chip-only — absent for chip-less / MRZ paths.
            let dg12 = passport.dataGroupsRead[.DG12] as? DataGroup12
            func nonEmpty(_ s: String?) -> String? { (s?.isEmpty == false) ? s : nil }
            let dateOfIssue = nonEmpty(dg12?.dateOfIssue)
            let issuingAuthorityName = nonEmpty(dg12?.issuingAuthority)
            let placeOfBirth = nonEmpty(passport.placeOfBirth)

            let data = PassportChipData(
                documentNumber: passport.documentNumber,
                surname:        passport.lastName,
                givenNames:     passport.firstName,
                nationality:    passport.nationality,
                issuingState:   passport.issuingAuthority,
                dateOfBirth:    passport.dateOfBirth,
                expiryDate:     passport.documentExpiryDate,
                gender:         passport.gender.isEmpty ? "<" : passport.gender,
                personalNumber: passport.personalNumber.flatMap { $0.isEmpty ? nil : $0 },
                authLevel:      authLevel,
                cscaVerified:   passport.passportCorrectlySigned,
                documentSigningCertVerified: passport.documentSigningCertificateVerified,
                documentSigningCertificate: dsc,
                activeAuthChallenge: aaChallengeData,
                activeAuthSignature: aaSignatureData,
                securityObject: securityObject,
                dataGroups: dataGroups,
                dateOfIssue: dateOfIssue,
                issuingAuthorityName: issuingAuthorityName,
                placeOfBirth: placeOfBirth)

            return .verified(chipData: data)

        } catch NFCPassportReaderError.UserCanceled {
            return .declined
        } catch NFCPassportReaderError.InvalidMRZKey {
            return .failed(.badMRZKey)
        } catch NFCPassportReaderError.NFCNotSupported {
            return .unsupported
        } catch NFCPassportReaderError.NoConnectedTag,
                 NFCPassportReaderError.ConnectionError,
                 NFCPassportReaderError.TimeOutError {
            return .failed(.connectionLost)
        } catch let e as NFCPassportReaderError where Self.isIntegrityError(e) {
            return .failed(.dataIntegrityFailure)
        } catch {
            return .failed(.unknown(error.localizedDescription))
        }
    }

    private static func isIntegrityError(_ e: NFCPassportReaderError) -> Bool {
        let s = "\(e)"
        return s.contains("hash") || s.contains("integrity") || s.contains("tamper")
    }
}
#else
public struct NFCPassportClient: Sendable {
    public static var isSupported: Bool { false }
    public static var bundledMasterListURL: URL? { nil }
    public static var bundledCSCACertificates: [Data] { [] }

    public init(masterListURL: URL? = nil) {}
    public init(cscaCertificates: [Data]) {}

    @MainActor
    public func readPassport(mrzKey: String, nonce: Data? = nil) async -> NFCPassportResult {
        .unsupported
    }
}
#endif

// MARK: - MRZ key derivation

/// Derives the BAC/PACE access key from the three MRZ fields printed on the photo page.
///
/// Format: docNumber(9) + check + DOB(6) + check + expiry(6) + check
/// Document number is right-padded with '<' to 9 characters.
/// Check digits use the ICAO Doc 9303 weighted sum (weights 7, 3, 1) mod 10.
public enum MRZKey {
    public static func compute(documentNumber: String, dateOfBirth: String, expiryDate: String) -> String {
        let doc = pad(documentNumber, to: 9)
        return doc + checkDigit(doc) + dateOfBirth + checkDigit(dateOfBirth) + expiryDate + checkDigit(expiryDate)
    }

    private static func pad(_ s: String, to length: Int) -> String {
        let trimmed = String(s.prefix(length))
        return trimmed + String(repeating: "<", count: max(0, length - trimmed.count))
    }

    private static func checkDigit(_ input: String) -> String {
        let weights = [7, 3, 1]
        var sum = 0
        for (i, ch) in input.enumerated() {
            let value: Int
            if ch == "<"                    { value = 0 }
            else if let n = ch.asciiDigitValue { value = n }
            else if let n = ch.asciiUpperValue { value = n + 10 }
            else                            { value = 0 }
            sum += value * weights[i % 3]
        }
        return String(sum % 10)
    }
}

private extension Character {
    var asciiDigitValue: Int? {
        guard let a = asciiValue, a >= 48, a <= 57 else { return nil }
        return Int(a - 48)
    }
    var asciiUpperValue: Int? {
        guard let a = asciiValue, a >= 65, a <= 90 else { return nil }
        return Int(a - 65)
    }
}
