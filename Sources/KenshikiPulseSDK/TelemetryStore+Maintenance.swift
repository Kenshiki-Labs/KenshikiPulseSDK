import Foundation
import SQLite3

// MARK: - Maintenance

extension SQLiteTelemetryStore {

    @discardableResult
    public func prune(keepingMostRecent maxRows: Int) async throws -> Int {
        let keep = Self.sqlLimit(maxRows)
        let statement = try prepare(
            """
            DELETE FROM telemetry_events WHERE id NOT IN (
                SELECT id FROM telemetry_events ORDER BY occurred_at DESC, id DESC LIMIT ?
            );
            """
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, keep)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError() }
        return Int(sqlite3_changes(db))
    }

    @discardableResult
    public func prune(olderThan cutoff: Date) async throws -> Int {
        let eventStatement = try prepare("DELETE FROM telemetry_events WHERE occurred_at < ?;")
        defer { sqlite3_finalize(eventStatement) }
        sqlite3_bind_double(eventStatement, 1, cutoff.timeIntervalSince1970)
        guard sqlite3_step(eventStatement) == SQLITE_DONE else { throw lastError() }
        let deletedEvents = Int(sqlite3_changes(db))

        let featureStatement = try prepare("DELETE FROM telemetry_feature_points WHERE occurred_at < ?;")
        defer { sqlite3_finalize(featureStatement) }
        sqlite3_bind_double(featureStatement, 1, cutoff.timeIntervalSince1970)
        guard sqlite3_step(featureStatement) == SQLITE_DONE else { throw lastError() }
        let deleted = deletedEvents + Int(sqlite3_changes(db))
        if deleted > 0 { try checkpointWal() }
        return deleted
    }

    public func clear() async throws {
        try exec("DELETE FROM telemetry_events;")
        try exec("DELETE FROM telemetry_feature_points;")
        try checkpointWal()
    }

    private func checkpointWal() throws {
        try exec("PRAGMA wal_checkpoint(TRUNCATE);")
    }

}
