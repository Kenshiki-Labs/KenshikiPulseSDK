import Foundation

/// Coarse class of an on-device telemetry event. Mirrors the app-layer continuity feed:
/// interpreted life signals, detected continuity breaks, sealed check-ins, and state transitions.
public enum TelemetryEventCategory: String, Codable, Equatable, Sendable, CaseIterable {
    case lifeSignal = "life_signal"
    case breakEvent = "break"
    case checkIn = "check_in"
    case stateTransition = "state_transition"
    /// Human-readable continuity log entry (the on-device timeline feed). Source of truth for the
    /// continuity log now lives in SQLite; the app hydrates its in-memory log from these rows.
    case continuityLog = "continuity_log"
}

/// Display/urgency weight for an event, matching the host app's `ok`/`warn`/`danger` log kinds
/// plus a `neutral` default for informational entries.
public enum TelemetrySeverity: String, Codable, Equatable, Sendable, CaseIterable {
    case ok
    case warn
    case danger
    case neutral
}

/// One persisted, content-free telemetry event.
///
/// **Privacy boundary (`derived_device_physics_envelope_only`).** A telemetry event carries only
/// *derived, bounded* context — an interpreter id, a human-readable title/detail, a severity, and an
/// optional Merkle-root anchor. It MUST NOT carry raw sensor streams, precise location, audio,
/// identifiers, or any PII. `metadata` is a small bag of bounded string facts (e.g. coarse counts or
/// enum labels) under the same rule; the host app is responsible for keeping it derived-only.
public struct TelemetryEvent: Codable, Equatable, Identifiable, Sendable {
    /// Stable unique id (a UUID string from the host app, or auto-generated).
    public var id: String
    /// When the event occurred on-device.
    public var occurredAt: Date
    public var category: TelemetryEventCategory
    public var severity: TelemetrySeverity
    /// Interpreter id this event came from, e.g. `motion`, `rest`, `sim_swap`, `device_change`.
    public var signalId: String?
    public var title: String
    public var detail: String
    /// The check-in `KenshikiSessionContext.sessionId` this event was observed during, when known.
    public var sessionId: String?
    /// The signed receipt's Merkle root at observation time — anchors the event to the evidence chain.
    public var merkleRoot: String?
    /// Whether this signal produced a usable sample at observation time. `nil` for events where
    /// liveness is not meaningful (e.g. a state transition). Drives longitudinal liveness windows.
    public var isLive: Bool?
    /// Bounded, derived-only extra facts. No raw sensor values or PII (see type docs).
    public var metadata: [String: String]

    public init(
        id: String = UUID().uuidString,
        occurredAt: Date = Date(),
        category: TelemetryEventCategory,
        severity: TelemetrySeverity = .neutral,
        signalId: String? = nil,
        title: String,
        detail: String = "",
        sessionId: String? = nil,
        merkleRoot: String? = nil,
        isLive: Bool? = nil,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.occurredAt = occurredAt
        self.category = category
        self.severity = severity
        self.signalId = signalId
        self.title = title
        self.detail = detail
        self.sessionId = sessionId
        self.merkleRoot = merkleRoot
        self.isLive = isLive
        self.metadata = metadata
    }
}

/// Per-signal liveness over a time window: how often a signal produced a usable sample across the
/// check-ins in the window. The substrate for "continuity of life" reads (3/7/30-day rates).
public struct SignalLiveness: Codable, Equatable, Sendable, Identifiable {
    public let signalId: String
    /// Check-ins in the window where this signal was live (`isLive == true`).
    public let liveCount: Int
    /// Check-ins in the window that recorded this signal at all.
    public let totalCount: Int

    public var id: String { signalId }
    /// Fraction of recorded check-ins where the signal was live, in `0...1`.
    public var rate: Double { totalCount == 0 ? 0 : Double(liveCount) / Double(totalCount) }

    public init(signalId: String, liveCount: Int, totalCount: Int) {
        self.signalId = signalId
        self.liveCount = liveCount
        self.totalCount = totalCount
    }
}

/// Aggregate continuity over a window: distinct check-ins observed and per-signal liveness rates.
public struct ContinuityWindowSummary: Codable, Equatable, Sendable {
    public let interval: DateInterval
    /// Distinct check-in sessions (by `sessionId`) seen in the window.
    public let checkInCount: Int
    public let signals: [SignalLiveness]

    public init(interval: DateInterval, checkInCount: Int, signals: [SignalLiveness]) {
        self.interval = interval
        self.checkInCount = checkInCount
        self.signals = signals
    }
}

