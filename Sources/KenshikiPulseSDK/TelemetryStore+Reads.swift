import Foundation
import SQLite3

// MARK: - Reads

extension SQLiteTelemetryStore {

    public func recent(limit: Int) async throws -> [TelemetryEvent] {
        let statement = try prepare(
            "SELECT \(Self.columns) FROM telemetry_events ORDER BY occurred_at DESC, id DESC LIMIT ?;"
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Self.sqlLimit(limit))
        return try rows(from: statement)
    }

    public func events(in interval: DateInterval) async throws -> [TelemetryEvent] {
        let statement = try prepare(
            """
            SELECT \(Self.columns) FROM telemetry_events
            WHERE occurred_at >= ? AND occurred_at < ?
            ORDER BY occurred_at ASC, id ASC;
            """
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, interval.start.timeIntervalSince1970)
        sqlite3_bind_double(statement, 2, interval.end.timeIntervalSince1970)
        return try rows(from: statement)
    }

    public func events(category: TelemetryEventCategory, limit: Int) async throws -> [TelemetryEvent] {
        let statement = try prepare(
            """
            SELECT \(Self.columns) FROM telemetry_events
            WHERE category = ?
            ORDER BY occurred_at DESC, id DESC LIMIT ?;
            """
        )
        defer { sqlite3_finalize(statement) }
        bindText(statement, 1, category.rawValue)
        sqlite3_bind_int(statement, 2, Self.sqlLimit(limit))
        return try rows(from: statement)
    }

