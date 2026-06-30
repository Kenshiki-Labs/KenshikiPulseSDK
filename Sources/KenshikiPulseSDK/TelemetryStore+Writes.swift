import Foundation
import SQLite3

// MARK: - Writes

extension SQLiteTelemetryStore {

    public func append(_ event: TelemetryEvent) async throws {
        try insert(event)
    }

    public func append(contentsOf events: [TelemetryEvent]) async throws {
        guard !events.isEmpty else { return }
        try exec("BEGIN TRANSACTION;")
        do {
            for event in events { try insert(event) }
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    public func append(_ point: TelemetryFeaturePoint) async throws {
        try insert(point)
    }

    public func append(contentsOf points: [TelemetryFeaturePoint]) async throws {
        guard !points.isEmpty else { return }
        try exec("BEGIN TRANSACTION;")
        do {
            for point in points { try insert(point) }
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    private func insert(_ event: TelemetryEvent) throws {
        try validate(event)
        let sql = """
            INSERT OR IGNORE INTO telemetry_events
                (id, occurred_at, category, severity, signal_id, title, detail, session_id, merkle_root, is_live, metadata)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        bindText(statement, 1, event.id)
        sqlite3_bind_double(statement, 2, event.occurredAt.timeIntervalSince1970)
        bindText(statement, 3, event.category.rawValue)
        bindText(statement, 4, event.severity.rawValue)
        bindText(statement, 5, event.signalId)
        bindText(statement, 6, event.title)
        bindText(statement, 7, event.detail)
        bindText(statement, 8, event.sessionId)
        bindText(statement, 9, event.merkleRoot)
        if let isLive = event.isLive {
            sqlite3_bind_int(statement, 10, isLive ? 1 : 0)
        } else {
            sqlite3_bind_null(statement, 10)
        }
        bindText(statement, 11, Self.encodeMetadata(event.metadata))

        guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError() }
        if sqlite3_changes(db) == 0 {
            try verifyExistingEventMatches(event)
        }
    }

    private func insert(_ point: TelemetryFeaturePoint) throws {
        try validate(point)
        let sql = """
            INSERT OR IGNORE INTO telemetry_feature_points
                (id, occurred_at, signal_id, feature_kind, bucket_seconds, value_bucket,
                 trend, volatility_bucket, state_label, session_id, metadata)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        bindText(statement, 1, point.id)
        sqlite3_bind_double(statement, 2, point.occurredAt.timeIntervalSince1970)
        bindText(statement, 3, point.signalId)
        bindText(statement, 4, point.featureKind)
        sqlite3_bind_int(statement, 5, Int32(max(1, point.bucketSeconds)))
        bindText(statement, 6, point.valueBucket)
        bindText(statement, 7, point.trend)
        bindText(statement, 8, point.volatilityBucket)
        bindText(statement, 9, point.stateLabel)
        bindText(statement, 10, point.sessionId)
        bindText(statement, 11, Self.encodeMetadata(point.metadata))

        guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError() }
        if sqlite3_changes(db) == 0 {
            try verifyExistingFeaturePointMatches(point)
        }
    }

    private func verifyExistingEventMatches(_ event: TelemetryEvent) throws {
        let statement = try prepare("SELECT \(Self.columns) FROM telemetry_events WHERE id = ? LIMIT 1;")
        defer { sqlite3_finalize(statement) }
        bindText(statement, 1, event.id)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw KenshikiPulseError.storageFailed("duplicate telemetry event missing: \(event.id)")
        }
        guard try decodeRow(statement) == event else {
            throw KenshikiPulseError.storageFailed("telemetry event id collision with different payload: \(event.id)")
        }
    }

    private func verifyExistingFeaturePointMatches(_ point: TelemetryFeaturePoint) throws {
        let statement = try prepare("SELECT \(Self.featureColumns) FROM telemetry_feature_points WHERE id = ? LIMIT 1;")
        defer { sqlite3_finalize(statement) }
        bindText(statement, 1, point.id)
        guard sqlite3_step(statement) == SQLITE_ROW else { throw KenshikiPulseError.storageFailed("duplicate feature point missing: \(point.id)") }
        guard try decodeFeatureRow(statement) == point else {
            throw KenshikiPulseError.storageFailed("feature point id collision with different payload: \(point.id)")
        }
    }

    private func validate(_ event: TelemetryEvent) throws {
        try validateText(event.id, field: "id", maxLength: 160)
        try validateText(event.signalId, field: "signal_id", maxLength: 80)
        try validateText(event.title, field: "title", maxLength: 160)
        try validateText(event.detail, field: "detail", maxLength: 1_000)
        try validateText(event.sessionId, field: "session_id", maxLength: 120)
        try validateText(event.merkleRoot, field: "merkle_root", maxLength: 256)
        try validateMetadata(event.metadata, allowedKeys: Self.allowedEventMetadataKeys, label: "event")
    }

    private func validate(_ point: TelemetryFeaturePoint) throws {
        try validateText(point.id, field: "id", maxLength: 160)
        try validateText(point.signalId, field: "signal_id", maxLength: 80)
        try validateText(point.featureKind, field: "feature_kind", maxLength: 80)
        try validateText(point.valueBucket, field: "value_bucket", maxLength: 80)
        try validateText(point.trend, field: "trend", maxLength: 80)
        try validateText(point.volatilityBucket, field: "volatility_bucket", maxLength: 80)
        try validateText(point.stateLabel, field: "state_label", maxLength: 120)
        try validateText(point.sessionId, field: "session_id", maxLength: 120)
        guard point.bucketSeconds > 0, point.bucketSeconds <= 86_400 else {
            throw KenshikiPulseError.storageFailed("feature point bucket_seconds out of bounds")
        }
        try validateMetadata(point.metadata, allowedKeys: Self.allowedFeatureMetadataKeys, label: "feature point")
    }

    private func validateText(_ value: String?, field: String, maxLength: Int) throws {
        guard let value else { return }
        guard !value.contains("\u{0}"), value.count <= maxLength else {
            throw KenshikiPulseError.storageFailed("telemetry \(field) is out of bounds")
        }
    }

    private func validateMetadata(_ metadata: [String: String], allowedKeys: Set<String>, label: String) throws {
        let unexpected = Set(metadata.keys).subtracting(allowedKeys)
        guard unexpected.isEmpty else {
            throw KenshikiPulseError.storageFailed("unexpected \(label) metadata keys: \(unexpected.sorted().joined(separator: ","))")
        }
        for (key, value) in metadata {
            try validateText(key, field: "metadata key", maxLength: 80)
            try validateText(value, field: "metadata value", maxLength: 256)
        }
    }

}
