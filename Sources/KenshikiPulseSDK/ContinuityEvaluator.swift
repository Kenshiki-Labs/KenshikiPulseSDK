import Foundation

/// Stable-signal fingerprint for break detection — derived from the signed `DeviceSignals`, excluding
/// noisy fields (radio generation, OS minor) that move during normal use.
public struct DeviceFingerprint: Codable, Equatable, Sendable {
    public var platform: String
    public var systemMajor: Int?
    public var idiom: String?
    public var simInserted: Bool?
    public var cellularRestricted: String?
    /// Privacy-preserving Wi-Fi network-continuity token (see `WifiNetworkIdentity`). Carried here so
    /// successive check-ins can detect "same primary network as before". Deliberately **not** part of
    /// break detection — a network change is normal and never resets continuity.
    public var wifiNetworkHash: String?

    public init(from signals: DeviceSignals) {
        platform = signals.deviceSurface.platform
        systemMajor = signals.deviceSurface.systemMajorVersion
        idiom = signals.deviceSurface.interfaceIdiom
        simInserted = signals.telephony.simInserted
        cellularRestricted = signals.telephony.cellularDataRestricted
        wifiNetworkHash = signals.connectivity.wifiNetworkHash
    }
}

/// Whether the device's primary Wi-Fi network is the same as the prior check-in. `unknown` when either
/// side has no token (off Wi-Fi / no entitlement / first check-in) — absence is not evidence.
public enum NetworkStability: String, Codable, Equatable, Sendable {
    case stable     // same network-continuity token as last check-in
    case changed    // a different known network
    case unknown    // no token on one or both sides
}

/// Why continuity broke between two check-ins. Reason code only — host apps supply display copy.
public enum ContinuityBreakReason: String, Codable, Equatable, Sendable {
    case deviceChange = "device_change"
    case simSwap = "sim_swap"
}

/// Result of evaluating one check-in's signals against the prior fingerprint.
public struct ContinuityEvaluation: Equatable, Sendable {
    public static let possibleProofSignalCount = ContinuityEvidenceLane.proofLanes.count

    /// Eligible proof channels for this check-in. A value is present only when the channel's
    /// `SignalSupport.status` is `.available`; user-denied, platform-unsupported, disabled, or
    /// intentionally uncollected channels are unavailable context, not negative evidence.
    public let proofSignals: [Bool]
    /// Total proof lanes the current SDK knows how to evaluate. This is not the coverage denominator;
    /// it is used to discount confidence when the user/device/app made many lanes unavailable.
    public let proofSignalsPossible: Int
    public let breakReason: ContinuityBreakReason?
    public let networkStability: NetworkStability
    /// Canonical, explainable evidence state for every known lane.
    public let evidenceSnapshot: ContinuityEvidenceSnapshot
    public let explanation: ContinuityExplanation

    public var signalsTotal: Int { proofSignals.count }
    public var signalsLive: Int { proofSignals.filter { $0 }.count }
    public var evidenceBreadth: Double { evidenceSnapshot.evidenceBreadth }

    /// Live-corroboration multiplier for `ContinuityModel` (0…1). Stable/unknown networks are neutral;
    /// a *changed* primary network applies a shallow, capped dip — a soft signal, never a break.
    public var coherence: Double {
        switch networkStability {
        case .stable, .unknown: return 1.0
        case .changed: return ContinuityModel.networkChangeCoherence
        }
    }

    public init(proofSignals: [Bool], proofSignalsPossible: Int = Self.possibleProofSignalCount,
                breakReason: ContinuityBreakReason?,
                networkStability: NetworkStability = .unknown,
                evidenceSnapshot: ContinuityEvidenceSnapshot? = nil,
                explanation: ContinuityExplanation? = nil) {
        self.proofSignals = proofSignals
        self.proofSignalsPossible = proofSignalsPossible
        self.breakReason = breakReason
        self.networkStability = networkStability
        let snapshot = evidenceSnapshot ??
            ContinuityEvidenceSnapshot.synthesized(fromProofSignals: proofSignals,
                                                   possibleLaneCount: proofSignalsPossible)
        self.evidenceSnapshot = snapshot
        self.explanation = explanation ?? ContinuityExplanation(snapshot: snapshot,
                                                                breakReason: breakReason,
                                                                networkStability: networkStability)
    }
}