    public func count() async throws -> Int {
        let statement = try prepare("SELECT COUNT(*) FROM telemetry_events;")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    public func timeline(in interval: DateInterval, limit: Int) async throws -> [TelemetryEvent] {
        let statement = try prepare(
            """
            SELECT \(Self.columns) FROM telemetry_events
            WHERE occurred_at >= ? AND occurred_at < ?
            ORDER BY occurred_at DESC, id DESC LIMIT ?;
            """
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, interval.start.timeIntervalSince1970)
        sqlite3_bind_double(statement, 2, interval.end.timeIntervalSince1970)
        sqlite3_bind_int(statement, 3, Self.sqlLimit(limit))
        return try rows(from: statement)
    }

    public func checkIns(in interval: DateInterval, limit: Int) async throws -> [CheckInRecord] {
        let statement = try prepare(
            """
            SELECT \(Self.columns) FROM telemetry_events
            WHERE category = ? AND session_id IS NOT NULL AND occurred_at >= ? AND occurred_at < ?
            ORDER BY occurred_at DESC, id DESC LIMIT ?;
            """
        )
        defer { sqlite3_finalize(statement) }
        bindText(statement, 1, TelemetryEventCategory.checkIn.rawValue)
        sqlite3_bind_double(statement, 2, interval.start.timeIntervalSince1970)
        sqlite3_bind_double(statement, 3, interval.end.timeIntervalSince1970)
        sqlite3_bind_int(statement, 4, Self.sqlLimit(limit))
        return try rows(from: statement).compactMap(Self.checkInRecord(from:))
    }

    public func signalSeries(signalId: String, in interval: DateInterval) async throws -> [SignalPoint] {
        let statement = try prepare(
            """
            SELECT \(Self.columns) FROM telemetry_events
            WHERE category = ? AND signal_id = ? AND occurred_at >= ? AND occurred_at < ?
            ORDER BY occurred_at ASC, id ASC;
            """
        )
        defer { sqlite3_finalize(statement) }
        bindText(statement, 1, TelemetryEventCategory.lifeSignal.rawValue)
        bindText(statement, 2, signalId)
        sqlite3_bind_double(statement, 3, interval.start.timeIntervalSince1970)
        sqlite3_bind_double(statement, 4, interval.end.timeIntervalSince1970)
        return try rows(from: statement).map(Self.signalPoint(from:))
    }

    public func dailySummary(in interval: DateInterval) async throws -> [ContinuityDaySummary] {
        let events = try await events(in: interval)
        return Self.summarizeDays(events: events, dayStart: Self.utcDayStart(for:))
    }

    public func localDailySummary(in interval: DateInterval, calendar: Calendar) async throws -> [ContinuityDaySummary] {
        let events = try await events(in: interval)
        var localCalendar = calendar
        if localCalendar.timeZone.identifier.isEmpty { localCalendar.timeZone = .current }
        return Self.summarizeDays(events: events) { date in
            localCalendar.startOfDay(for: date)
        }
    }

    private static func summarizeDays(
        events: [TelemetryEvent],
        dayStart: (Date) -> Date
    ) -> [ContinuityDaySummary] {
        var byDay: [Date: DayAccumulator] = [:]
        for event in events {
            let day = dayStart(event.occurredAt)
            var accumulator = byDay[day] ?? DayAccumulator()
            switch event.category {
            case .checkIn:
                accumulator.checkInCount += 1
            case .breakEvent:
                accumulator.breakCount += 1
            case .lifeSignal:
                accumulator.totalSignalCount += 1
                if event.isLive == true { accumulator.liveSignalCount += 1 }
            case .stateTransition, .continuityLog:
                break
            }
            byDay[day] = accumulator
        }
        return byDay.keys.sorted().map { day in
            let value = byDay[day] ?? DayAccumulator()
            return ContinuityDaySummary(
                dayStart: day,
                checkInCount: value.checkInCount,
                breakCount: value.breakCount,
                liveSignalCount: value.liveSignalCount,
                totalSignalCount: value.totalSignalCount
            )
        }
    }

    public func breaks(in interval: DateInterval, limit: Int) async throws -> [TelemetryEvent] {
        let statement = try prepare(
            """
            SELECT \(Self.columns) FROM telemetry_events
            WHERE category = ? AND occurred_at >= ? AND occurred_at < ?
            ORDER BY occurred_at DESC, id DESC LIMIT ?;
            """
        )
        defer { sqlite3_finalize(statement) }
        bindText(statement, 1, TelemetryEventCategory.breakEvent.rawValue)
        sqlite3_bind_double(statement, 2, interval.start.timeIntervalSince1970)
        sqlite3_bind_double(statement, 3, interval.end.timeIntervalSince1970)
        sqlite3_bind_int(statement, 4, Self.sqlLimit(limit))
        return try rows(from: statement)
    }

    public func stateTransitions(in interval: DateInterval, limit: Int) async throws -> [TelemetryEvent] {
        let statement = try prepare(
            """
            SELECT \(Self.columns) FROM telemetry_events
            WHERE category = ? AND occurred_at >= ? AND occurred_at < ?
            ORDER BY occurred_at DESC, id DESC LIMIT ?;
            """
        )
        defer { sqlite3_finalize(statement) }
        bindText(statement, 1, TelemetryEventCategory.stateTransition.rawValue)
        sqlite3_bind_double(statement, 2, interval.start.timeIntervalSince1970)
        sqlite3_bind_double(statement, 3, interval.end.timeIntervalSince1970)
        sqlite3_bind_int(statement, 4, Self.sqlLimit(limit))
        return try rows(from: statement)
    }

    public func featureSeries(signalId: String, in interval: DateInterval) async throws -> [TelemetryFeaturePoint] {
        let statement = try prepare(
            """
            SELECT \(Self.featureColumns) FROM telemetry_feature_points
            WHERE signal_id = ? AND occurred_at >= ? AND occurred_at < ?
            ORDER BY occurred_at ASC, id ASC;
            """
        )
        defer { sqlite3_finalize(statement) }
        bindText(statement, 1, signalId)
        sqlite3_bind_double(statement, 2, interval.start.timeIntervalSince1970)
        sqlite3_bind_double(statement, 3, interval.end.timeIntervalSince1970)
        return try featureRows(from: statement)
    }

    public func featurePoints(in interval: DateInterval, limit: Int) async throws -> [TelemetryFeaturePoint] {
        let statement = try prepare(
            """
            SELECT \(Self.featureColumns) FROM telemetry_feature_points
            WHERE occurred_at >= ? AND occurred_at < ?
            ORDER BY occurred_at ASC, id ASC LIMIT ?;
            """
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, interval.start.timeIntervalSince1970)
        sqlite3_bind_double(statement, 2, interval.end.timeIntervalSince1970)
        sqlite3_bind_int(statement, 3, Self.sqlLimit(limit))
        return try featureRows(from: statement)
    }

    public func exportBatch(after cursor: TelemetryExportCursor?, limit: Int) async throws -> TelemetryExportBatch {
        let pageSize = Self.sqlLimit(limit)
        guard pageSize > 0 else { return TelemetryExportBatch(events: [], nextCursor: cursor) }

        let statement: OpaquePointer
        if let localSequence = cursor?.localSequence {
            statement = try prepare(
                """
                SELECT rowid, \(Self.columns) FROM telemetry_events
                WHERE rowid > ?
                ORDER BY rowid ASC LIMIT ?;
                """
            )
            sqlite3_bind_int64(statement, 1, localSequence)
            sqlite3_bind_int(statement, 2, pageSize)
        } else if let cursor {
            statement = try prepare(
                """
                SELECT rowid, \(Self.columns) FROM telemetry_events
                WHERE occurred_at > ? OR (occurred_at = ? AND id > ?)
                ORDER BY occurred_at ASC, id ASC LIMIT ?;
                """
            )
            sqlite3_bind_double(statement, 1, cursor.occurredAt.timeIntervalSince1970)
            sqlite3_bind_double(statement, 2, cursor.occurredAt.timeIntervalSince1970)
            bindText(statement, 3, cursor.eventId)
            sqlite3_bind_int(statement, 4, pageSize)
        } else {
            statement = try prepare(
                """
                SELECT rowid, \(Self.columns) FROM telemetry_events
                ORDER BY rowid ASC LIMIT ?;
                """
            )
            sqlite3_bind_int(statement, 1, pageSize)
        }
        defer { sqlite3_finalize(statement) }

        let rows = try exportRows(from: statement)
        let events = rows.map { $0.event }
        let nextCursor = rows.last.map { row in
            TelemetryExportCursor(occurredAt: row.event.occurredAt, eventId: row.event.id, localSequence: row.localSequence)
        }
        return TelemetryExportBatch(events: events, nextCursor: nextCursor)
    }

    public func exportFeatureBatch(
        after cursor: TelemetryFeatureExportCursor?,
        limit: Int
    ) async throws -> TelemetryFeatureExportBatch {
        let pageSize = Self.sqlLimit(limit)
        guard pageSize > 0 else { return TelemetryFeatureExportBatch(featurePoints: [], nextCursor: cursor) }

        let statement: OpaquePointer
        if let localSequence = cursor?.localSequence {
            statement = try prepare(
                """
                SELECT rowid, \(Self.featureColumns) FROM telemetry_feature_points
                WHERE rowid > ?
                ORDER BY rowid ASC LIMIT ?;
                """
            )
            sqlite3_bind_int64(statement, 1, localSequence)
            sqlite3_bind_int(statement, 2, pageSize)
        } else if let cursor {
            statement = try prepare(
                """
                SELECT rowid, \(Self.featureColumns) FROM telemetry_feature_points
                WHERE occurred_at > ? OR (occurred_at = ? AND id > ?)
                ORDER BY occurred_at ASC, id ASC LIMIT ?;
                """
            )
            sqlite3_bind_double(statement, 1, cursor.occurredAt.timeIntervalSince1970)
            sqlite3_bind_double(statement, 2, cursor.occurredAt.timeIntervalSince1970)
            bindText(statement, 3, cursor.pointId)
            sqlite3_bind_int(statement, 4, pageSize)
        } else {
            statement = try prepare(
                """
                SELECT rowid, \(Self.featureColumns) FROM telemetry_feature_points
                ORDER BY rowid ASC LIMIT ?;
                """
            )
            sqlite3_bind_int(statement, 1, pageSize)
        }
        defer { sqlite3_finalize(statement) }

        let rows = try featureExportRows(from: statement)
        let points = rows.map { $0.point }
        let nextCursor = rows.last.map { row in
            TelemetryFeatureExportCursor(
                occurredAt: row.point.occurredAt,
                pointId: row.point.id,
                localSequence: row.localSequence
            )
        }
        return TelemetryFeatureExportBatch(featurePoints: points, nextCursor: nextCursor)
    }

    /// Longitudinal continuity over `interval`: distinct check-ins and per-signal liveness rates,
    /// computed from `life_signal` events. This is the 3/7/30-day "continuity of life" read.
    public func windowSummary(in interval: DateInterval) async throws -> ContinuityWindowSummary {
        let start = interval.start.timeIntervalSince1970
        let end = interval.end.timeIntervalSince1970

        let checkInStatement = try prepare(
            """
            SELECT COUNT(DISTINCT session_id) FROM telemetry_events
            WHERE category = ? AND session_id IS NOT NULL AND occurred_at >= ? AND occurred_at < ?;
            """
        )
        defer { sqlite3_finalize(checkInStatement) }
        bindText(checkInStatement, 1, TelemetryEventCategory.checkIn.rawValue)
        sqlite3_bind_double(checkInStatement, 2, start)
        sqlite3_bind_double(checkInStatement, 3, end)
        let checkInCount = sqlite3_step(checkInStatement) == SQLITE_ROW
            ? Int(sqlite3_column_int64(checkInStatement, 0)) : 0

        let livenessStatement = try prepare(
            """
            SELECT signal_id,
                   SUM(CASE WHEN is_live = 1 THEN 1 ELSE 0 END),
                   COUNT(*)
            FROM telemetry_events
            WHERE category = ? AND signal_id IS NOT NULL AND occurred_at >= ? AND occurred_at < ?
            GROUP BY signal_id
            ORDER BY signal_id ASC;
            """
        )
        defer { sqlite3_finalize(livenessStatement) }
        bindText(livenessStatement, 1, TelemetryEventCategory.lifeSignal.rawValue)
        sqlite3_bind_double(livenessStatement, 2, start)
        sqlite3_bind_double(livenessStatement, 3, end)

        var signals: [SignalLiveness] = []
        while true {
            switch sqlite3_step(livenessStatement) {
            case SQLITE_ROW:
                signals.append(SignalLiveness(
                    signalId: columnText(livenessStatement, 0) ?? "",
                    liveCount: Int(sqlite3_column_int64(livenessStatement, 1)),
                    totalCount: Int(sqlite3_column_int64(livenessStatement, 2))
                ))
            case SQLITE_DONE:
                return ContinuityWindowSummary(interval: interval, checkInCount: checkInCount, signals: signals)
            default:
                throw lastError()
            }
        }
    }

}
