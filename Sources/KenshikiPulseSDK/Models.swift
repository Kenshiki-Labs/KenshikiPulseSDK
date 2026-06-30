import Foundation

public enum KenshikiPulseConstants {
    public static let sdkVersion = "0.1.0"
    public static let evidenceSchemaVersion = "kenshiki.device.evidence.v0"
    public static let evidenceReceiptSchemaVersion = "kenshiki.device.evidence.receipt.v1"
    public static let deviceRecurrenceSchemaVersion = "kenshiki.device.recurrence.v1"
    public static let verificationSchemaVersion = "kenshiki.existence.verification.v0"
    public static let privacyBoundary = "derived_device_physics_envelope_only"
    public static let appAttestChallengeMetadataKey = "kenshiki_app_attest_challenge"
    public static let requestingPartyMetadataKey = "kenshiki_requesting_party"
    /// UserDefaults key the evidence Merkle ledger persists its leaves under. Exposed so a host app
    /// can back up / migrate the signed continuity chain across devices.
    public static let evidenceMerkleLedgerDefaultsKey = "com.kenshiki.device.evidence.merkle.leaves.v1"
}

public struct KenshikiSessionContext: Codable, Equatable, Sendable {
    public var sessionId: String
    public var applicantId: String?
    public var applicationId: String?
    public var tenantId: String?
    public var metadata: [String: String]

    public init(
        sessionId: String = UUID().uuidString,
        applicantId: String? = nil,
        applicationId: String? = nil,
        tenantId: String? = nil,
        metadata: [String: String] = [:]
    ) {
        self.sessionId = sessionId
        self.applicantId = applicantId
        self.applicationId = applicationId
        self.tenantId = tenantId
        self.metadata = metadata
    }
}

public struct DeviceEvidenceEnvelope: Codable, Equatable, Sendable {
    public var schemaVersion: String
    public var privacyBoundary: String
    public var generatedAt: Date
    public var session: KenshikiSessionContext
    public var collection: DeviceEvidenceCollection
    public var signals: DeviceSignals
    /// Salted, tenant-scoped, rotating device pseudonym (see ``DeviceRecurrence``). Part of the signed
    /// payload — omitted from the wire only when device-recurrence is disabled or consent withholds it.
    public var recurrence: DeviceRecurrenceReceipt?
    public var receipt: EvidenceIntegrityReceipt?

    public init(
        schemaVersion: String = KenshikiPulseConstants.evidenceSchemaVersion,
        privacyBoundary: String = KenshikiPulseConstants.privacyBoundary,
        generatedAt: Date = Date(),
        session: KenshikiSessionContext,
        collection: DeviceEvidenceCollection,
        signals: DeviceSignals,
        recurrence: DeviceRecurrenceReceipt? = nil,
        receipt: EvidenceIntegrityReceipt? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.privacyBoundary = privacyBoundary
        self.generatedAt = generatedAt
        self.session = session
        self.collection = collection
        self.signals = signals
        self.recurrence = recurrence
        self.receipt = receipt
    }
}

/// Wire model for the device recurrence pseudonym. Carries no raw identifier: `current` and `previous`
/// are base64url HMAC tags a relying party indexes on by equality (only the device can produce them).
/// `previous` lets the backend chain across a rotation boundary; see ``DeviceRecurrence``.
public struct DeviceRecurrenceReceipt: Codable, Equatable, Sendable {
    public var schemaVersion: String
    public var algorithm: String
    /// `"tenant"` when bound to a tenant id (cross-tenant unlinkable) or `"install"` when no tenant id
    /// was supplied (single-tenant integrations).
    public var scope: String
    public var epoch: Int
    public var rotationDays: Int
    public var current: String
    public var previous: String

    public init(
        schemaVersion: String = KenshikiPulseConstants.deviceRecurrenceSchemaVersion,
        algorithm: String,
        scope: String,
        epoch: Int,
        rotationDays: Int,
        current: String,
        previous: String
    ) {
        self.schemaVersion = schemaVersion
        self.algorithm = algorithm
        self.scope = scope
        self.epoch = epoch
        self.rotationDays = rotationDays
        self.current = current
        self.previous = previous
    }
}