/// Machine-readable explanation beside every continuity evaluation.
public struct ContinuityExplanation: Equatable, Sendable {
    public let contributingLanes: [ContinuityEvidenceLane]
    public let emptyLanes: [ContinuityEvidenceLane]
    public let unavailableLanes: [ContinuityEvidenceLane]
    public let staleLanes: [ContinuityEvidenceLane]
    public let contradictoryLanes: [ContinuityEvidenceLane]
    public let breakReason: ContinuityBreakReason?
    public let networkStability: NetworkStability

    public init(snapshot: ContinuityEvidenceSnapshot,
                breakReason: ContinuityBreakReason?,
                networkStability: NetworkStability) {
        contributingLanes = Self.lanes(in: snapshot, where: .observed)
        emptyLanes = Self.lanes(in: snapshot, where: .empty)
        unavailableLanes = Self.lanes(in: snapshot, where: .unavailable)
        staleLanes = Self.lanes(in: snapshot, where: .stale)
        contradictoryLanes = Self.lanes(in: snapshot, where: .contradictory)
        self.breakReason = breakReason
        self.networkStability = networkStability
    }

    private static func lanes(in snapshot: ContinuityEvidenceSnapshot,
                              where state: ContinuityEvidenceState) -> [ContinuityEvidenceLane] {
        snapshot.points.compactMap { $0.state == state ? $0.lane : nil }
    }
}

/// Pure, deterministic continuity evaluation over the signed `DeviceSignals`: per-signal proof
/// coverage + stable-fingerprint break detection. No app/UI dependencies.
public enum ContinuityEvaluator {
    public static let defaultFreshnessWindow: TimeInterval = 72 * 60 * 60

    public static func evaluate(signals: DeviceSignals, previous: DeviceFingerprint?) -> ContinuityEvaluation {
        evaluate(signals: signals, previous: previous, collectedAt: nil, now: nil)
    }

    public static func evaluate(signals: DeviceSignals,
                                previous: DeviceFingerprint?,
                                collectedAt: Date?,
                                now: Date?,
                                freshnessWindow: TimeInterval = defaultFreshnessWindow) -> ContinuityEvaluation {
        let current = DeviceFingerprint(from: signals)
        let evidence = evidenceSnapshot(from: signals,
                                        collectedAt: collectedAt,
                                        now: now,
                                        freshnessWindow: freshnessWindow)
        let networkStability = networkStability(previous: previous, current: current)
        let breakReason = detectBreak(previous: previous, current: current)
        return ContinuityEvaluation(
            proofSignals: proofSignals(from: evidence),
            breakReason: breakReason,
            networkStability: networkStability,
            evidenceSnapshot: evidence,
            explanation: ContinuityExplanation(snapshot: evidence,
                                               breakReason: breakReason,
                                               networkStability: networkStability)
        )
    }

    /// Same primary Wi-Fi network as the prior check-in? Pure; not part of break detection.
    public static func networkStability(previous: DeviceFingerprint?, current: DeviceFingerprint) -> NetworkStability {
        guard let prev = previous?.wifiNetworkHash, let cur = current.wifiNetworkHash else { return .unknown }
        return prev == cur ? .stable : .changed
    }

    public static func detectBreak(previous: DeviceFingerprint?, current: DeviceFingerprint) -> ContinuityBreakReason? {
        guard let previous else { return nil }
        if previous.platform != current.platform || previous.idiom != current.idiom {
            return .deviceChange
        }
        if let previousSIM = previous.simInserted,
           let currentSIM = current.simInserted,
           previousSIM != currentSIM {
            return .simSwap
        }
        return nil
    }

    public static func proofSignals(from signals: DeviceSignals) -> [Bool] {
        proofSignals(from: evidenceSnapshot(from: signals))
    }

    public static func proofSignals(from snapshot: ContinuityEvidenceSnapshot) -> [Bool] {
        let proofLanes = Set(ContinuityEvidenceLane.proofLanes)
        return snapshot.points.compactMap { point -> Bool? in
            guard proofLanes.contains(point.lane) else { return nil }
            return point.isEligible ? point.isLive : nil
        }
    }