/// One check-in summary reconstructed from telemetry. This is the semantic row Timeline and
/// scoring code should use instead of parsing `TelemetryEvent.metadata` directly.
public struct CheckInRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let sessionId: String
    public let occurredAt: Date
    public let outcome: String
    public let severity: TelemetrySeverity
    public let merkleRoot: String?
    /// All signal slots recorded for this check-in: signed-envelope + live-only.
    public let signalsLive: Int?
    public let signalsTotal: Int?
    /// Signed-envelope-only coverage over eligible channels, matching `ContinuityEvaluator.proofSignals(from:)`.
    public let signedSignalsLive: Int?
    public let signedSignalsTotal: Int?
    /// Signal slots actually observed at check-in time. Headless live-only placeholders are excluded.
    public let observedSignalsLive: Int?
    public let observedSignalsTotal: Int?
    /// Capture provenance/quality for diagnostics and AI confidence. Optional for rows written before
    /// capture provenance existed.
    public let captureSource: String?
    public let captureQuality: String?
    public let captureObserved: Int?
    public let captureLagMilliseconds: Int?

    public init(
        id: String,
        sessionId: String,
        occurredAt: Date,
        outcome: String,
        severity: TelemetrySeverity,
        merkleRoot: String?,
        signalsLive: Int?,
        signalsTotal: Int?,
        signedSignalsLive: Int? = nil,
        signedSignalsTotal: Int? = nil,
        observedSignalsLive: Int? = nil,
        observedSignalsTotal: Int? = nil,
        captureSource: String? = nil,
        captureQuality: String? = nil,
        captureObserved: Int? = nil,
        captureLagMilliseconds: Int? = nil
    ) {
        self.id = id
        self.sessionId = sessionId
        self.occurredAt = occurredAt
        self.outcome = outcome
        self.severity = severity
        self.merkleRoot = merkleRoot
        self.signalsLive = signalsLive
        self.signalsTotal = signalsTotal
        self.signedSignalsLive = signedSignalsLive
        self.signedSignalsTotal = signedSignalsTotal
        self.observedSignalsLive = observedSignalsLive
        self.observedSignalsTotal = observedSignalsTotal
        self.captureSource = captureSource
        self.captureQuality = captureQuality
        self.captureObserved = captureObserved
        self.captureLagMilliseconds = captureLagMilliseconds
    }
}

/// One signal's liveness point at a check-in time. `source` is a bounded label such as `signed` or
/// `live`; it never contains raw sensor data.
public struct SignalPoint: Codable, Equatable, Identifiable, Sendable {
    public var id: String { "\(sessionId ?? "-")-\(signalId)-\(occurredAt.timeIntervalSince1970)" }
    public let signalId: String
    public let occurredAt: Date
    public let sessionId: String?
    public let isLive: Bool
    public let source: String?

    public init(signalId: String, occurredAt: Date, sessionId: String?, isLive: Bool, source: String?) {
        self.signalId = signalId
        self.occurredAt = occurredAt
        self.sessionId = sessionId
        self.isLive = isLive
        self.source = source
    }
}

/// Daily aggregate for graphing and deterministic history features. `dayStart` is the UTC day bucket.
public struct ContinuityDaySummary: Codable, Equatable, Identifiable, Sendable {
    public var id: Date { dayStart }
    public let dayStart: Date
    public let checkInCount: Int
    public let breakCount: Int
    public let liveSignalCount: Int
    public let totalSignalCount: Int

    public var liveRate: Double {
        totalSignalCount == 0 ? 0 : Double(liveSignalCount) / Double(totalSignalCount)
    }

    public init(
        dayStart: Date,
        checkInCount: Int,
        breakCount: Int,
        liveSignalCount: Int,
        totalSignalCount: Int
    ) {
        self.dayStart = dayStart
        self.checkInCount = checkInCount
        self.breakCount = breakCount
        self.liveSignalCount = liveSignalCount
        self.totalSignalCount = totalSignalCount
    }
}

/// Stable cursor for incremental off-device export. Use `(occurredAt, eventId)` so rows with the
/// same timestamp can be paged without gaps or duplicates.
struct TelemetryExportCursor: Codable, Equatable, Sendable {
    public let occurredAt: Date
    public let eventId: String
    /// Monotonic local SQLite row sequence used for export pagination. `nil` is accepted for
    /// cursors created by older clients; export then falls back to `(occurredAt, eventId)`.
    public let localSequence: Int64?

    public init(occurredAt: Date, eventId: String, localSequence: Int64? = nil) {
        self.occurredAt = occurredAt
        self.eventId = eventId
        self.localSequence = localSequence
    }
}

