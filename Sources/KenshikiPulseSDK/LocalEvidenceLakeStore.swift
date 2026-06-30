import CryptoKit
import Foundation
import SQLite3

enum LocalEvidenceQuality: String, Codable, Equatable, Sendable, CaseIterable {
    case observed
    case empty
    case unavailable
    case stale
    case contradictory
}

enum LocalEvidencePermissionState: String, Codable, Equatable, Sendable, CaseIterable {
    case authorized
    case denied
    case restricted
    case notDetermined = "not_determined"
    case notRequired = "not_required"
    case unknown
    case unavailable
}

enum LocalEvidenceSupportState: String, Codable, Equatable, Sendable, CaseIterable {
    case available
    case notCollected = "not_collected"
    case disabledByConfiguration = "disabled_by_configuration"
    case notSupportedByPlatform = "not_supported_by_platform"
    case unavailable
}

enum LocalEvidencePrivacyClass: String, Codable, Equatable, Sendable, CaseIterable {
    case localWindow = "local_window"
    case localStateTransition = "local_state_transition"
    case localSaltedToken = "local_salted_token"
    case localCoarsePlace = "local_coarse_place"
    case researchEligibleBounded = "research_eligible_bounded"
}

/// One bounded, local-only evidence observation. This is the replay substrate, not UI copy, AI input,
/// or an operational upload payload.
struct LocalEvidenceWindow: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var capturedAt: Date
    public var windowStartAt: Date
    public var windowEndAt: Date
    public var sensorId: String
    public var laneGroup: String
    public var evidenceKind: String
    public var source: String
    public var collectionSurface: String
    public var quality: LocalEvidenceQuality
    public var permissionState: LocalEvidencePermissionState
    public var supportState: LocalEvidenceSupportState
    public var freshnessSeconds: Int
    public var schemaVersion: String
    public var extractorVersion: String
    public var privacyClass: LocalEvidencePrivacyClass
    public var payload: [String: String]
    public var payloadHash: String
    public var createdAt: Date

    public init(
        id: String? = nil,
        capturedAt: Date,
        windowStartAt: Date,
        windowEndAt: Date,
        sensorId: String,
        laneGroup: String,
        evidenceKind: String,
        source: String,
        collectionSurface: String,
        quality: LocalEvidenceQuality,
        permissionState: LocalEvidencePermissionState,
        supportState: LocalEvidenceSupportState,
        freshnessSeconds: Int,
        schemaVersion: String = SQLiteLocalEvidenceLakeStore.windowSchemaVersion,
        extractorVersion: String,
        privacyClass: LocalEvidencePrivacyClass,
        payload: [String: String],
        createdAt: Date = Date()
    ) {
        let hash = Self.hashPayload(payload)
        self.id = id ?? Self.deterministicID(
            sensorId: sensorId,
            evidenceKind: evidenceKind,
            windowStartAt: windowStartAt,
            windowEndAt: windowEndAt,
            payloadHash: hash
        )
        self.capturedAt = capturedAt
        self.windowStartAt = windowStartAt
        self.windowEndAt = windowEndAt
        self.sensorId = sensorId
        self.laneGroup = laneGroup
        self.evidenceKind = evidenceKind
        self.source = source
        self.collectionSurface = collectionSurface
        self.quality = quality
        self.permissionState = permissionState
        self.supportState = supportState
        self.freshnessSeconds = freshnessSeconds
        self.schemaVersion = schemaVersion
        self.extractorVersion = extractorVersion
        self.privacyClass = privacyClass
        self.payload = payload
        self.payloadHash = hash
        self.createdAt = createdAt
    }

    static func deterministicID(
        sensorId: String,
        evidenceKind: String,
        windowStartAt: Date,
        windowEndAt: Date,
        payloadHash: String
    ) -> String {
        let material = [
            sensorId,
            evidenceKind,
            String(format: "%.3f", windowStartAt.timeIntervalSince1970),
            String(format: "%.3f", windowEndAt.timeIntervalSince1970),
            payloadHash,
        ].joined(separator: "|")
        return "lake-\(sha256Hex(material).prefix(40))"
    }

    static func hashPayload(_ payload: [String: String]) -> String {
        sha256Hex(canonicalPayload(payload))
    }
}

