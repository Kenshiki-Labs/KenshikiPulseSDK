import Foundation
import SQLite3

// MARK: - Row decoding

extension SQLiteTelemetryStore {

    static let columns =
        "id, occurred_at, category, severity, signal_id, title, detail, session_id, merkle_root, is_live, metadata"

    static let featureColumns =
        "id, occurred_at, signal_id, feature_kind, bucket_seconds, value_bucket, trend, "
        + "volatility_bucket, state_label, session_id, metadata"

    func rows(from statement: OpaquePointer) throws -> [TelemetryEvent] {
        var events: [TelemetryEvent] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                events.append(try decodeRow(statement))
            case SQLITE_DONE:
                return events
            default:
                throw lastError()
            }
        }
    }

    func decodeRow(_ statement: OpaquePointer) throws -> TelemetryEvent {
        let rawCategory = columnText(statement, 2) ?? ""
        let rawSeverity = columnText(statement, 3) ?? ""
        guard let category = TelemetryEventCategory(rawValue: rawCategory) else {
            throw KenshikiPulseError.storageFailed("corrupt telemetry category: \(rawCategory)")
        }
        guard let severity = TelemetrySeverity(rawValue: rawSeverity) else {
            throw KenshikiPulseError.storageFailed("corrupt telemetry severity: \(rawSeverity)")
        }
        return TelemetryEvent(
            id: columnText(statement, 0) ?? "",
            occurredAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
            category: category,
            severity: severity,
            signalId: columnText(statement, 4),
            title: columnText(statement, 5) ?? "",
            detail: columnText(statement, 6) ?? "",
            sessionId: columnText(statement, 7),
            merkleRoot: columnText(statement, 8),
            isLive: columnBool(statement, 9),
            metadata: try Self.decodeMetadata(columnText(statement, 10))
        )
    }

    func exportRows(from statement: OpaquePointer) throws -> [(localSequence: Int64, event: TelemetryEvent)] {
        var rows: [(localSequence: Int64, event: TelemetryEvent)] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                rows.append((
                    localSequence: sqlite3_column_int64(statement, 0),
                    event: try decodeRow(statement, offset: 1)
                ))
            case SQLITE_DONE:
                return rows
            default:
                throw lastError()
            }
        }
    }

    func decodeRow(_ statement: OpaquePointer, offset: Int32) throws -> TelemetryEvent {
        let rawCategory = columnText(statement, offset + 2) ?? ""
        let rawSeverity = columnText(statement, offset + 3) ?? ""
        guard let category = TelemetryEventCategory(rawValue: rawCategory) else {
            throw KenshikiPulseError.storageFailed("corrupt telemetry category: \(rawCategory)")
        }
        guard let severity = TelemetrySeverity(rawValue: rawSeverity) else {
            throw KenshikiPulseError.storageFailed("corrupt telemetry severity: \(rawSeverity)")
        }
        return TelemetryEvent(
            id: columnText(statement, offset + 0) ?? "",
            occurredAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, offset + 1)),
            category: category,
            severity: severity,
            signalId: columnText(statement, offset + 4),
            title: columnText(statement, offset + 5) ?? "",
            detail: columnText(statement, offset + 6) ?? "",
            sessionId: columnText(statement, offset + 7),
            merkleRoot: columnText(statement, offset + 8),
            isLive: columnBool(statement, offset + 9),
            metadata: try Self.decodeMetadata(columnText(statement, offset + 10))
        )
    }

    func featureRows(from statement: OpaquePointer) throws -> [TelemetryFeaturePoint] {
        var points: [TelemetryFeaturePoint] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                points.append(try decodeFeatureRow(statement))
            case SQLITE_DONE:
                return points
            default:
                throw lastError()
            }
        }
    }

    func decodeFeatureRow(_ statement: OpaquePointer) throws -> TelemetryFeaturePoint {
        TelemetryFeaturePoint(
            id: columnText(statement, 0) ?? "",
            occurredAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
            signalId: columnText(statement, 2) ?? "",
            featureKind: columnText(statement, 3) ?? "",
            bucketSeconds: Int(sqlite3_column_int64(statement, 4)),
            valueBucket: columnText(statement, 5) ?? "",
            trend: columnText(statement, 6),
            volatilityBucket: columnText(statement, 7),
            stateLabel: columnText(statement, 8),
            sessionId: columnText(statement, 9),
            metadata: try Self.decodeMetadata(columnText(statement, 10))
        )
    }

    func featureExportRows(
        from statement: OpaquePointer
    ) throws -> [(localSequence: Int64, point: TelemetryFeaturePoint)] {
        var rows: [(localSequence: Int64, point: TelemetryFeaturePoint)] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                rows.append((
                    localSequence: sqlite3_column_int64(statement, 0),
                    point: try decodeFeatureRow(statement, offset: 1)
                ))
            case SQLITE_DONE:
                return rows
            default:
                throw lastError()
            }
        }
    }

    func decodeFeatureRow(_ statement: OpaquePointer, offset: Int32) throws -> TelemetryFeaturePoint {
        TelemetryFeaturePoint(
            id: columnText(statement, offset + 0) ?? "",
            occurredAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, offset + 1)),
            signalId: columnText(statement, offset + 2) ?? "",
            featureKind: columnText(statement, offset + 3) ?? "",
            bucketSeconds: Int(sqlite3_column_int64(statement, offset + 4)),
            valueBucket: columnText(statement, offset + 5) ?? "",
            trend: columnText(statement, offset + 6),
            volatilityBucket: columnText(statement, offset + 7),
            stateLabel: columnText(statement, offset + 8),
            sessionId: columnText(statement, offset + 9),
            metadata: try Self.decodeMetadata(columnText(statement, offset + 10))
        )
    }

    func columnBool(_ statement: OpaquePointer, _ index: Int32) -> Bool? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_int(statement, index) != 0
    }

    static func checkInRecord(from event: TelemetryEvent) -> CheckInRecord? {
        guard event.category == .checkIn, let sessionId = event.sessionId else { return nil }
        return CheckInRecord(
            id: event.id,
            sessionId: sessionId,
            occurredAt: event.occurredAt,
            outcome: event.title,
            severity: event.severity,
            merkleRoot: event.merkleRoot,
            signalsLive: event.metadata["signals_live"].flatMap(Int.init),
            signalsTotal: event.metadata["signals_total"].flatMap(Int.init),
            signedSignalsLive: event.metadata["signed_signals_live"].flatMap(Int.init),
            signedSignalsTotal: event.metadata["signed_signals_total"].flatMap(Int.init),
            observedSignalsLive: event.metadata["observed_signals_live"].flatMap(Int.init),
            observedSignalsTotal: event.metadata["observed_signals_total"].flatMap(Int.init),
            captureSource: event.metadata["capture_source"],
            captureQuality: event.metadata["capture_quality"],
            captureObserved: event.metadata["capture_observed"].flatMap(Int.init),
            captureLagMilliseconds: event.metadata["capture_lag_ms"].flatMap(Int.init)
        )
    }

    static func signalPoint(from event: TelemetryEvent) -> SignalPoint {
        SignalPoint(
            signalId: event.signalId ?? "",
            occurredAt: event.occurredAt,
            sessionId: event.sessionId,
            isLive: event.isLive == true,
            source: event.metadata["source"]
        )
    }

    struct DayAccumulator {
        var checkInCount = 0
        var breakCount = 0
        var liveSignalCount = 0
        var totalSignalCount = 0
    }

    static func utcDayStart(for date: Date) -> Date {
        Date(timeIntervalSince1970: floor(date.timeIntervalSince1970 / 86_400) * 86_400)
    }

}

