import Foundation
import SQLite3

// MARK: - Open / migrate (nonisolated so `init` can build the connection synchronously)

extension SQLiteTelemetryStore {

    static func makeConnection(path: String) throws -> OpaquePointer {
        do {
            return try openAndPrepare(path: path)
        } catch {
            // Corruption recovery: a file-backed store that can't open/verify/migrate is unreadable,
            // and now that SQLite is the SSOT continuity log, silently failing would lose it forever.
            // Quarantine the bad file (kept for forensics) and rebuild fresh so the store self-heals.
            // Never for :memory: — there's no file, so nothing to recover.
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

    static func integrityCheck(_ db: OpaquePointer) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA quick_check;", -1, &statement, nil) == SQLITE_OK else {
            throw errorFor(db)
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let raw = sqlite3_column_text(statement, 0) else {
            throw KenshikiPulseError.storageFailed("integrity check returned no result")
        }
        let result = String(cString: raw)
        guard result == "ok" else {
            throw KenshikiPulseError.storageFailed("integrity check failed: \(result)")
        }
    }

    /// Move an unreadable database aside (kept as `.corrupt` for forensics) and clear its WAL/SHM so a
    /// fresh database can be created in its place. Best-effort.
    static func quarantineCorruptDatabase(at path: String) {
        let fileManager = FileManager.default
        try? fileManager.removeItem(atPath: path + ".corrupt")
        try? fileManager.moveItem(atPath: path, toPath: path + ".corrupt")
        for suffix in ["-wal", "-shm"] { try? fileManager.removeItem(atPath: path + suffix) }
    }

    /// Encrypt the database at rest. `.completeUntilFirstUserAuthentication` keeps it readable for
    /// background check-ins after first unlock while encrypting it before that — stronger than relying
    /// on the implicit default, without breaking background writes the way `.complete` would.
    static func applyFileProtection(to url: URL) {
        #if os(iOS)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        #endif
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

    static func migrate(_ db: OpaquePointer) throws {
        let currentVersion = try userVersion(db)
        guard currentVersion < schemaVersion else { return }
        try execute(
            db,
            """
            CREATE TABLE IF NOT EXISTS telemetry_events (
                id TEXT PRIMARY KEY,
                occurred_at REAL NOT NULL,
                category TEXT NOT NULL,
                severity TEXT NOT NULL,
                signal_id TEXT,
                title TEXT NOT NULL,
                detail TEXT NOT NULL,
                session_id TEXT,
                merkle_root TEXT,
                is_live INTEGER,
                metadata TEXT
            );
            CREATE INDEX IF NOT EXISTS idx_telemetry_occurred_at ON telemetry_events(occurred_at);
            CREATE INDEX IF NOT EXISTS idx_telemetry_category ON telemetry_events(category);
            CREATE INDEX IF NOT EXISTS idx_telemetry_signal ON telemetry_events(category, signal_id, occurred_at);
            CREATE INDEX IF NOT EXISTS idx_telemetry_session ON telemetry_events(session_id, occurred_at);
            CREATE INDEX IF NOT EXISTS idx_telemetry_merkle_root ON telemetry_events(merkle_root);
            CREATE INDEX IF NOT EXISTS idx_telemetry_export ON telemetry_events(occurred_at, id);

            CREATE TABLE IF NOT EXISTS telemetry_feature_points (
                id TEXT PRIMARY KEY,
                occurred_at REAL NOT NULL,
                signal_id TEXT NOT NULL,
                feature_kind TEXT NOT NULL,
                bucket_seconds INTEGER NOT NULL,
                value_bucket TEXT NOT NULL,
                trend TEXT,
                volatility_bucket TEXT,
                state_label TEXT,
                session_id TEXT,
                metadata TEXT
            );
            CREATE INDEX IF NOT EXISTS idx_feature_points_time ON telemetry_feature_points(occurred_at, id);
            CREATE INDEX IF NOT EXISTS idx_feature_points_signal ON telemetry_feature_points(signal_id, occurred_at);
            CREATE INDEX IF NOT EXISTS idx_feature_points_session ON telemetry_feature_points(session_id, occurred_at);
            """
        )
        if currentVersion < 2, try !columnExists("is_live", in: "telemetry_events", db: db) {
            try execute(db, "ALTER TABLE telemetry_events ADD COLUMN is_live INTEGER;")
        }
        if currentVersion < 3 {
            try backfillCheckInMetadata(db)
        }
        try execute(db, "PRAGMA user_version = \(schemaVersion);")
    }

    static func backfillCheckInMetadata(_ db: OpaquePointer) throws {
        let checkInSQL = """
            SELECT id, session_id, metadata FROM telemetry_events
            WHERE category = 'check_in' AND session_id IS NOT NULL;
            """
        var checkInStatement: OpaquePointer?
        guard sqlite3_prepare_v2(db, checkInSQL, -1, &checkInStatement, nil) == SQLITE_OK else {
            throw errorFor(db)
        }
        defer { sqlite3_finalize(checkInStatement) }

        var checkIns: [CheckInRow] = []
        while true {
            switch sqlite3_step(checkInStatement) {
            case SQLITE_ROW:
                guard let id = columnText(checkInStatement, 0), let sessionId = columnText(checkInStatement, 1) else {
                    continue
                }
                checkIns.append(CheckInRow(
                    id: id,
                    sessionId: sessionId,
                    metadata: decodeMetadataLenient(columnText(checkInStatement, 2))
                ))
            case SQLITE_DONE:
                for checkIn in checkIns {
                    try backfillCheckInMetadata(checkIn, db: db)
                }
                return
            default:
                throw errorFor(db)
            }
        }
    }

    struct CheckInRow {
        let id: String
        let sessionId: String
        let metadata: [String: String]
    }

    static func backfillCheckInMetadata(
        _ checkIn: CheckInRow,
        db: OpaquePointer
    ) throws {
        let counts = try signalCounts(sessionId: checkIn.sessionId, db: db)
        guard counts.total > 0 else { return }

        var metadata = checkIn.metadata
        metadata["signals_live"] = String(counts.live)
        metadata["signals_total"] = String(counts.total)
        metadata["signed_signals_live"] = String(counts.signedLive)
        metadata["signed_signals_total"] = String(counts.signedTotal)
        metadata["observed_signals_live"] = String(counts.observedLive)
        metadata["observed_signals_total"] = String(counts.observedTotal)

        var updateStatement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "UPDATE telemetry_events SET metadata = ? WHERE id = ?;", -1, &updateStatement, nil) == SQLITE_OK,
              let updateStatement
        else {
            throw errorFor(db)
        }
        defer { sqlite3_finalize(updateStatement) }
        bindText(updateStatement, 1, encodeMetadata(metadata))
        bindText(updateStatement, 2, checkIn.id)
        guard sqlite3_step(updateStatement) == SQLITE_DONE else { throw errorFor(db) }
    }

    struct MigrationSignalCounts {
        var live = 0
        var total = 0
        var signedLive = 0
        var signedTotal = 0
        var observedLive = 0
        var observedTotal = 0
    }

    static func signalCounts(sessionId: String, db: OpaquePointer) throws -> MigrationSignalCounts {
        var statement: OpaquePointer?
        let sql = """
            SELECT is_live, metadata FROM telemetry_events
            WHERE category = 'life_signal' AND session_id = ?;
            """
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw errorFor(db)
        }
        defer { sqlite3_finalize(statement) }
        bindText(statement, 1, sessionId)

        var counts = MigrationSignalCounts()
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                let isLive = sqlite3_column_type(statement, 0) != SQLITE_NULL && sqlite3_column_int(statement, 0) != 0
                let metadata = decodeMetadataLenient(columnText(statement, 1))
                let isSigned = metadata["source"] == "signed"
                let isObserved = metadata["observed"] != "false"

                counts.total += 1
                if isLive { counts.live += 1 }
                if isSigned {
                    counts.signedTotal += 1
                    if isLive { counts.signedLive += 1 }
                }
                if isObserved {
                    counts.observedTotal += 1
                    if isLive { counts.observedLive += 1 }
                }
            case SQLITE_DONE:
                return counts
            default:
                throw errorFor(db)
            }
        }
    }

    private static func columnExists(_ column: String, in table: String, db: OpaquePointer) throws -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table));", -1, &statement, nil) == SQLITE_OK else {
            throw errorFor(db)
        }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let rawName = sqlite3_column_text(statement, 1) else { continue }
            if String(cString: rawName) == column { return true }
        }
        return false
    }

    private static func userVersion(_ db: OpaquePointer) throws -> Int32 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &statement, nil) == SQLITE_OK else {
            throw errorFor(db)
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return sqlite3_column_int(statement, 0)
    }

    // internal (not private): also called from TelemetryStore+Decoding.swift.
    static func execute(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw errorFor(db) }
    }

    static func errorFor(_ db: OpaquePointer) -> KenshikiPulseError {
        .storageFailed(String(cString: sqlite3_errmsg(db)))
    }

    static func sqlLimit(_ limit: Int) -> Int32 {
        Int32(Swift.max(0, Swift.min(limit, Int(maxQueryLimit))))
    }

}
