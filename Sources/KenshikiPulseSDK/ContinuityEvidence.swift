/// Canonical continuity evidence lanes known to the SDK and host app.
///
/// The signed SDK proof model uses `proofLanes`. Product surfaces may also use app-only lanes
/// such as place/focus when explaining Live/Now and Day history. Adding an app-only lane must not
/// change proof scoring denominators.
public enum ContinuityEvidenceLane: String, Codable, CaseIterable, Equatable, Sendable {
    case battery
    case motion
    case magnetometer
    case barometer
    case ambientLight = "ambient_light"
    case telephony
    case connectivity
    case bluetooth
    case trustedBLEWitness = "trusted_ble_witness"
    case mediaOutput = "media_output"
    case displayProjection = "display_projection"
    case deviceSurface = "device_surface"
    case place
    case focus
    case interaction

    public var group: ContinuityEvidenceGroup {
        switch self {
        case .battery:
            return .power
        case .motion, .barometer:
            return .movement
        case .magnetometer, .ambientLight, .trustedBLEWitness:
            return .deviceEnvironment
        case .telephony, .connectivity, .bluetooth:
            return .network
        case .mediaOutput, .displayProjection:
            return .attention
        case .deviceSurface:
            return .deviceSurface
        case .place:
            return .place
        case .focus, .interaction:
            return .interaction
        }
    }

    public static let proofLanes: [ContinuityEvidenceLane] = [
        .battery,
        .motion,
        .magnetometer,
        .barometer,
        .ambientLight,
        .telephony,
        .connectivity,
        .bluetooth,
        .mediaOutput,
        .displayProjection,
        .deviceSurface
    ]
}

/// Coarse groups used to avoid pretending correlated lanes are independent witnesses.
public enum ContinuityEvidenceGroup: String, Codable, CaseIterable, Equatable, Sendable {
    case power
    case movement
    case deviceEnvironment = "device_environment"
    case network
    case attention
    case deviceSurface = "device_surface"
    case place
    case interaction

    public static let proofGroups: [ContinuityEvidenceGroup] = Array(
        Set(ContinuityEvidenceLane.proofLanes.map(\.group))
    ).sorted { $0.rawValue < $1.rawValue }
}

/// Canonical state for one continuity evidence lane.
///
/// - `observed`: the lane was eligible and produced a usable bounded sample.
/// - `empty`: the lane was eligible, but produced no usable sample this time.
/// - `unavailable`: the lane was not eligible because of permission, platform, entitlement, disabled
///   collection, simulator limits, or user choice. This is context, not suspicion.
/// - `stale`: a previous sample exists but is too old for this check-in window.
/// - `contradictory`: two or more eligible facts conflict. This lowers confidence, but is not a
///   continuity break unless a break detector explicitly says so.
public enum ContinuityEvidenceState: String, Codable, Equatable, Sendable {
    case observed
    case empty
    case unavailable
    case stale
    case contradictory

    public var isEligible: Bool {
        switch self {
        case .observed, .empty, .stale, .contradictory: return true
        case .unavailable: return false
        }
    }

    public var isLive: Bool { self == .observed }
}

/// One lane's evaluated evidence state. Values are derived and bounded; raw sensor data does not
/// belong here.
public struct ContinuityEvidencePoint: Codable, Equatable, Sendable {
    public let lane: ContinuityEvidenceLane
    public let state: ContinuityEvidenceState
    public let supportStatus: SignalSupportStatus
    public let reason: String?

    public var isEligible: Bool { state.isEligible }
    public var isLive: Bool { state.isLive }

    public init(
        lane: ContinuityEvidenceLane,
        state: ContinuityEvidenceState,
        supportStatus: SignalSupportStatus,
        reason: String? = nil
    ) {
        self.lane = lane
        self.state = state
        self.supportStatus = supportStatus
        self.reason = reason
    }
}

/// A complete, explainable evidence snapshot for one check-in.
public struct ContinuityEvidenceSnapshot: Codable, Equatable, Sendable {
    public let points: [ContinuityEvidencePoint]
    public let possibleLaneCount: Int

    public var eligibleCount: Int { points.filter(\.isEligible).count }
    public var liveCount: Int { points.filter(\.isLive).count }
    public var emptyCount: Int { points.filter { $0.state == .empty }.count }
    public var unavailableCount: Int { points.filter { $0.state == .unavailable }.count }
    public var staleCount: Int { points.filter { $0.state == .stale }.count }
    public var contradictoryCount: Int { points.filter { $0.state == .contradictory }.count }

    /// Breadth of lanes that were actually eligible for this check-in. This is the maturity/confidence
    /// discount; it must not be described as user trust.
    public var evidenceBreadth: Double {
        guard possibleLaneCount > 0 else { return 0 }
        return min(1, max(0, Double(eligibleCount) / Double(possibleLaneCount)))
    }

    /// Coverage within eligible lanes only. Unavailable lanes do not count against this denominator.
    public var eligibleCoverage: Double {
        guard eligibleCount > 0 else { return 0 }
        return min(1, max(0, Double(liveCount) / Double(eligibleCount)))
    }

    /// Group-adjusted breadth for proof lanes. Correlated lanes in the same group count once.
    public var groupedEvidenceBreadth: Double {
        let eligibleGroups = Set(points.filter(\.isEligible).map { $0.lane.group })
        guard !ContinuityEvidenceGroup.proofGroups.isEmpty else { return 0 }
        return min(1, max(0, Double(eligibleGroups.count) / Double(ContinuityEvidenceGroup.proofGroups.count)))
    }

    /// Group-adjusted coverage: each eligible group contributes one vote, using the strongest state
    /// inside that group. This prevents dense correlated lanes from overpowering sparse independent
    /// evidence.
    public var groupedEligibleCoverage: Double {
        let groups = Dictionary(grouping: points.filter(\.isEligible), by: { $0.lane.group })
        guard !groups.isEmpty else { return 0 }
        let liveGroups = groups.values.filter { groupPoints in
            groupPoints.contains { $0.state == .observed }
        }.count
        return min(1, max(0, Double(liveGroups) / Double(groups.count)))
    }

    /// Same lanes, but observed live points are marked stale. Empty/unavailable/contradictory points
    /// keep their original meaning.
    public func markingObservedStale(reason: String) -> ContinuityEvidenceSnapshot {
        let stalePoints = points.map { point in
            guard point.state == .observed else { return point }
            return ContinuityEvidencePoint(
                lane: point.lane,
                state: .stale,
                supportStatus: point.supportStatus,
                reason: point.reason ?? reason
            )
        }
        return ContinuityEvidenceSnapshot(points: stalePoints, possibleLaneCount: possibleLaneCount)
    }

    public init(
        points: [ContinuityEvidencePoint],
        possibleLaneCount: Int = ContinuityEvidenceLane.proofLanes.count
    ) {
        self.points = points
        self.possibleLaneCount = possibleLaneCount
    }

    public static func synthesized(fromProofSignals proofSignals: [Bool],
                                   possibleLaneCount: Int = ContinuityEvidenceLane.proofLanes.count)
    -> ContinuityEvidenceSnapshot {
        let lanes = Array(ContinuityEvidenceLane.proofLanes.prefix(proofSignals.count))
        let points = zip(lanes, proofSignals).map { lane, live in
            ContinuityEvidencePoint(
                lane: lane,
                state: live ? .observed : .empty,
                supportStatus: .available
            )
        }
        return ContinuityEvidenceSnapshot(points: points, possibleLaneCount: possibleLaneCount)
    }
}