// MARK: - SQLite helpers

extension SQLiteTelemetryStore {

    func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw lastError()
        }
        return statement
    }

    func exec(_ sql: String) throws {
        guard let db else { throw KenshikiPulseError.storageFailed("database is closed") }
        try Self.execute(db, sql)
    }

    func bindText(_ statement: OpaquePointer, _ index: Int32, _ value: String?) {
        Self.bindText(statement, index, value)
    }

    func columnText(_ statement: OpaquePointer, _ index: Int32) -> String? {
        Self.columnText(statement, index)
    }

    static func bindText(_ statement: OpaquePointer, _ index: Int32, _ value: String?) {
        if let value {
            sqlite3_bind_text(statement, index, value, -1, transient)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    static func columnText(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard let statement else { return nil }
        guard let cString = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: cString)
    }

    func lastError() -> KenshikiPulseError {
        .storageFailed(db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown SQLite error")
    }

    static func encodeMetadata(_ metadata: [String: String]) -> String? {
        guard !metadata.isEmpty, let data = try? JSONEncoder().encode(metadata) else { return nil }
        return String(bytes: data, encoding: .utf8)
    }

    static func decodeMetadata(_ raw: String?) throws -> [String: String] {
        guard let raw else { return [:] }
        guard let data = raw.data(using: .utf8) else {
            throw KenshikiPulseError.storageFailed("corrupt telemetry metadata encoding")
        }
        do {
            return try JSONDecoder().decode([String: String].self, from: data)
        } catch {
            throw KenshikiPulseError.storageFailed("corrupt telemetry metadata JSON: \(error.localizedDescription)")
        }
    }

    static func decodeMetadataLenient(_ raw: String?) -> [String: String] {
        guard let raw, let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return decoded
    }
}