public struct EvidenceIntegrityReceipt: Codable, Equatable, Sendable {
    public var schemaVersion: String
    public var signedAt: Date
    public var hashAlgorithm: String
    public var canonicalization: String
    public var payloadHash: String
    public var leafHash: String
    public var previousMerkleRoot: String?
    public var merkleRoot: String
    public var merkleLeafIndex: Int
    public var merkleLeafCount: Int
    public var deviceSigning: DeviceSigningReceipt
    public var platformAttestation: PlatformAttestationReceipt

    public init(
        schemaVersion: String = KenshikiPulseConstants.evidenceReceiptSchemaVersion,
        signedAt: Date,
        hashAlgorithm: String = "sha256",
        canonicalization: String = "json.sortedKeys.iso8601millis.receipt_omitted",
        payloadHash: String,
        leafHash: String,
        previousMerkleRoot: String?,
        merkleRoot: String,
        merkleLeafIndex: Int,
        merkleLeafCount: Int,
        deviceSigning: DeviceSigningReceipt,
        platformAttestation: PlatformAttestationReceipt
    ) {
        self.schemaVersion = schemaVersion
        self.signedAt = signedAt
        self.hashAlgorithm = hashAlgorithm
        self.canonicalization = canonicalization
        self.payloadHash = payloadHash
        self.leafHash = leafHash
        self.previousMerkleRoot = previousMerkleRoot
        self.merkleRoot = merkleRoot
        self.merkleLeafIndex = merkleLeafIndex
        self.merkleLeafCount = merkleLeafCount
        self.deviceSigning = deviceSigning
        self.platformAttestation = platformAttestation
    }
}

public struct DeviceSigningReceipt: Codable, Equatable, Sendable {
    public var algorithm: String
    public var keyId: String
    public var publicKey: String
    public var publicKeyHash: String
    public var secureHardware: Bool
    public var signature: String

    public init(
        algorithm: String = "ecdsa-p256-sha256-x962",
        keyId: String,
        publicKey: String,
        publicKeyHash: String,
        secureHardware: Bool,
        signature: String
    ) {
        self.algorithm = algorithm
        self.keyId = keyId
        self.publicKey = publicKey
        self.publicKeyHash = publicKeyHash
        self.secureHardware = secureHardware
        self.signature = signature
    }
}

public struct PlatformAttestationReceipt: Codable, Equatable, Sendable {
    public var provider: String
    public var state: String
    public var environment: String?
    public var keyIdentifier: String?
    public var keyIdentifierHash: String?
    public var clientDataHash: String?
    public var attestationObject: String?
    public var assertionObject: String?
    public var reason: String?

    public init(
        provider: String = "apple_app_attest",
        state: String,
        environment: String? = nil,
        keyIdentifier: String? = nil,
        keyIdentifierHash: String? = nil,
        clientDataHash: String? = nil,
        attestationObject: String? = nil,
        assertionObject: String? = nil,
        reason: String? = nil
    ) {
        self.provider = provider
        self.state = state
        self.environment = environment
        self.keyIdentifier = keyIdentifier
        self.keyIdentifierHash = keyIdentifierHash
        self.clientDataHash = clientDataHash
        self.attestationObject = attestationObject
        self.assertionObject = assertionObject
        self.reason = reason
    }
}

public struct DeviceEvidenceCollection: Codable, Equatable, Sendable {
    public var startedAt: Date
    public var endedAt: Date
    public var durationMilliseconds: Int
    public var sdkVersion: String
    public var consentPolicy: KenshikiConsentPolicy

    public init(
        startedAt: Date,
        endedAt: Date,
        durationMilliseconds: Int,
        sdkVersion: String = KenshikiPulseConstants.sdkVersion,
        consentPolicy: KenshikiConsentPolicy
    ) {
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationMilliseconds = durationMilliseconds
        self.sdkVersion = sdkVersion
        self.consentPolicy = consentPolicy
    }
}