    public static func evidenceSnapshot(from signals: DeviceSignals) -> ContinuityEvidenceSnapshot {
        evidenceSnapshot(from: signals, collectedAt: nil, now: nil)
    }

    public static func evidenceSnapshot(from signals: DeviceSignals,
                                        collectedAt: Date?,
                                        now: Date?,
                                        freshnessWindow: TimeInterval = defaultFreshnessWindow) -> ContinuityEvidenceSnapshot {
        let batteryHasSample = signals.battery.support.status == .available && (
            finite(signals.battery.level) ||
            signals.battery.state != nil ||
            signals.battery.thermalState != nil ||
            signals.battery.lowPowerModeEnabled != nil
        )
        let motionHasSample = signals.motion.support.status == .available && signals.motion.sampleCount > 0 && (
            finite(signals.motion.userAccelerationMagnitude) ||
            finite(signals.motion.rotationRateMagnitude) ||
            finite(signals.motion.gravityMagnitude)
        )
        let magnetometerHasSample = signals.magnetometer.support.status == .available &&
            signals.magnetometer.sampleCount > 0 &&
            finite(signals.magnetometer.fieldMagnitudeMicrotesla) &&
            signals.magnetometer.calibrationAccuracy != "uncalibrated"
        let barometerHasSample = signals.barometer.support.status == .available && (
            finite(signals.barometer.relativeAltitudeMeters) || finite(signals.barometer.pressureKilopascals)
        )
        let ambientLightHasSample = signals.ambientLight.support.status == .available && (
            finite(signals.ambientLight.screenBrightnessLevel) || signals.ambientLight.proxySource != nil
        )
        let telephonyHasSample = signals.telephony.support.status == .available && (
            !signals.telephony.radioGenerations.isEmpty ||
            (signals.telephony.serviceCount ?? 0) > 0 ||
            signals.telephony.radioVisibility == "visible" ||
            signals.telephony.radioVisibility == "hidden_by_ios" ||
            signals.telephony.simInserted != nil ||
            signals.telephony.dataServiceAvailable == true ||
            (signals.telephony.dataServiceChangeCount ?? 0) > 0 ||
            (signals.telephony.cellularDataRestricted != nil && signals.telephony.cellularDataRestricted != "unknown") ||
            (signals.telephony.callEventCount ?? 0) > 0 ||
            signals.telephony.activeCallCount != nil ||
            signals.telephony.connectedCallCount != nil ||
            signals.telephony.heldCallCount != nil ||
            signals.telephony.callObserverStartedAt != nil
        )
        let connectivityHasSample = signals.connectivity.support.status == .available &&
            signals.connectivity.pathStatus == "satisfied" &&
            !signals.connectivity.interfaceTypes.isEmpty
        let bluetoothEligible = signals.bluetooth.support.status == .available && (
            !isDeniedBluetoothAuthorization(signals.bluetooth.authorization) ||
            signals.bluetooth.audioRouteConnected == true ||
            signals.bluetooth.audioRouteClass?.isEmpty == false && signals.bluetooth.audioRouteClass != "none"
        )
        let bluetoothHasSample = bluetoothEligible && (
            signals.bluetooth.radioState != nil ||
            signals.bluetooth.scanAvailable != nil ||
            signals.bluetooth.audioRouteClass != nil ||
            signals.bluetooth.audioRouteConnected != nil ||
            signals.bluetooth.audioRouteChangeCount != nil
        )
        let mediaOutputHasSample = signals.mediaOutput.support.status == .available && (
            signals.mediaOutput.routeClass?.isEmpty == false ||
            signals.mediaOutput.external != nil ||
            signals.mediaOutput.otherAudioPlaying != nil
        )
        let displayProjectionHasSample = signals.displayProjection.support.status == .available && (
            signals.displayProjection.screenCaptured != nil ||
            signals.displayProjection.externalDisplayCount != nil ||
            signals.displayProjection.projectionStatus != nil
        )
        let deviceSurfaceHasSample = signals.deviceSurface.support.status == .available &&
            !signals.deviceSurface.platform.isEmpty &&
            !signals.deviceSurface.systemName.isEmpty

        let telephonyContradiction = signals.telephony.support.status == .available &&
            signals.telephony.simInserted == false &&
            (!signals.telephony.radioGenerations.isEmpty ||
             (signals.telephony.serviceCount ?? 0) > 0 ||
             signals.telephony.dataServiceAvailable == true)
        let bluetoothContradiction = signals.bluetooth.support.status == .available &&
            ((signals.bluetooth.audioRouteConnected == true && signals.bluetooth.audioRouteClass == "none") ||
             (signals.bluetooth.audioRouteConnected == false &&
              (signals.bluetooth.audioRouteClass == "bluetooth" || signals.bluetooth.audioRouteClass == "car")))

        let snapshot = ContinuityEvidenceSnapshot(points: [
            point(.battery, support: signals.battery.support, observed: batteryHasSample),
            point(.motion, support: signals.motion.support, observed: motionHasSample),
            point(.magnetometer, support: signals.magnetometer.support, observed: magnetometerHasSample),
            point(.barometer, support: signals.barometer.support, observed: barometerHasSample),
            point(.ambientLight, support: signals.ambientLight.support, observed: ambientLightHasSample),
            point(.telephony,
                  support: signals.telephony.support,
                  observed: telephonyHasSample,
                  contradictory: telephonyContradiction,
                  contradictionReason: "sim_absent_with_radio_evidence"),
            point(.connectivity, support: signals.connectivity.support, observed: connectivityHasSample),
            bluetoothPoint(signals.bluetooth,
                           eligible: bluetoothEligible,
                           observed: bluetoothHasSample,
                           contradictory: bluetoothContradiction),
            point(.mediaOutput, support: signals.mediaOutput.support, observed: mediaOutputHasSample),
            point(.displayProjection, support: signals.displayProjection.support, observed: displayProjectionHasSample),
            point(.deviceSurface, support: signals.deviceSurface.support, observed: deviceSurfaceHasSample)
        ])

        guard let collectedAt, let now, now.timeIntervalSince(collectedAt) > freshnessWindow else {
            return snapshot
        }
        return snapshot.markingObservedStale(reason: "snapshot_outside_freshness_window")
    }