/// Export envelope for syncing the bounded telemetry event log into a server-side database. The
/// payload is still derived-only; the server receives the same privacy surface the UI can query.
struct TelemetryExportBatch: Codable, Equatable, Sendable {
    public let schemaVersion: String
    public let privacyBoundary: String
    public let exportedAt: Date
    public let events: [TelemetryEvent]
    public let featurePoints: [TelemetryFeaturePoint]
    public let nextCursor: TelemetryExportCursor?

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, privacyBoundary, exportedAt, events, featurePoints, nextCursor
    }

    public init(
        schemaVersion: String = "kenshiki.device.telemetry.export.v1",
        privacyBoundary: String = KenshikiPulseConstants.privacyBoundary,
        exportedAt: Date = Date(),
        events: [TelemetryEvent],
        featurePoints: [TelemetryFeaturePoint] = [],
        nextCursor: TelemetryExportCursor?
    ) {
        self.schemaVersion = schemaVersion
        self.privacyBoundary = privacyBoundary
        self.exportedAt = exportedAt
        self.events = events
        self.featurePoints = featurePoints
        self.nextCursor = nextCursor
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(String.self, forKey: .schemaVersion)
        privacyBoundary = try container.decode(String.self, forKey: .privacyBoundary)
        exportedAt = try container.decode(Date.self, forKey: .exportedAt)
        events = try container.decode([TelemetryEvent].self, forKey: .events)
        featurePoints = try container.decodeIfPresent([TelemetryFeaturePoint].self, forKey: .featurePoints) ?? []
        nextCursor = try container.decodeIfPresent(TelemetryExportCursor.self, forKey: .nextCursor)
    }
}

/// Bounded derived feature point for continuity trace rendering.
///
/// Feature points are not raw sensor samples. They carry coarse buckets and labels such as
/// `spike`, `quiet`, `wifi`, or `step_down` so Timeline can render a proof trace without storing
/// accelerometer vectors, magnetic field values, pressure readings, location, audio, or identifiers.
public struct TelemetryFeaturePoint: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let occurredAt: Date
    public let signalId: String
    public let featureKind: String
    public let bucketSeconds: Int
    public let valueBucket: String
    public let trend: String?
    public let volatilityBucket: String?
    public let stateLabel: String?
    public let sessionId: String?
    public let metadata: [String: String]

    public init(
        id: String = UUID().uuidString,
        occurredAt: Date = Date(),
        signalId: String,
        featureKind: String,
        bucketSeconds: Int,
        valueBucket: String,
        trend: String? = nil,
        volatilityBucket: String? = nil,
        stateLabel: String? = nil,
        sessionId: String? = nil,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.occurredAt = occurredAt
        self.signalId = signalId
        self.featureKind = featureKind
        self.bucketSeconds = bucketSeconds
        self.valueBucket = valueBucket
        self.trend = trend
        self.volatilityBucket = volatilityBucket
        self.stateLabel = stateLabel
        self.sessionId = sessionId
        self.metadata = metadata
    }
}

/// Stable cursor for incremental feature-point export. Uses SQLite insertion order for pagination;
/// `occurredAt` and `pointId` are informational/backward-compatible anchors for external logs.
struct TelemetryFeatureExportCursor: Codable, Equatable, Sendable {
    public let occurredAt: Date
    public let pointId: String
    public let localSequence: Int64?

    public init(occurredAt: Date, pointId: String, localSequence: Int64? = nil) {
        self.occurredAt = occurredAt
        self.pointId = pointId
        self.localSequence = localSequence
    }
}

/// Export page for bounded feature points used by the Continuity Trace. These rows are derived-only
/// and contain buckets/labels, not raw sensor samples.
struct TelemetryFeatureExportBatch: Codable, Equatable, Sendable {
    public let schemaVersion: String
    public let privacyBoundary: String
    public let exportedAt: Date
    public let featurePoints: [TelemetryFeaturePoint]
    public let nextCursor: TelemetryFeatureExportCursor?

    public init(
        schemaVersion: String = "kenshiki.device.telemetry.features.export.v1",
        privacyBoundary: String = KenshikiPulseConstants.privacyBoundary,
        exportedAt: Date = Date(),
        featurePoints: [TelemetryFeaturePoint],
        nextCursor: TelemetryFeatureExportCursor?
    ) {
        self.schemaVersion = schemaVersion
        self.privacyBoundary = privacyBoundary
        self.exportedAt = exportedAt
        self.featurePoints = featurePoints
        self.nextCursor = nextCursor
    }
}