public struct DeviceSignals: Codable, Equatable, Sendable {
    public var battery: BatterySignal
    public var motion: MotionSignal
    public var magnetometer: MagnetometerSignal
    public var barometer: BarometerSignal
    public var ambientLight: AmbientLightSignal
    public var mediaOutput: MediaOutputSignal
    public var displayProjection: DisplayProjectionSignal
    public var connectivity: ConnectivitySignal
    public var bluetooth: BluetoothSignal
    public var deviceSurface: DeviceSurfaceSignal
    public var telephony: TelephonySignal

    public init(
        battery: BatterySignal,
        motion: MotionSignal,
        magnetometer: MagnetometerSignal,
        barometer: BarometerSignal,
        ambientLight: AmbientLightSignal,
        mediaOutput: MediaOutputSignal = MediaOutputSignal(support: SignalSupport(status: .notCollected)),
        displayProjection: DisplayProjectionSignal = DisplayProjectionSignal(support: SignalSupport(status: .notCollected)),
        connectivity: ConnectivitySignal = ConnectivitySignal(support: SignalSupport(status: .notCollected)),
        bluetooth: BluetoothSignal = BluetoothSignal(support: SignalSupport(status: .notCollected)),
        deviceSurface: DeviceSurfaceSignal,
        telephony: TelephonySignal = TelephonySignal(support: SignalSupport(status: .notCollected))
    ) {
        self.battery = battery
        self.motion = motion
        self.magnetometer = magnetometer
        self.barometer = barometer
        self.ambientLight = ambientLight
        self.mediaOutput = mediaOutput
        self.displayProjection = displayProjection
        self.connectivity = connectivity
        self.bluetooth = bluetooth
        self.deviceSurface = deviceSurface
        self.telephony = telephony
    }

    private enum CodingKeys: String, CodingKey {
        case battery, motion, magnetometer, barometer, ambientLight, mediaOutput
        case displayProjection, connectivity, bluetooth, deviceSurface, telephony
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        battery = try container.decode(BatterySignal.self, forKey: .battery)
        motion = try container.decode(MotionSignal.self, forKey: .motion)
        magnetometer = try container.decode(MagnetometerSignal.self, forKey: .magnetometer)
        barometer = try container.decode(BarometerSignal.self, forKey: .barometer)
        ambientLight = try container.decode(AmbientLightSignal.self, forKey: .ambientLight)
        mediaOutput = try container.decodeIfPresent(MediaOutputSignal.self, forKey: .mediaOutput) ??
            MediaOutputSignal(support: SignalSupport(status: .notCollected))
        displayProjection = try container.decodeIfPresent(DisplayProjectionSignal.self, forKey: .displayProjection) ??
            DisplayProjectionSignal(support: SignalSupport(status: .notCollected))
        connectivity = try container.decodeIfPresent(ConnectivitySignal.self, forKey: .connectivity) ??
            ConnectivitySignal(support: SignalSupport(status: .notCollected))
        bluetooth = try container.decodeIfPresent(BluetoothSignal.self, forKey: .bluetooth) ??
            BluetoothSignal(support: SignalSupport(status: .notCollected))
        deviceSurface = try container.decode(DeviceSurfaceSignal.self, forKey: .deviceSurface)
        telephony = try container.decodeIfPresent(TelephonySignal.self, forKey: .telephony) ??
            TelephonySignal(support: SignalSupport(status: .notCollected))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(battery, forKey: .battery)
        try container.encode(motion, forKey: .motion)
        try container.encode(magnetometer, forKey: .magnetometer)
        try container.encode(barometer, forKey: .barometer)
        try container.encode(ambientLight, forKey: .ambientLight)
        try container.encode(mediaOutput, forKey: .mediaOutput)
        try container.encode(displayProjection, forKey: .displayProjection)
        try container.encode(connectivity, forKey: .connectivity)
        try container.encode(bluetooth, forKey: .bluetooth)
        try container.encode(deviceSurface, forKey: .deviceSurface)
        try container.encode(telephony, forKey: .telephony)
    }
}

public enum SignalSupportStatus: String, Codable, Equatable, Sendable {
    case available
    case unavailable
    case notSupportedByPlatform = "not_supported_by_platform"
    case disabledByConfiguration = "disabled_by_configuration"
    case notCollected = "not_collected"
}