struct LocalEvidenceExtractionRun: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let runAt: Date
    public let windowStartAt: Date
    public let windowEndAt: Date
    public let extractorVersion: String
    public let fusionVersion: String
    public let inputRowCount: Int
    public let inputHash: String
    public let outputFeatureCount: Int
    public let outputEventCount: Int
    public let status: String
    public let error: String?

    public init(
        id: String? = nil,
        runAt: Date = Date(),
        windowStartAt: Date,
        windowEndAt: Date,
        extractorVersion: String,
        fusionVersion: String,
        inputRowCount: Int,
        inputHash: String,
        outputFeatureCount: Int,
        outputEventCount: Int,
        status: String,
        error: String? = nil
    ) {
        self.id = id ?? "extract-\(Self.hashID(runAt: runAt, inputHash: inputHash, extractorVersion: extractorVersion))"
        self.runAt = runAt
        self.windowStartAt = windowStartAt
        self.windowEndAt = windowEndAt
        self.extractorVersion = extractorVersion
        self.fusionVersion = fusionVersion
        self.inputRowCount = inputRowCount
        self.inputHash = inputHash
        self.outputFeatureCount = outputFeatureCount
        self.outputEventCount = outputEventCount
        self.status = status
        self.error = error
    }

    private static func hashID(runAt: Date, inputHash: String, extractorVersion: String) -> String {
        String(LocalEvidenceWindow.sha256Hex(
            "\(runAt.timeIntervalSince1970)|\(inputHash)|\(extractorVersion)"
        ).prefix(40))
    }
}

struct LocalEvidenceSnapshot: Codable, Equatable, Sendable {
    public let interval: DateInterval
    public let rows: [LocalEvidenceWindow]

    public init(interval: DateInterval, rows: [LocalEvidenceWindow]) {
        self.interval = interval
        self.rows = rows
    }

    public var inputHash: String {
        let material = rows
            .sorted { $0.id < $1.id }
            .map { "\($0.id):\($0.payloadHash):\($0.quality.rawValue):\($0.supportState.rawValue)" }
            .joined(separator: "|")
        return LocalEvidenceWindow.sha256Hex(material)
    }

    public var observedCount: Int {
        rows.filter { $0.quality == .observed }.count
    }

    public var unavailableCount: Int {
        rows.filter { $0.quality == .unavailable }.count
    }
}

protocol LocalEvidenceLakeStoring: Sendable {
    func append(_ window: LocalEvidenceWindow) async throws
    func append(contentsOf windows: [LocalEvidenceWindow]) async throws
    func snapshot(in interval: DateInterval, limit: Int) async throws -> LocalEvidenceSnapshot
    func recent(sensorId: String?, limit: Int) async throws -> [LocalEvidenceWindow]
    func appendExtractionRun(_ run: LocalEvidenceExtractionRun) async throws
    func latestExtractionRun() async throws -> LocalEvidenceExtractionRun?
    @discardableResult
    func prune(olderThan cutoff: Date) async throws -> Int
    func clear() async throws
}