    private static func finite(_ value: Double?) -> Bool {
        value?.isFinite == true
    }

    private static func point(_ lane: ContinuityEvidenceLane,
                              support: SignalSupport,
                              observed: Bool,
                              contradictory: Bool = false,
                              contradictionReason: String? = nil) -> ContinuityEvidencePoint {
        guard support.status == .available else {
            return ContinuityEvidencePoint(lane: lane,
                                           state: .unavailable,
                                           supportStatus: support.status,
                                           reason: support.reason)
        }
        if contradictory {
            return ContinuityEvidencePoint(lane: lane,
                                           state: .contradictory,
                                           supportStatus: support.status,
                                           reason: contradictionReason ?? support.reason)
        }
        return ContinuityEvidencePoint(lane: lane,
                                       state: observed ? .observed : .empty,
                                       supportStatus: support.status,
                                       reason: support.reason)
    }

    private static func bluetoothPoint(_ signal: BluetoothSignal,
                                       eligible: Bool,
                                       observed: Bool,
                                       contradictory: Bool = false) -> ContinuityEvidencePoint {
        if signal.support.status != .available || !eligible {
            let reason = signal.support.reason ??
                (isDeniedBluetoothAuthorization(signal.authorization) ? "bluetooth_denied_without_route" : nil)
            return ContinuityEvidencePoint(lane: .bluetooth,
                                           state: .unavailable,
                                           supportStatus: signal.support.status,
                                           reason: reason)
        }
        if contradictory {
            return ContinuityEvidencePoint(lane: .bluetooth,
                                           state: .contradictory,
                                           supportStatus: signal.support.status,
                                           reason: "bluetooth_route_state_conflict")
        }
        return ContinuityEvidencePoint(lane: .bluetooth,
                                       state: observed ? .observed : .empty,
                                       supportStatus: signal.support.status,
                                       reason: signal.support.reason)
    }

    private static func isDeniedBluetoothAuthorization(_ value: String?) -> Bool {
        value == "denied" || value == "restricted"
    }
}