public struct SignalSupport: Codable, Equatable, Sendable {
    public var status: SignalSupportStatus
    public var reason: String?

    public init(status: SignalSupportStatus, reason: String? = nil) {
        self.status = status
        self.reason = reason
    }
}

public struct BatterySignal: Codable, Equatable, Sendable {
    public var support: SignalSupport
    public var level: Double?
    public var state: String?
    public var thermalState: String?
    public var lowPowerModeEnabled: Bool?

    public init(
        support: SignalSupport,
        level: Double? = nil,
        state: String? = nil,
        thermalState: String? = nil,
        lowPowerModeEnabled: Bool? = nil
    ) {
        self.support = support
        self.level = level
        self.state = state
        self.thermalState = thermalState
        self.lowPowerModeEnabled = lowPowerModeEnabled
    }
}

public struct MotionSignal: Codable, Equatable, Sendable {
    public var support: SignalSupport
    public var sampleCount: Int
    public var userAccelerationMagnitude: Double?
    public var rotationRateMagnitude: Double?
    public var gravityMagnitude: Double?

    public init(
        support: SignalSupport,
        sampleCount: Int = 0,
        userAccelerationMagnitude: Double? = nil,
        rotationRateMagnitude: Double? = nil,
        gravityMagnitude: Double? = nil
    ) {
        self.support = support
        self.sampleCount = sampleCount
        self.userAccelerationMagnitude = userAccelerationMagnitude
        self.rotationRateMagnitude = rotationRateMagnitude
        self.gravityMagnitude = gravityMagnitude
    }
}

public struct MagnetometerSignal: Codable, Equatable, Sendable {
    public var support: SignalSupport
    public var sampleCount: Int
    public var fieldMagnitudeMicrotesla: Double?
    public var calibrationAccuracy: String?

    public init(
        support: SignalSupport,
        sampleCount: Int = 0,
        fieldMagnitudeMicrotesla: Double? = nil,
        calibrationAccuracy: String? = nil
    ) {
        self.support = support
        self.sampleCount = sampleCount
        self.fieldMagnitudeMicrotesla = fieldMagnitudeMicrotesla
        self.calibrationAccuracy = calibrationAccuracy
    }
}

public struct BarometerSignal: Codable, Equatable, Sendable {
    public var support: SignalSupport
    public var relativeAltitudeMeters: Double?
    public var pressureKilopascals: Double?

    public init(
        support: SignalSupport,
        relativeAltitudeMeters: Double? = nil,
        pressureKilopascals: Double? = nil
    ) {
        self.support = support
        self.relativeAltitudeMeters = relativeAltitudeMeters
        self.pressureKilopascals = pressureKilopascals
    }
}

public struct AmbientLightSignal: Codable, Equatable, Sendable {
    public var support: SignalSupport
    public var screenBrightnessLevel: Double?
    public var proxySource: String?
    public var brightnessBand: String?
    public var brightnessBandChangeCount: Int?

    public init(
        support: SignalSupport,
        screenBrightnessLevel: Double? = nil,
        proxySource: String? = nil,
        brightnessBand: String? = nil,
        brightnessBandChangeCount: Int? = nil
    ) {
        self.support = support
        self.screenBrightnessLevel = screenBrightnessLevel
        self.proxySource = proxySource
        self.brightnessBand = brightnessBand
        self.brightnessBandChangeCount = brightnessBandChangeCount
    }
}

/// Privacy-safe media-output context. This stores only the output route class and booleans:
/// no audio content, device names, song/app names, microphone samples, or route identifiers.
public struct MediaOutputSignal: Codable, Equatable, Sendable {
    public var support: SignalSupport
    public var routeClass: String?
    public var external: Bool?
    public var otherAudioPlaying: Bool?
    public var routeChangeCount: Int?
    public var externalRouteChangeCount: Int?

