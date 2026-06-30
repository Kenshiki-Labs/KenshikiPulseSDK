import Foundation
import SQLite3

/// Persistent, queryable store for on-device telemetry events. Implementations keep raw sensor data
/// out by construction — they persist only the bounded `TelemetryEvent` surface.
protocol TelemetryStoring: Sendable {
    func append(_ event: TelemetryEvent) async throws
    func append(contentsOf events: [TelemetryEvent]) async throws
    func append(_ point: TelemetryFeaturePoint) async throws
    func append(contentsOf points: [TelemetryFeaturePoint]) async throws
    /// Most-recent-first, newest `limit` events.
    func recent(limit: Int) async throws -> [TelemetryEvent]
    /// Events whose `occurredAt` falls within `interval`, oldest-first.
    func events(in interval: DateInterval) async throws -> [TelemetryEvent]
    /// Most-recent-first events of one category.
    func events(category: TelemetryEventCategory, limit: Int) async throws -> [TelemetryEvent]
    func count() async throws -> Int
    /// Most-recent-first timeline events in `interval`.
    func timeline(in interval: DateInterval, limit: Int) async throws -> [TelemetryEvent]
    /// Most-recent-first check-in summaries in `interval`.
    func checkIns(in interval: DateInterval, limit: Int) async throws -> [CheckInRecord]
    /// Oldest-first liveness points for one signal.
    func signalSeries(signalId: String, in interval: DateInterval) async throws -> [SignalPoint]
    /// Oldest-first daily aggregates for graphing and deterministic history features.
    func dailySummary(in interval: DateInterval) async throws -> [ContinuityDaySummary]
    /// Oldest-first local-calendar daily aggregates for human rhythm features.
    func localDailySummary(in interval: DateInterval, calendar: Calendar) async throws -> [ContinuityDaySummary]
    /// Most-recent-first break events in `interval`.
    func breaks(in interval: DateInterval, limit: Int) async throws -> [TelemetryEvent]
    /// Most-recent-first derived state-transition events in `interval`.
    func stateTransitions(in interval: DateInterval, limit: Int) async throws -> [TelemetryEvent]
    /// Oldest-first bounded feature points for one signal.
    func featureSeries(signalId: String, in interval: DateInterval) async throws -> [TelemetryFeaturePoint]
    /// Oldest-first bounded feature points in `interval`, optionally limited.
    func featurePoints(in interval: DateInterval, limit: Int) async throws -> [TelemetryFeaturePoint]
    /// Oldest-first export page for server-side ingestion. Pass the previous `nextCursor` to continue.
    func exportBatch(after cursor: TelemetryExportCursor?, limit: Int) async throws -> TelemetryExportBatch
    /// Oldest-first feature-point export page for continuity-trace ingestion.
    func exportFeatureBatch(after cursor: TelemetryFeatureExportCursor?, limit: Int) async throws -> TelemetryFeatureExportBatch
    /// Per-signal liveness rates and distinct check-in count over `interval`.
    func windowSummary(in interval: DateInterval) async throws -> ContinuityWindowSummary
    /// Trim to the newest `maxRows` events. Returns the number of rows deleted.
    @discardableResult
    func prune(keepingMostRecent maxRows: Int) async throws -> Int
    /// Delete events older than `cutoff` (time-based retention). Returns the number of rows deleted.
    @discardableResult
    func prune(olderThan cutoff: Date) async throws -> Int
    func clear() async throws
}

/// SQLite-backed `TelemetryStoring`, implemented directly on the platform `SQLite3` system library so
/// the package keeps zero external dependencies. The actor serializes all access, so the underlying
/// connection needs no extra mutex. Replaces the host app's capped, JSON-blob-in-`UserDefaults`
/// continuity log with an unbounded, indexed, time-queryable history.
actor SQLiteTelemetryStore: TelemetryStoring {
    static let schemaVersion: Int32 = 4
    /// SQLite wants the destructor sentinel for transient (copied) bound text; the C macro doesn't import.
    static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    static let allowedEventMetadataKeys: Set<String> = [
        "source", "observed", "evidence_state", "support_status", "evidence_reason",
        "signals_live", "signals_total",
        "signed_signals_live", "signed_signals_total",
        "observed_signals_live", "observed_signals_total",
        "capture_source", "capture_quality", "capture_observed", "capture_lag_ms",
        "detector", "confidence", "inputs", "privacy_boundary",
        "battery_state", "power_correlation", "power_window", "discharge_slope",
    ]
    static let allowedFeatureMetadataKeys: Set<String> = [
        "source", "observed", "detector", "confidence", "inputs", "privacy_boundary", "privacy",
    ]
    static let maxQueryLimit: Int32 = 10_000

    let url: URL?   // nil for in-memory
    var db: OpaquePointer?

    /// Opens (creating if needed) a telemetry database at `url`.
    /// - Parameter url: file URL for the database. Pass `nil` for an ephemeral in-memory store (tests).
    public init(url: URL?) throws {
        self.url = url
        self.db = try Self.makeConnection(path: url?.path ?? ":memory:")
    }

    /// Opens the default database under Application Support: `<AppSupport>/Kenshiki/telemetry.sqlite3`.
    public init() throws {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base.appendingPathComponent("Kenshiki", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("telemetry.sqlite3", isDirectory: false)
        self.url = fileURL
        self.db = try Self.makeConnection(path: fileURL.path)
        try Self.protectDatabaseFiles(fileURL)
    }

    deinit {
        if let db { sqlite3_close_v2(db) }
    }
}