actor SQLiteLocalEvidenceLakeStore: LocalEvidenceLakeStoring {
    public static let windowSchemaVersion = "pulse.local_evidence_lake.window.v1"
    public static let defaultExtractorVersion = "pulse.local_evidence_lake.extractor.v1"
    static let schemaVersion: Int32 = 1
    static let maxQueryLimit: Int32 = 10_000
    static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    let url: URL?
    var db: OpaquePointer?

    public init(url: URL?) throws {
        self.url = url
        self.db = try Self.makeConnection(path: url?.path ?? ":memory:")
    }

    /// Opens `<AppSupport>/Kenshiki/pulse-evidence-lake.sqlite`.
    public init() throws {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base.appendingPathComponent("Kenshiki", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("pulse-evidence-lake.sqlite", isDirectory: false)
        self.url = fileURL
        self.db = try Self.makeConnection(path: fileURL.path)
        try Self.protectDatabaseFiles(fileURL)
    }

    deinit {
        if let db { sqlite3_close_v2(db) }
    }

    public func append(_ window: LocalEvidenceWindow) async throws {
        try insert(window)
    }

    public func append(contentsOf windows: [LocalEvidenceWindow]) async throws {
        guard !windows.isEmpty else { return }
        try exec("BEGIN TRANSACTION;")
        do {
            for window in windows { try insert(window) }
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    public func snapshot(in interval: DateInterval, limit: Int = 2_000) async throws -> LocalEvidenceSnapshot {
        let statement = try prepare(
            """
            SELECT \(Self.windowColumns) FROM lake_windows
            WHERE window_end_at >= ? AND window_start_at < ?
            ORDER BY window_start_at ASC, id ASC LIMIT ?;
            """
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, interval.start.timeIntervalSince1970)
        sqlite3_bind_double(statement, 2, interval.end.timeIntervalSince1970)
        sqlite3_bind_int(statement, 3, Self.sqlLimit(limit))
        return LocalEvidenceSnapshot(interval: interval, rows: try windowRows(from: statement))
    }

    public func recent(sensorId: String? = nil, limit: Int = 200) async throws -> [LocalEvidenceWindow] {
        let statement: OpaquePointer
        if let sensorId {
            statement = try prepare(
                """
                SELECT \(Self.windowColumns) FROM lake_windows
                WHERE sensor_id = ?
                ORDER BY captured_at DESC, id DESC LIMIT ?;
                """
            )
            bindText(statement, 1, sensorId)
            sqlite3_bind_int(statement, 2, Self.sqlLimit(limit))
        } else {
            statement = try prepare(
                """
                SELECT \(Self.windowColumns) FROM lake_windows
                ORDER BY captured_at DESC, id DESC LIMIT ?;
                """
            )
            sqlite3_bind_int(statement, 1, Self.sqlLimit(limit))
        }
        defer { sqlite3_finalize(statement) }
        return try windowRows(from: statement)
    }

    public func appendExtractionRun(_ run: LocalEvidenceExtractionRun) async throws {
        let sql = """
            INSERT OR REPLACE INTO lake_extraction_runs
                (id, run_at, window_start_at, window_end_at, extractor_version, fusion_version,
                 input_row_count, input_hash, output_feature_count, output_event_count, status, error)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        bindText(statement, 1, run.id)
        sqlite3_bind_double(statement, 2, run.runAt.timeIntervalSince1970)
        sqlite3_bind_double(statement, 3, run.windowStartAt.timeIntervalSince1970)
        sqlite3_bind_double(statement, 4, run.windowEndAt.timeIntervalSince1970)
        bindText(statement, 5, run.extractorVersion)
        bindText(statement, 6, run.fusionVersion)
        sqlite3_bind_int(statement, 7, Int32(run.inputRowCount))
        bindText(statement, 8, run.inputHash)
        sqlite3_bind_int(statement, 9, Int32(run.outputFeatureCount))
        sqlite3_bind_int(statement, 10, Int32(run.outputEventCount))
        bindText(statement, 11, run.status)
        bindText(statement, 12, run.error)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError() }
    }

    public func latestExtractionRun() async throws -> LocalEvidenceExtractionRun? {
        let statement = try prepare(
            """
            SELECT id, run_at, window_start_at, window_end_at, extractor_version, fusion_version,
                   input_row_count, input_hash, output_feature_count, output_event_count, status, error
            FROM lake_extraction_runs
            ORDER BY run_at DESC, id DESC LIMIT 1;
            """
        )
        defer { sqlite3_finalize(statement) }
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return try decodeExtractionRun(statement)
        case SQLITE_DONE:
            return nil
        default:
            throw lastError()
        }
    }

    @discardableResult
    public func prune(olderThan cutoff: Date) async throws -> Int {
        let statement = try prepare("DELETE FROM lake_windows WHERE window_end_at < ?;")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, cutoff.timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError() }
        let deleted = Int(sqlite3_changes(db))
        if deleted > 0 {
            try recordRetentionState()
            try checkpointWal()
        }
        return deleted
    }

    public func clear() async throws {
        try exec("DELETE FROM lake_windows;")
        try exec("DELETE FROM lake_extraction_runs;")
        try exec("DELETE FROM lake_local_tokens;")
        try exec("DELETE FROM lake_retention_state;")
        try checkpointWal()
    }

    private func insert(_ window: LocalEvidenceWindow) throws {
        try validate(window)
        let payloadJSON = try Self.encodePayload(window.payload)
        guard window.payloadHash == LocalEvidenceWindow.hashPayload(window.payload) else {
            throw KenshikiPulseError.storageFailed("local evidence payload hash mismatch")
        }
        let sql = """
            INSERT OR IGNORE INTO lake_windows
                (id, captured_at, window_start_at, window_end_at, sensor_id, lane_group, evidence_kind,
                 source, collection_surface, quality, permission_state, support_state, freshness_seconds,
                 schema_version, extractor_version, privacy_class, payload_json, payload_hash, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        bindText(statement, 1, window.id)
        sqlite3_bind_double(statement, 2, window.capturedAt.timeIntervalSince1970)
        sqlite3_bind_double(statement, 3, window.windowStartAt.timeIntervalSince1970)
        sqlite3_bind_double(statement, 4, window.windowEndAt.timeIntervalSince1970)
        bindText(statement, 5, window.sensorId)
        bindText(statement, 6, window.laneGroup)
        bindText(statement, 7, window.evidenceKind)
        bindText(statement, 8, window.source)
        bindText(statement, 9, window.collectionSurface)
        bindText(statement, 10, window.quality.rawValue)
        bindText(statement, 11, window.permissionState.rawValue)
        bindText(statement, 12, window.supportState.rawValue)
        sqlite3_bind_int(statement, 13, Int32(max(0, window.freshnessSeconds)))
        bindText(statement, 14, window.schemaVersion)
        bindText(statement, 15, window.extractorVersion)
        bindText(statement, 16, window.privacyClass.rawValue)
        bindText(statement, 17, payloadJSON)
        bindText(statement, 18, window.payloadHash)
        sqlite3_bind_double(statement, 19, window.createdAt.timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError() }
        if sqlite3_changes(db) == 0 {
            try verifyExistingWindowMatches(window)
        }
    }

    private func verifyExistingWindowMatches(_ window: LocalEvidenceWindow) throws {
        let statement = try prepare("SELECT \(Self.windowColumns) FROM lake_windows WHERE id = ? LIMIT 1;")
        defer { sqlite3_finalize(statement) }
        bindText(statement, 1, window.id)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw KenshikiPulseError.storageFailed("duplicate local evidence window missing: \(window.id)")
        }
        guard try decodeWindow(statement) == window else {
            throw KenshikiPulseError.storageFailed("local evidence window id collision: \(window.id)")
        }
    }

    private func validate(_ window: LocalEvidenceWindow) throws {
        try validateText(window.id, field: "id", maxLength: 160)
        try validateText(window.sensorId, field: "sensor_id", maxLength: 80)
        try validateText(window.laneGroup, field: "lane_group", maxLength: 80)
        try validateText(window.evidenceKind, field: "evidence_kind", maxLength: 80)
        try validateText(window.source, field: "source", maxLength: 80)
        try validateText(window.collectionSurface, field: "collection_surface", maxLength: 80)
        try validateText(window.schemaVersion, field: "schema_version", maxLength: 120)
        try validateText(window.extractorVersion, field: "extractor_version", maxLength: 120)
        guard window.windowEndAt >= window.windowStartAt else {
            throw KenshikiPulseError.storageFailed("local evidence window has negative duration")
        }
        guard window.payload.count <= 32 else {
            throw KenshikiPulseError.storageFailed("local evidence payload has too many keys")
        }
        for (key, value) in window.payload {
            try validateText(key, field: "payload key", maxLength: 80)
            try validateText(value, field: "payload value", maxLength: 256)
            guard !key.lowercased().contains("ssid"),
                  !key.lowercased().contains("bssid"),
                  !key.lowercased().contains("phone_number"),
                  !key.lowercased().contains("latitude"),
                  !key.lowercased().contains("longitude")
            else {
                throw KenshikiPulseError.storageFailed("forbidden local evidence payload key: \(key)")
            }
        }
    }

    private func validateText(_ value: String?, field: String, maxLength: Int) throws {
        guard let value else { return }
        guard !value.contains("\u{0}"), value.count <= maxLength else {
            throw KenshikiPulseError.storageFailed("local evidence \(field) is out of bounds")
        }
    }
}

private extension SQLiteLocalEvidenceLakeStore {
    static let windowColumns = """
        id, captured_at, window_start_at, window_end_at, sensor_id, lane_group, evidence_kind,
        source, collection_surface, quality, permission_state, support_state, freshness_seconds,
        schema_version, extractor_version, privacy_class, payload_json, payload_hash, created_at
        """

    static func makeConnection(path: String) throws -> OpaquePointer {
        do {
            return try openAndPrepare(path: path)
        } catch {
            guard path != ":memory:" else { throw error }
            quarantineCorruptDatabase(at: path)
            return try openAndPrepare(path: path)
        }
    }

    static func openAndPrepare(path: String) throws -> OpaquePointer {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unable to open database"
            if let handle { sqlite3_close_v2(handle) }
            throw KenshikiPulseError.storageFailed(message)
        }
        do {
            try execute(handle, "PRAGMA busy_timeout = 5000;")
            try execute(handle, "PRAGMA secure_delete = ON;")
            try execute(handle, "PRAGMA journal_mode = WAL;")
            try execute(handle, "PRAGMA foreign_keys = ON;")
            try integrityCheck(handle)
            try migrate(handle)
        } catch {
            sqlite3_close_v2(handle)
            throw error
        }
        return handle
    }

    static func migrate(_ db: OpaquePointer) throws {
        try execute(
            db,
            """
            CREATE TABLE IF NOT EXISTS lake_windows (
              id TEXT PRIMARY KEY,
              captured_at REAL NOT NULL,
              window_start_at REAL NOT NULL,
              window_end_at REAL NOT NULL,
              sensor_id TEXT NOT NULL,
              lane_group TEXT NOT NULL,
              evidence_kind TEXT NOT NULL,
              source TEXT NOT NULL,
              collection_surface TEXT NOT NULL,
              quality TEXT NOT NULL,
              permission_state TEXT NOT NULL,
              support_state TEXT NOT NULL,
              freshness_seconds INTEGER NOT NULL,
              schema_version TEXT NOT NULL,
              extractor_version TEXT NOT NULL,
              privacy_class TEXT NOT NULL,
              payload_json TEXT NOT NULL,
              payload_hash TEXT NOT NULL,
              created_at REAL NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_lake_windows_time ON lake_windows(window_start_at, window_end_at);
            CREATE INDEX IF NOT EXISTS idx_lake_windows_sensor_time ON lake_windows(sensor_id, evidence_kind, window_start_at);
            CREATE INDEX IF NOT EXISTS idx_lake_windows_quality ON lake_windows(sensor_id, quality, window_start_at);
            CREATE INDEX IF NOT EXISTS idx_lake_windows_source ON lake_windows(source, collection_surface, captured_at);

            CREATE TABLE IF NOT EXISTS lake_extraction_runs (
              id TEXT PRIMARY KEY,
              run_at REAL NOT NULL,
              window_start_at REAL NOT NULL,
              window_end_at REAL NOT NULL,
              extractor_version TEXT NOT NULL,
              fusion_version TEXT NOT NULL,
              input_row_count INTEGER NOT NULL,
              input_hash TEXT NOT NULL,
              output_feature_count INTEGER NOT NULL,
              output_event_count INTEGER NOT NULL,
              status TEXT NOT NULL,
              error TEXT
            );
            CREATE INDEX IF NOT EXISTS idx_lake_extraction_time ON lake_extraction_runs(run_at);

            CREATE TABLE IF NOT EXISTS lake_local_tokens (
              token_family TEXT NOT NULL,
              token_hash TEXT NOT NULL,
              first_seen_at REAL NOT NULL,
              last_seen_at REAL NOT NULL,
              observation_count INTEGER NOT NULL,
              distinct_day_count INTEGER NOT NULL,
              last_counted_day REAL NOT NULL,
              metadata_json TEXT NOT NULL,
              PRIMARY KEY (token_family, token_hash)
            );

            CREATE TABLE IF NOT EXISTS lake_retention_state (
              id TEXT PRIMARY KEY,
              last_pruned_at REAL NOT NULL,
              retained_row_count INTEGER NOT NULL,
              retained_bytes_estimate INTEGER NOT NULL,
              oldest_retained_at REAL,
              newest_retained_at REAL,
              policy_version TEXT NOT NULL
            );
            PRAGMA user_version = \(schemaVersion);
            """
        )
    }

    static func integrityCheck(_ db: OpaquePointer) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA quick_check;", -1, &statement, nil) == SQLITE_OK else {
            throw errorFor(db)
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let raw = sqlite3_column_text(statement, 0) else {
            throw KenshikiPulseError.storageFailed("local evidence integrity check returned no result")
        }
        let result = String(cString: raw)
        guard result == "ok" else {
            throw KenshikiPulseError.storageFailed("local evidence integrity check failed: \(result)")
        }
    }

    static func quarantineCorruptDatabase(at path: String) {
        let fileManager = FileManager.default
        try? fileManager.removeItem(atPath: path + ".corrupt")
        try? fileManager.moveItem(atPath: path, toPath: path + ".corrupt")
        for suffix in ["-wal", "-shm"] { try? fileManager.removeItem(atPath: path + suffix) }
    }

    static func protectDatabaseFiles(_ fileURL: URL) throws {
        #if os(iOS)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = fileURL
        try mutableURL.setResourceValues(values)

        for suffix in ["", "-wal", "-shm"] {
            let path = fileURL.path + suffix
            if FileManager.default.fileExists(atPath: path) {
                try FileManager.default.setAttributes(
                    [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                    ofItemAtPath: path
                )
            }
        }
        #else
        _ = fileURL
        #endif
    }

    func decodeWindow(_ statement: OpaquePointer) throws -> LocalEvidenceWindow {
        guard let quality = LocalEvidenceQuality(rawValue: columnText(statement, 9) ?? ""),
              let permission = LocalEvidencePermissionState(rawValue: columnText(statement, 10) ?? ""),
              let support = LocalEvidenceSupportState(rawValue: columnText(statement, 11) ?? ""),
              let privacyClass = LocalEvidencePrivacyClass(rawValue: columnText(statement, 15) ?? "")
        else {
            throw KenshikiPulseError.storageFailed("corrupt local evidence enum value")
        }
        let payload = try Self.decodePayload(columnText(statement, 16))
        return LocalEvidenceWindow(
            id: columnText(statement, 0) ?? "",
            capturedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
            windowStartAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
            windowEndAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
            sensorId: columnText(statement, 4) ?? "",
            laneGroup: columnText(statement, 5) ?? "",
            evidenceKind: columnText(statement, 6) ?? "",
            source: columnText(statement, 7) ?? "",
            collectionSurface: columnText(statement, 8) ?? "",
            quality: quality,
            permissionState: permission,
            supportState: support,
            freshnessSeconds: Int(sqlite3_column_int64(statement, 12)),
            schemaVersion: columnText(statement, 13) ?? "",
            extractorVersion: columnText(statement, 14) ?? "",
            privacyClass: privacyClass,
            payload: payload,
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 18))
        )
    }

    func windowRows(from statement: OpaquePointer) throws -> [LocalEvidenceWindow] {
        var rows: [LocalEvidenceWindow] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                rows.append(try decodeWindow(statement))
            case SQLITE_DONE:
                return rows
            default:
                throw lastError()
            }
        }
    }

    func decodeExtractionRun(_ statement: OpaquePointer) throws -> LocalEvidenceExtractionRun {
        LocalEvidenceExtractionRun(
            id: columnText(statement, 0) ?? "",
            runAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
            windowStartAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
            windowEndAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
            extractorVersion: columnText(statement, 4) ?? "",
            fusionVersion: columnText(statement, 5) ?? "",
            inputRowCount: Int(sqlite3_column_int64(statement, 6)),
            inputHash: columnText(statement, 7) ?? "",
            outputFeatureCount: Int(sqlite3_column_int64(statement, 8)),
            outputEventCount: Int(sqlite3_column_int64(statement, 9)),
            status: columnText(statement, 10) ?? "",
            error: columnText(statement, 11)
        )
    }

    func recordRetentionState() throws {
        let countStatement = try prepare("SELECT COUNT(*), MIN(window_start_at), MAX(window_end_at) FROM lake_windows;")
        defer { sqlite3_finalize(countStatement) }
        guard sqlite3_step(countStatement) == SQLITE_ROW else { return }
        let count = Int(sqlite3_column_int64(countStatement, 0))
        let oldest = sqlite3_column_type(countStatement, 1) == SQLITE_NULL ? nil : sqlite3_column_double(countStatement, 1)
        let newest = sqlite3_column_type(countStatement, 2) == SQLITE_NULL ? nil : sqlite3_column_double(countStatement, 2)

        let statement = try prepare(
            """
            INSERT OR REPLACE INTO lake_retention_state
                (id, last_pruned_at, retained_row_count, retained_bytes_estimate,
                 oldest_retained_at, newest_retained_at, policy_version)
            VALUES ('default', ?, ?, ?, ?, ?, 'v1');
            """
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, Date().timeIntervalSince1970)
        sqlite3_bind_int(statement, 2, Int32(count))
        sqlite3_bind_int64(statement, 3, sqlite3_int64(count * 512))
        if let oldest {
            sqlite3_bind_double(statement, 4, oldest)
        } else {
            sqlite3_bind_null(statement, 4)
        }
        if let newest {
            sqlite3_bind_double(statement, 5, newest)
        } else {
            sqlite3_bind_null(statement, 5)
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError() }
    }

    func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw lastError()
        }
        return statement
    }

    func exec(_ sql: String) throws {
        guard let db else { throw KenshikiPulseError.storageFailed("local evidence database is closed") }
        try Self.execute(db, sql)
    }

    func bindText(_ statement: OpaquePointer, _ index: Int32, _ value: String?) {
        Self.bindText(statement, index, value)
    }

    func columnText(_ statement: OpaquePointer, _ index: Int32) -> String? {
        Self.columnText(statement, index)
    }

    func lastError() -> KenshikiPulseError {
        .storageFailed(db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown local evidence SQLite error")
    }

    func checkpointWal() throws {
        try exec("PRAGMA wal_checkpoint(TRUNCATE);")
    }

    static func execute(_ db: OpaquePointer, _ sql: String) throws {
        var error: UnsafeMutablePointer<Int8>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
            if let error { sqlite3_free(error) }
            throw KenshikiPulseError.storageFailed(message)
        }
    }

    static func errorFor(_ db: OpaquePointer) -> KenshikiPulseError {
        .storageFailed(String(cString: sqlite3_errmsg(db)))
    }

    static func bindText(_ statement: OpaquePointer, _ index: Int32, _ value: String?) {
        if let value {
            sqlite3_bind_text(statement, index, value, -1, transient)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    static func columnText(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard let statement, let cString = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: cString)
    }

    static func sqlLimit(_ limit: Int) -> Int32 {
        Int32(max(1, min(Int(maxQueryLimit), limit)))
    }

    static func encodePayload(_ payload: [String: String]) throws -> String {
        LocalEvidenceWindow.canonicalPayload(payload)
    }

    static func decodePayload(_ raw: String?) throws -> [String: String] {
        guard let raw, let data = raw.data(using: .utf8) else { return [:] }
        do {
            return try JSONDecoder().decode([String: String].self, from: data)
        } catch {
            throw KenshikiPulseError.storageFailed("corrupt local evidence payload JSON: \(error.localizedDescription)")
        }
    }
}

private extension LocalEvidenceWindow {
    static func canonicalPayload(_ payload: [String: String]) -> String {
        let body = payload.keys.sorted().map { key in
            "\"\(escape(key))\":\"\(escape(payload[key] ?? ""))\""
        }.joined(separator: ",")
        return "{\(body)}"
    }

    static func sha256Hex(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func escape(_ value: String) -> String {
        var result = ""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result
    }
}