    public init(
        support: SignalSupport,
        routeClass: String? = nil,
        external: Bool? = nil,
        otherAudioPlaying: Bool? = nil,
        routeChangeCount: Int? = nil,
        externalRouteChangeCount: Int? = nil
    ) {
        self.support = support
        self.routeClass = routeClass
        self.external = external
        self.otherAudioPlaying = otherAudioPlaying
        self.routeChangeCount = routeChangeCount
        self.externalRouteChangeCount = externalRouteChangeCount
    }
}

/// Privacy-safe display-projection context. This stores only whether the screen is captured
/// or using an external display class; no screen contents, window titles, or display names.
public struct DisplayProjectionSignal: Codable, Equatable, Sendable {
    public var support: SignalSupport
    public var screenCaptured: Bool?
    public var externalDisplayCount: Int?
    public var projectionStatus: String?
    public var projectionChangeCount: Int?
    public var captureChangeCount: Int?

    public init(
        support: SignalSupport,
        screenCaptured: Bool? = nil,
        externalDisplayCount: Int? = nil,
        projectionStatus: String? = nil,
        projectionChangeCount: Int? = nil,
        captureChangeCount: Int? = nil
    ) {
        self.support = support
        self.screenCaptured = screenCaptured
        self.externalDisplayCount = externalDisplayCount
        self.projectionStatus = projectionStatus
        self.projectionChangeCount = projectionChangeCount
        self.captureChangeCount = captureChangeCount
    }
}

/// Privacy-safe network path snapshot. This intentionally does not include SSID,
/// BSSID, IP address, DNS server, carrier, tower, RF strength, or nearby networks.
public struct ConnectivitySignal: Codable, Equatable, Sendable {
    public var support: SignalSupport
    public var pathStatus: String?
    public var unsatisfiedReason: String?
    public var interfaceTypes: [String]
    public var availableInterfaceTypes: [String]
    public var perInterfacePathStatuses: [String: String]
    public var expensive: Bool?
    public var constrained: Bool?
    public var supportsDNS: Bool?
    public var supportsIPv4: Bool?
    public var supportsIPv6: Bool?
    /// Number of network gateways visible on the current path (derived from `NWPath.gateways`).
    public var gatewayCount: Int?
    /// Number of interfaces available on the current path (derived from `NWPath.availableInterfaces`).
    public var availableInterfaceCount: Int?
    /// Privacy-preserving Wi-Fi network-continuity token: a per-device *salted hash* of the current
    /// BSSID. Proves "same Wi-Fi as prior check-ins" without revealing the network, and cannot be
    /// correlated across devices. `nil` when not on Wi-Fi / no `wifi-info` entitlement / no location
    /// authorization. A change is a stability/coherence input, not a continuity break. See `WifiNetworkIdentity`.
    public var wifiNetworkHash: String?
    /// Coarse familiarity of the current Wi-Fi network, judged only from this device's own token history:
    /// new / known / familiar / unknown. This is the continuity-relevant band derived from
    /// `wifiNetworkHash`; the raw token stays local, only the band is meant to be exported. See
    /// `NetworkFamiliarity` / `KnownNetworkStore`.
    public var wifiFamiliarity: String?

    public init(
        support: SignalSupport,
        pathStatus: String? = nil,
        unsatisfiedReason: String? = nil,
        interfaceTypes: [String] = [],
        availableInterfaceTypes: [String] = [],
        perInterfacePathStatuses: [String: String] = [:],
        expensive: Bool? = nil,
        constrained: Bool? = nil,
        supportsDNS: Bool? = nil,
        supportsIPv4: Bool? = nil,
        supportsIPv6: Bool? = nil,
        gatewayCount: Int? = nil,
        availableInterfaceCount: Int? = nil,
        wifiNetworkHash: String? = nil,
        wifiFamiliarity: String? = nil
    ) {
        self.support = support
        self.pathStatus = pathStatus
        self.unsatisfiedReason = unsatisfiedReason
        self.interfaceTypes = interfaceTypes
        self.availableInterfaceTypes = availableInterfaceTypes
        self.perInterfacePathStatuses = perInterfacePathStatuses
        self.expensive = expensive
        self.constrained = constrained
        self.supportsDNS = supportsDNS
        self.supportsIPv4 = supportsIPv4
        self.supportsIPv6 = supportsIPv6
        self.gatewayCount = gatewayCount
        self.availableInterfaceCount = availableInterfaceCount
        self.wifiNetworkHash = wifiNetworkHash
        self.wifiFamiliarity = wifiFamiliarity
    }
}

/// Privacy-safe Bluetooth/accessory radio context. This stores only CoreBluetooth authorization/state
/// and the coarse Bluetooth audio route class; it never includes peripheral names, UUIDs,
/// advertisements, MAC addresses, manufacturer data, or nearby-device scans.
public struct BluetoothSignal: Codable, Equatable, Sendable {
    public var support: SignalSupport
    /// CoreBluetooth authorization: allowed, denied, restricted, not_determined, or unavailable.
    public var authorization: String?
    /// CoreBluetooth central state: powered_on, powered_off, unauthorized, unsupported, resetting,
    /// unknown, or unavailable.
    public var radioState: String?
    /// Whether Bluetooth scanning would be possible from the current authorization/radio state. This
    /// is a capability bucket only; Kenshiki does not scan nearby devices by default.
    public var scanAvailable: Bool?
    /// Coarse audio route class when a Bluetooth output is active: bluetooth, car, or none.
    public var audioRouteClass: String?
    /// Whether the current audio route is a Bluetooth-backed route. No route names or identifiers.
    public var audioRouteConnected: Bool?
    /// Count of coarse Bluetooth audio route class changes observed on this install. This is a
    /// connect/disconnect rhythm bucket, not a device identity or pairing log.
    public var audioRouteChangeCount: Int?

    public init(
        support: SignalSupport,
        authorization: String? = nil,
        radioState: String? = nil,
        scanAvailable: Bool? = nil,
        audioRouteClass: String? = nil,
        audioRouteConnected: Bool? = nil,
        audioRouteChangeCount: Int? = nil
    ) {
        self.support = support
        self.authorization = authorization
        self.radioState = radioState
        self.scanAvailable = scanAvailable
        self.audioRouteClass = audioRouteClass
        self.audioRouteConnected = audioRouteConnected
        self.audioRouteChangeCount = audioRouteChangeCount
    }
}

public struct DeviceSurfaceSignal: Codable, Equatable, Sendable {
    public var support: SignalSupport
    public var platform: String
    public var systemName: String
    public var systemMajorVersion: Int?
    public var interfaceIdiom: String?
    public var bundleIdentifier: String?
    public var simulator: Bool

    public init(
        support: SignalSupport,
        platform: String,
        systemName: String,
        systemMajorVersion: Int? = nil,
        interfaceIdiom: String? = nil,
        bundleIdentifier: String? = nil,
        simulator: Bool
    ) {
        self.support = support
        self.platform = platform
        self.systemName = systemName
        self.systemMajorVersion = systemMajorVersion
        self.interfaceIdiom = interfaceIdiom
        self.bundleIdentifier = bundleIdentifier
        self.simulator = simulator
    }
}

/// Telephony / radio snapshot. iOS exposes no cell-tower, signal-strength, baseband,
/// IMEI, carrier identity, or ICCID to third-party apps, so this is deliberately coarse:
/// radio-access generation, carrier-descriptor SIM presence, and cellular-data state only.
public struct TelephonySignal: Codable, Equatable, Sendable {
    public var support: SignalSupport
    /// Whether a SIM matching the app's Info.plist carrier descriptors (MCC/MNC/GIDs)
    /// is inserted (iOS 18+). Carrier-descriptor-scoped — for a non-carrier app this is
    /// of limited value (see calibration plan §2.16). `nil` when unknown/unavailable.
    public var simInserted: Bool?
    /// Coarse radio-access generations currently in use, e.g. `["4g"]`, `["5g"]`.
    /// Derived from `serviceCurrentRadioAccessTechnology`; no tower/baseband detail exists on iOS.
    public var radioGenerations: [String]
    /// Count of service slots visible through CoreTelephony. This is a count only, never a raw service
    /// identifier, carrier, MCC/MNC, phone number, or account identifier.
    public var serviceCount: Int?
    /// Visibility state for radio evidence: `"visible"` when RAT is exposed, `"hidden_by_ios"` when
    /// other service evidence exists but RAT is withheld, or `"not_observed"`.
    public var radioVisibility: String?
    /// Cellular-data permission state: `"restricted"` | `"not_restricted"` | `"unknown"`.
    public var cellularDataRestricted: String?
    /// Whether CoreTelephony exposed a current data-service key. The key itself is local-only and is
    /// never signed or exported.
    public var dataServiceAvailable: Bool?
    /// Count of observed data-service-key changes, derived from a device-local salted token. The raw
    /// service identifier is never persisted or exported.
    public var dataServiceChangeCount: Int?
    /// Content-free call activity observed by the host app via CallKit. This is an
    /// aggregate occurrence count only: no phone numbers, contacts, direction, audio,
    /// call history, or per-call log is stored.
    public var callEventCount: Int?
    /// Most recent call-state occurrence observed while the app process was alive.
    public var lastCallEventAt: Date?
    /// Current active-call count from CallKit at observation time. This is a live state,
    /// not a stored call record.
    public var activeCallCount: Int?
    /// Current connected-call aggregate from CallKit at observation time. No call UUIDs,
    /// direction, numbers, contacts, audio, or per-call records are stored.
    public var connectedCallCount: Int?
    /// Current held-call aggregate from CallKit at observation time.
    public var heldCallCount: Int?
    /// When the host app last started the CallKit observer. Useful for coverage/freshness.
    public var callObserverStartedAt: Date?
    /// Seconds since the CallKit observer started, capped at collection time. This is coverage
    /// metadata, not a call-history duration.
    public var callObserverCoverageSeconds: Int?

    public init(
        support: SignalSupport,
        simInserted: Bool? = nil,
        radioGenerations: [String] = [],
        serviceCount: Int? = nil,
        radioVisibility: String? = nil,
        cellularDataRestricted: String? = nil,
        dataServiceAvailable: Bool? = nil,
        dataServiceChangeCount: Int? = nil,
        callEventCount: Int? = nil,
        lastCallEventAt: Date? = nil,
        activeCallCount: Int? = nil,
        connectedCallCount: Int? = nil,
        heldCallCount: Int? = nil,
        callObserverStartedAt: Date? = nil,
        callObserverCoverageSeconds: Int? = nil
    ) {
        self.support = support
        self.simInserted = simInserted
        self.radioGenerations = radioGenerations
        self.serviceCount = serviceCount
        self.radioVisibility = radioVisibility
        self.cellularDataRestricted = cellularDataRestricted
        self.dataServiceAvailable = dataServiceAvailable
        self.dataServiceChangeCount = dataServiceChangeCount
        self.callEventCount = callEventCount
        self.lastCallEventAt = lastCallEventAt
        self.activeCallCount = activeCallCount
        self.connectedCallCount = connectedCallCount
        self.heldCallCount = heldCallCount
        self.callObserverStartedAt = callObserverStartedAt
        self.callObserverCoverageSeconds = callObserverCoverageSeconds
    }
}

public struct ExistenceVerificationRequest: Codable, Equatable, Sendable {
    public var schemaVersion: String
    public var requestedAt: Date
    public var evidence: DeviceEvidenceEnvelope

    public init(
        schemaVersion: String = KenshikiPulseConstants.verificationSchemaVersion,
        requestedAt: Date = Date(),
        evidence: DeviceEvidenceEnvelope
    ) {
        self.schemaVersion = schemaVersion
        self.requestedAt = requestedAt
        self.evidence = evidence
    }
}

public struct ExistenceVerificationResult: Codable, Equatable, Sendable {
    public var requestId: String?
    public var decision: String
    public var confidence: Double?
    public var reasons: [String]
    public var receivedAt: Date?

    public init(
        requestId: String? = nil,
        decision: String,
        confidence: Double? = nil,
        reasons: [String] = [],
        receivedAt: Date? = nil
    ) {
        self.requestId = requestId
        self.decision = decision
        self.confidence = confidence
        self.reasons = reasons
        self.receivedAt = receivedAt
    }
}
