import XCTest
import SQLite3
@testable import KenshikiPulseSDK

final class TelemetryStoreTests: XCTestCase {
    private func makeEvent(
        id: String = UUID().uuidString,
        offset: TimeInterval,
        category: TelemetryEventCategory = .lifeSignal,
        severity: TelemetrySeverity = .ok,
        signalId: String? = "motion"
    ) -> TelemetryEvent {
        TelemetryEvent(
            id: id,
            occurredAt: Date(timeIntervalSince1970: 1_700_000_000 + offset),
            category: category,
            severity: severity,
            signalId: signalId,
            title: "Movement looks human",
            detail: "1.2 g over the window.",
            sessionId: "session-1",
            merkleRoot: "root-abc",
            metadata: ["signals_live": "10", "signals_total": "10"]
        )
    }

    func testAppendAndRecentReturnsMostRecentFirst() async throws {
        let store = try SQLiteTelemetryStore(url: nil)
        try await store.append(makeEvent(id: "a", offset: 0))
        try await store.append(makeEvent(id: "b", offset: 60))
        try await store.append(makeEvent(id: "c", offset: 120))

        let recent = try await store.recent(limit: 2)
        XCTAssertEqual(recent.map(\.id), ["c", "b"])
        let total = try await store.count()
        XCTAssertEqual(total, 3)
    }

    func testRoundTripPreservesAllFields() async throws {
        let store = try SQLiteTelemetryStore(url: nil)
        let event = makeEvent(id: "a", offset: 0, category: .breakEvent, severity: .danger, signalId: "sim_swap")
        try await store.append(event)

        let loaded = try await store.recent(limit: 1).first
        XCTAssertEqual(loaded, event)
    }

    func testEventsInIntervalAreOldestFirstAndBounded() async throws {
        let store = try SQLiteTelemetryStore(url: nil)
        try await store.append(contentsOf: [
            makeEvent(id: "a", offset: 0),
            makeEvent(id: "b", offset: 100),
            makeEvent(id: "c", offset: 200),
            makeEvent(id: "d", offset: 300),
        ])

        let interval = DateInterval(
            start: Date(timeIntervalSince1970: 1_700_000_050),
            end: Date(timeIntervalSince1970: 1_700_000_250)
        )
        let events = try await store.events(in: interval)
        XCTAssertEqual(events.map(\.id), ["b", "c"])
    }

    func testIntervalEndIsExclusive() async throws {
        let store = try SQLiteTelemetryStore(url: nil)
        try await store.append(contentsOf: [
            makeEvent(id: "inside", offset: 99),
            makeEvent(id: "boundary", offset: 100),
        ])

        let interval = DateInterval(start: at(0), end: at(100))
        let events = try await store.events(in: interval)
        XCTAssertEqual(events.map(\.id), ["inside"])
    }

    func testEventsByCategoryFilters() async throws {
        let store = try SQLiteTelemetryStore(url: nil)
        try await store.append(makeEvent(id: "a", offset: 0, category: .lifeSignal))
        try await store.append(makeEvent(id: "b", offset: 60, category: .breakEvent, signalId: "device_change"))
        try await store.append(makeEvent(id: "c", offset: 120, category: .checkIn, signalId: nil))

        let breaks = try await store.events(category: .breakEvent, limit: 10)
        XCTAssertEqual(breaks.map(\.id), ["b"])
    }

    func testPruneKeepsNewest() async throws {
        let store = try SQLiteTelemetryStore(url: nil)
        for index in 0..<10 {
            try await store.append(makeEvent(id: "e\(index)", offset: TimeInterval(index) * 60))
        }
        let deleted = try await store.prune(keepingMostRecent: 3)
        XCTAssertEqual(deleted, 7)

        let remaining = try await store.recent(limit: 100)
        XCTAssertEqual(remaining.map(\.id), ["e9", "e8", "e7"])
    }

    func testPruneOlderThanRemovesOnlyEventsBeforeCutoff() async throws {
        let store = try SQLiteTelemetryStore(url: nil)
        let base: TimeInterval = 1_700_000_000
        try await store.append(makeEvent(id: "old1", offset: 0))            // base
        try await store.append(makeEvent(id: "old2", offset: 100))          // base+100
        try await store.append(makeEvent(id: "keep1", offset: 1_000))       // base+1000
        try await store.append(makeEvent(id: "keep2", offset: 2_000))       // base+2000

        let cutoff = Date(timeIntervalSince1970: base + 500)
        let deleted = try await store.prune(olderThan: cutoff)
        XCTAssertEqual(deleted, 2)

        let remaining = try await store.recent(limit: 100)
        XCTAssertEqual(Set(remaining.map(\.id)), ["keep1", "keep2"])
    }

    func testClearEmptiesStore() async throws {
        let store = try SQLiteTelemetryStore(url: nil)
        try await store.append(makeEvent(id: "a", offset: 0))
        try await store.clear()
        let total = try await store.count()
        XCTAssertEqual(total, 0)
    }

    func testPersistsAcrossReopen() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kenshiki-telemetry-\(UUID().uuidString).sqlite3")
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: url.path + suffix)
            }
        }

        let writer = try SQLiteTelemetryStore(url: url)
        try await writer.append(makeEvent(id: "persisted", offset: 0))

        let reader = try SQLiteTelemetryStore(url: url)
        let loaded = try await reader.recent(limit: 10)
        XCTAssertEqual(loaded.map(\.id), ["persisted"])
    }

    func testRecoversFromCorruptDatabaseFile() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kenshiki-corrupt-\(UUID().uuidString).sqlite3")
        defer {
            for suffix in ["", "-wal", "-shm", ".corrupt"] {
                try? FileManager.default.removeItem(atPath: url.path + suffix)
            }
        }
        // A file that is not a valid SQLite database.
        try Data("this is not a sqlite database".utf8).write(to: url)

        // Opening must NOT throw — the store quarantines the bad file and rebuilds a fresh one.
        let store = try SQLiteTelemetryStore(url: url)
        try await store.append(makeEvent(id: "fresh", offset: 0))
        let recovered = try await store.recent(limit: 10)
        XCTAssertEqual(recovered.map(\.id), ["fresh"])

        // The corrupt original is preserved for forensics, not silently deleted.
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path + ".corrupt"))
    }

    func testWindowSummaryComputesPerSignalLivenessAndCheckIns() async throws {
        let store = try SQLiteTelemetryStore(url: nil)
        // Two check-ins (distinct session ids). motion live both times; focus live once.
        try await store.append(contentsOf: [
            TelemetryEvent(id: "c1-motion", occurredAt: at(0), category: .lifeSignal,
                           signalId: "motion", title: "m", sessionId: "c1", isLive: true),
            TelemetryEvent(id: "c1-focus", occurredAt: at(1), category: .lifeSignal,
                           signalId: "focus", title: "f", sessionId: "c1", isLive: false),
            TelemetryEvent(id: "c1-summary", occurredAt: at(2), category: .checkIn,
                           signalId: nil, title: "check-in", sessionId: "c1"),
            TelemetryEvent(id: "c2-motion", occurredAt: at(3600), category: .lifeSignal,
                           signalId: "motion", title: "m", sessionId: "c2", isLive: true),
            TelemetryEvent(id: "c2-focus", occurredAt: at(3601), category: .lifeSignal,
                           signalId: "focus", title: "f", sessionId: "c2", isLive: true),
            // A non-life_signal event in-window must not count toward liveness.
            TelemetryEvent(id: "c2-summary", occurredAt: at(3602), category: .checkIn,
                           signalId: nil, title: "check-in", sessionId: "c2"),
        ])

        let summary = try await store.windowSummary(
            in: DateInterval(start: at(-10), end: at(7200))
        )
        XCTAssertEqual(summary.checkInCount, 2)
        let byId = Dictionary(uniqueKeysWithValues: summary.signals.map { ($0.signalId, $0) })
        XCTAssertEqual(byId["motion"]?.liveCount, 2)
        XCTAssertEqual(byId["motion"]?.totalCount, 2)
        XCTAssertEqual(byId["motion"]?.rate, 1.0)
        XCTAssertEqual(byId["focus"]?.liveCount, 1)
        XCTAssertEqual(byId["focus"]?.totalCount, 2)
        XCTAssertEqual(byId["focus"]?.rate, 0.5)
        XCTAssertNil(byId["check-in"])   // summary row excluded
    }

    func testWindowSummaryExcludesOutOfWindowEvents() async throws {
        let store = try SQLiteTelemetryStore(url: nil)
        try await store.append(contentsOf: [
            TelemetryEvent(id: "old", occurredAt: at(0), category: .lifeSignal,
                           signalId: "motion", title: "m", sessionId: "old", isLive: true),
            TelemetryEvent(id: "old-summary", occurredAt: at(1), category: .checkIn,
                           title: "check-in", sessionId: "old"),
            TelemetryEvent(id: "new", occurredAt: at(10_000), category: .lifeSignal,
                           signalId: "motion", title: "m", sessionId: "new", isLive: false),
            TelemetryEvent(id: "new-summary", occurredAt: at(10_001), category: .checkIn,
                           title: "check-in", sessionId: "new"),
        ])
        let summary = try await store.windowSummary(in: DateInterval(start: at(5_000), end: at(20_000)))
        XCTAssertEqual(summary.checkInCount, 1)
        XCTAssertEqual(summary.signals.first?.signalId, "motion")
        XCTAssertEqual(summary.signals.first?.liveCount, 0)
        XCTAssertEqual(summary.signals.first?.totalCount, 1)
    }

    func testIsLiveRoundTripsIncludingNil() async throws {
        let store = try SQLiteTelemetryStore(url: nil)
        try await store.append(TelemetryEvent(id: "live", category: .lifeSignal, signalId: "motion",
                                              title: "m", isLive: true))
        try await store.append(TelemetryEvent(id: "nil", category: .stateTransition, title: "t"))
        let events = try await store.recent(limit: 10)
        let byId = Dictionary(uniqueKeysWithValues: events.map { ($0.id, $0) })
        XCTAssertEqual(byId["live"]?.isLive, true)
        XCTAssertNil(byId["nil"]?.isLive)
    }

    func testTimelineReturnsMostRecentEventsWithinLimit() async throws {
        let store = try SQLiteTelemetryStore(url: nil)
        try await store.append(contentsOf: [
            TelemetryEvent(id: "old", occurredAt: at(0), category: .checkIn, title: "old", sessionId: "old"),
            TelemetryEvent(id: "mid", occurredAt: at(100), category: .breakEvent, title: "mid"),
            TelemetryEvent(id: "new", occurredAt: at(200), category: .checkIn, title: "new", sessionId: "new"),
        ])

        let events = try await store.timeline(in: DateInterval(start: at(-1), end: at(300)), limit: 2)
        XCTAssertEqual(events.map(\.id), ["new", "mid"])
    }

    func testCheckInsDecodeSummaryMetadata() async throws {
        let store = try SQLiteTelemetryStore(url: nil)
        try await store.append(contentsOf: [
            TelemetryEvent(id: "signal", occurredAt: at(0), category: .lifeSignal,
                           signalId: "motion", title: "m", sessionId: "s1", isLive: true),
            TelemetryEvent(id: "check", occurredAt: at(1), category: .checkIn, severity: .ok,
                           title: "continuous", sessionId: "s1", merkleRoot: "root",
                           metadata: [
                               "signals_live": "10",
                               "signals_total": "13",
                               "signed_signals_live": "7",
                               "signed_signals_total": "10",
                               "observed_signals_live": "10",
                               "observed_signals_total": "13",
                           ]),
        ])

        let checkIns = try await store.checkIns(in: DateInterval(start: at(-1), end: at(10)), limit: 10)
        XCTAssertEqual(checkIns.count, 1)
        XCTAssertEqual(checkIns.first?.sessionId, "s1")
        XCTAssertEqual(checkIns.first?.outcome, "continuous")
        XCTAssertEqual(checkIns.first?.signalsLive, 10)
        XCTAssertEqual(checkIns.first?.signalsTotal, 13)
        XCTAssertEqual(checkIns.first?.signedSignalsLive, 7)
        XCTAssertEqual(checkIns.first?.signedSignalsTotal, 10)
        XCTAssertEqual(checkIns.first?.observedSignalsLive, 10)
        XCTAssertEqual(checkIns.first?.observedSignalsTotal, 13)
        XCTAssertEqual(checkIns.first?.merkleRoot, "root")
    }
}

// Export, migration, and daily-summary coverage — split out to keep the test type body focused.
extension TelemetryStoreTests {
    func testExportBatchPagesOldestFirstWithCursor() async throws {
        let store = try SQLiteTelemetryStore(url: nil)
        try await store.append(contentsOf: [
            makeEvent(id: "a", offset: 0),
            makeEvent(id: "b", offset: 0),
            makeEvent(id: "c", offset: 60),
        ])

        let first = try await store.exportBatch(after: nil, limit: 2)
        XCTAssertEqual(first.schemaVersion, "kenshiki.device.telemetry.export.v1")
        XCTAssertEqual(first.privacyBoundary, KenshikiPulseConstants.privacyBoundary)
        XCTAssertEqual(first.events.map(\.id), ["a", "b"])
        XCTAssertEqual(first.nextCursor?.eventId, "b")

        let second = try await store.exportBatch(after: first.nextCursor, limit: 2)
        XCTAssertEqual(second.events.map(\.id), ["c"])
        XCTAssertEqual(second.nextCursor?.eventId, "c")
        XCTAssertNotNil(second.nextCursor?.localSequence)
    }

    func testExportUsesInsertionSequenceForLateOlderEvents() async throws {
        let store = try SQLiteTelemetryStore(url: nil)
        try await store.append(makeEvent(id: "new", offset: 1_000))
        let first = try await store.exportBatch(after: nil, limit: 10)
        XCTAssertEqual(first.events.map(\.id), ["new"])

        try await store.append(makeEvent(id: "late-old", offset: 0))

        let second = try await store.exportBatch(after: first.nextCursor, limit: 10)
        XCTAssertEqual(second.events.map(\.id), ["late-old"])
    }

    func testEventAppendRejectsChangedDuplicatePayload() async throws {
        let store = try SQLiteTelemetryStore(url: nil)
        let event = makeEvent(id: "same", offset: 0, category: .checkIn, signalId: nil)
        try await store.append(event)
        try await store.append(event)

        do {
            try await store.append(TelemetryEvent(id: "same", occurredAt: event.occurredAt,
                                                 category: .checkIn, title: "changed"))
            XCTFail("Expected changed duplicate event to fail")
        } catch KenshikiPulseError.storageFailed(let message) {
            XCTAssertTrue(message.contains("id collision"))
        }
    }

    func testRejectsUnexpectedEventMetadataKeys() async throws {
        let store = try SQLiteTelemetryStore(url: nil)
        do {
            try await store.append(TelemetryEvent(id: "raw", category: .lifeSignal, signalId: "motion",
                                                 title: "Movement", metadata: ["raw_accel_x": "0.123"]))
            XCTFail("Expected unexpected metadata key to fail")
        } catch KenshikiPulseError.storageFailed(let message) {
            XCTAssertTrue(message.contains("unexpected event metadata keys"))
        }
    }

    func testReadSurfacesCorruptCategory() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kenshiki-corrupt-category-\(UUID().uuidString).sqlite3")
        defer {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
        }
        let store = try SQLiteTelemetryStore(url: url)
        try await store.append(makeEvent(id: "a", offset: 0))
        try corruptTelemetryColumn(url: url, set: "category = 'raw_sensor'")

        do {
            _ = try await store.recent(limit: 10)
            XCTFail("Expected corrupt category to fail")
        } catch KenshikiPulseError.storageFailed(let message) {
            XCTAssertTrue(message.contains("corrupt telemetry category"))
        }
    }

    func testReadSurfacesCorruptMetadataJSON() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kenshiki-corrupt-metadata-\(UUID().uuidString).sqlite3")
        defer {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
        }
        let store = try SQLiteTelemetryStore(url: url)
        try await store.append(makeEvent(id: "a", offset: 0))
        try corruptTelemetryColumn(url: url, set: "metadata = '{not-json}'")

        do {
            _ = try await store.recent(limit: 10)
            XCTFail("Expected corrupt metadata to fail")
        } catch KenshikiPulseError.storageFailed(let message) {
            XCTAssertTrue(message.contains("corrupt telemetry metadata JSON"))
        }
    }

    func testExportThenReimportRoundTripsIdempotently() async throws {
        // The device-migration guarantee: page everything out, wipe (new device), append it back,
        // and re-appending identical rows must not duplicate.
        let source = try SQLiteTelemetryStore(url: nil)
        let originals = [
            makeEvent(id: "a", offset: 0, category: .lifeSignal, signalId: "motion"),
            makeEvent(id: "b", offset: 60, category: .checkIn, signalId: nil),
            makeEvent(id: "c", offset: 120, category: .breakEvent, signalId: "sim_swap"),
        ]
        try await source.append(contentsOf: originals)

        var exported: [TelemetryEvent] = []
        var cursor: TelemetryExportCursor?
        while true {
            let batch = try await source.exportBatch(after: cursor, limit: 2)
            guard !batch.events.isEmpty else { break }
            exported.append(contentsOf: batch.events)
            if batch.events.count < 2 { break }
            cursor = batch.nextCursor
        }
        XCTAssertEqual(Set(exported.map(\.id)), ["a", "b", "c"])

        // Fresh "new device": import the batch, then import again.
        let target = try SQLiteTelemetryStore(url: nil)
        try await target.append(contentsOf: exported)
        try await target.append(contentsOf: exported)   // idempotent re-import
        let recovered = try await target.recent(limit: 100)
        XCTAssertEqual(recovered.count, 3)
        XCTAssertEqual(Set(recovered.map(\.id)), ["a", "b", "c"])
    }

    func testSchemaV3MigrationBackfillsLegacyCheckInMetadata() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kenshiki-telemetry-v2-\(UUID().uuidString).sqlite3")
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: url.path + suffix)
            }
        }
        try makeLegacyV2Database(at: url)

        let store = try SQLiteTelemetryStore(url: url)
        let checkIns = try await store.checkIns(in: DateInterval(start: at(-1), end: at(10)), limit: 10)

        XCTAssertEqual(checkIns.first?.signalsLive, 10)
        XCTAssertEqual(checkIns.first?.signalsTotal, 13)
        XCTAssertEqual(checkIns.first?.signedSignalsLive, 7)
        XCTAssertEqual(checkIns.first?.signedSignalsTotal, 10)
        XCTAssertEqual(checkIns.first?.observedSignalsLive, 10)
        XCTAssertEqual(checkIns.first?.observedSignalsTotal, 13)
    }

    func testSignalSeriesFiltersSignalOldestFirstWithSource() async throws {
        let store = try SQLiteTelemetryStore(url: nil)
        try await store.append(contentsOf: [
            TelemetryEvent(id: "m2", occurredAt: at(200), category: .lifeSignal,
                           signalId: "motion", title: "m", sessionId: "s2", isLive: false,
                           metadata: ["source": "signed"]),
            TelemetryEvent(id: "f1", occurredAt: at(100), category: .lifeSignal,
                           signalId: "focus", title: "f", sessionId: "s1", isLive: true,
                           metadata: ["source": "live"]),
            TelemetryEvent(id: "m1", occurredAt: at(0), category: .lifeSignal,
                           signalId: "motion", title: "m", sessionId: "s1", isLive: true,
                           metadata: ["source": "signed"]),
        ])

        let points = try await store.signalSeries(signalId: "motion", in: DateInterval(start: at(-1), end: at(300)))
        XCTAssertEqual(points.map(\.sessionId), ["s1", "s2"])
        XCTAssertEqual(points.map(\.isLive), [true, false])
        XCTAssertEqual(points.map(\.source), ["signed", "signed"])
    }

    func testDailySummaryBucketsCheckInsBreaksAndSignals() async throws {
        let store = try SQLiteTelemetryStore(url: nil)
        try await store.append(contentsOf: [
            TelemetryEvent(id: "d1-check", occurredAt: at(0), category: .checkIn, title: "ok", sessionId: "d1"),
            TelemetryEvent(id: "d1-motion", occurredAt: at(1), category: .lifeSignal,
                           signalId: "motion", title: "m", sessionId: "d1", isLive: true),
            TelemetryEvent(id: "d1-focus", occurredAt: at(2), category: .lifeSignal,
                           signalId: "focus", title: "f", sessionId: "d1", isLive: false),
            TelemetryEvent(id: "d1-break", occurredAt: at(3), category: .breakEvent, title: "break"),
            TelemetryEvent(id: "d2-check", occurredAt: at(86_400), category: .checkIn, title: "ok", sessionId: "d2"),
            TelemetryEvent(id: "d2-motion", occurredAt: at(86_401), category: .lifeSignal,
                           signalId: "motion", title: "m", sessionId: "d2", isLive: true),
        ])

        let days = try await store.dailySummary(in: DateInterval(start: at(-1), end: at(90_000)))
        XCTAssertEqual(days.count, 2)
        XCTAssertEqual(days[0].checkInCount, 1)
        XCTAssertEqual(days[0].breakCount, 1)
        XCTAssertEqual(days[0].liveSignalCount, 1)
        XCTAssertEqual(days[0].totalSignalCount, 2)
        XCTAssertEqual(days[0].liveRate, 0.5)
        XCTAssertEqual(days[1].checkInCount, 1)
        XCTAssertEqual(days[1].liveSignalCount, 1)
        XCTAssertEqual(days[1].totalSignalCount, 1)
    }

    func testLocalDailySummaryUsesProvidedCalendar() async throws {
        let store = try SQLiteTelemetryStore(url: nil)
        // UTC midnight boundary, but both events are the previous local day in America/Los_Angeles.
        let first = try utcDate(year: 2023, month: 11, day: 15, hour: 23, minute: 30)
        let second = try utcDate(year: 2023, month: 11, day: 16, hour: 1, minute: 30)
        try await store.append(contentsOf: [
            TelemetryEvent(id: "late-utc-day-1", occurredAt: first,
                           category: .checkIn, title: "ok", sessionId: "s1"),
            TelemetryEvent(id: "early-utc-day-2", occurredAt: second,
                           category: .checkIn, title: "ok", sessionId: "s2"),
        ])

        let interval = DateInterval(start: first.addingTimeInterval(-60), end: second.addingTimeInterval(60))
        let utc = try await store.dailySummary(in: interval)
        var pacific = Calendar(identifier: .gregorian)
        pacific.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let local = try await store.localDailySummary(in: interval, calendar: pacific)

        XCTAssertEqual(utc.count, 2)
        XCTAssertEqual(local.count, 1)
        XCTAssertEqual(local.first?.checkInCount, 2)
    }

    func testBreaksFiltersWindowMostRecentFirst() async throws {
        let store = try SQLiteTelemetryStore(url: nil)
        try await store.append(contentsOf: [
            TelemetryEvent(id: "old-break", occurredAt: at(0), category: .breakEvent, title: "old"),
            TelemetryEvent(id: "new-break", occurredAt: at(100), category: .breakEvent, title: "new"),
            TelemetryEvent(id: "check", occurredAt: at(200), category: .checkIn, title: "ok", sessionId: "s"),
        ])

        let breaks = try await store.breaks(in: DateInterval(start: at(-1), end: at(150)), limit: 10)
        XCTAssertEqual(breaks.map(\.id), ["new-break", "old-break"])
    }

    func testStateTransitionsFiltersWindowMostRecentFirst() async throws {
        let store = try SQLiteTelemetryStore(url: nil)
        try await store.append(contentsOf: [
            TelemetryEvent(id: "old-state", occurredAt: at(0), category: .stateTransition,
                           signalId: "deep_rest_candidate", title: "Deep rest candidate"),
            TelemetryEvent(id: "new-state", occurredAt: at(100), category: .stateTransition,
                           signalId: "vehicular_transit", title: "Vehicular transit pattern"),
            TelemetryEvent(id: "check", occurredAt: at(200), category: .checkIn, title: "ok", sessionId: "s"),
        ])

        let states = try await store.stateTransitions(in: DateInterval(start: at(-1), end: at(150)), limit: 10)
        XCTAssertEqual(states.map(\.id), ["new-state", "old-state"])
    }
}

// Feature-point coverage — split into its own extension to keep the test type body focused.
extension TelemetryStoreTests {
    func testFeaturePointsRoundTripAndFilterBySignal() async throws {
        let store = try SQLiteTelemetryStore(url: nil)
        try await store.append(contentsOf: [
            TelemetryFeaturePoint(id: "m1", occurredAt: at(0), signalId: "magnetic",
                                  featureKind: "field_context", bucketSeconds: 60,
                                  valueBucket: "steady", trend: "flat", volatilityBucket: "low",
                                  stateLabel: "desk", sessionId: "s1", metadata: ["privacy": "bucketed"]),
            TelemetryFeaturePoint(id: "m2", occurredAt: at(60), signalId: "magnetic",
                                  featureKind: "field_context", bucketSeconds: 60,
                                  valueBucket: "spike", trend: "rising", volatilityBucket: "high"),
            TelemetryFeaturePoint(id: "p1", occurredAt: at(30), signalId: "pressure",
                                  featureKind: "barometer", bucketSeconds: 60,
                                  valueBucket: "step_down"),
        ])

        let magnetic = try await store.featureSeries(signalId: "magnetic", in: DateInterval(start: at(-1), end: at(120)))
        XCTAssertEqual(magnetic.map(\.id), ["m1", "m2"])
        XCTAssertEqual(magnetic.first?.valueBucket, "steady")
        XCTAssertEqual(magnetic.first?.trend, "flat")
        XCTAssertEqual(magnetic.first?.volatilityBucket, "low")
        XCTAssertEqual(magnetic.first?.stateLabel, "desk")
        XCTAssertEqual(magnetic.first?.sessionId, "s1")
        XCTAssertEqual(magnetic.first?.metadata["privacy"], "bucketed")
    }

    func testFeaturePointsReturnOldestFirstWithLimit() async throws {
        let store = try SQLiteTelemetryStore(url: nil)
        try await store.append(contentsOf: [
            TelemetryFeaturePoint(id: "b", occurredAt: at(60), signalId: "motion", featureKind: "activity",
                                  bucketSeconds: 60, valueBucket: "burst"),
            TelemetryFeaturePoint(id: "a", occurredAt: at(0), signalId: "motion", featureKind: "activity",
                                  bucketSeconds: 60, valueBucket: "quiet"),
            TelemetryFeaturePoint(id: "c", occurredAt: at(120), signalId: "radio", featureKind: "path",
                                  bucketSeconds: 60, valueBucket: "wifi"),
        ])

        let points = try await store.featurePoints(in: DateInterval(start: at(-1), end: at(200)), limit: 2)
        XCTAssertEqual(points.map(\.id), ["a", "b"])
    }

    func testFeatureExportUsesInsertionSequenceForLateOlderPoints() async throws {
        let store = try SQLiteTelemetryStore(url: nil)
        try await store.append(TelemetryFeaturePoint(id: "new", occurredAt: at(1_000), signalId: "motion",
                                                     featureKind: "activity", bucketSeconds: 60,
                                                     valueBucket: "burst"))
        let first = try await store.exportFeatureBatch(after: nil, limit: 10)
        XCTAssertEqual(first.featurePoints.map(\.id), ["new"])

        try await store.append(TelemetryFeaturePoint(id: "late-old", occurredAt: at(0), signalId: "motion",
                                                     featureKind: "activity", bucketSeconds: 60,
                                                     valueBucket: "quiet"))

        let second = try await store.exportFeatureBatch(after: first.nextCursor, limit: 10)
        XCTAssertEqual(second.featurePoints.map(\.id), ["late-old"])
        XCTAssertNotNil(second.nextCursor?.localSequence)
    }

    func testFeaturePointLimitIsClamped() async throws {
        let store = try SQLiteTelemetryStore(url: nil)
        try await store.append(TelemetryFeaturePoint(id: "one", occurredAt: at(0), signalId: "motion",
                                                     featureKind: "activity", bucketSeconds: 60,
                                                     valueBucket: "quiet"))

        let points = try await store.featurePoints(in: DateInterval(start: at(-1), end: at(10)), limit: Int.max)
        XCTAssertEqual(points.map(\.id), ["one"])
    }

    func testFeaturePointAppendIsIdempotentOnlyForSamePayload() async throws {
        let store = try SQLiteTelemetryStore(url: nil)
        let point = TelemetryFeaturePoint(id: "same", occurredAt: at(0), signalId: "motion",
                                          featureKind: "activity", bucketSeconds: 60,
                                          valueBucket: "quiet")
        try await store.append(point)
        try await store.append(point)

        let points = try await store.featureSeries(signalId: "motion", in: DateInterval(start: at(-1), end: at(10)))
        XCTAssertEqual(points.count, 1)
        XCTAssertEqual(points.first?.valueBucket, "quiet")

        do {
            try await store.append(TelemetryFeaturePoint(id: "same", occurredAt: at(0), signalId: "motion",
                                                         featureKind: "activity", bucketSeconds: 60,
                                                         valueBucket: "burst"))
            XCTFail("Expected changed duplicate feature point to fail")
        } catch KenshikiPulseError.storageFailed(let message) {
            XCTAssertTrue(message.contains("id collision"))
        }
    }

    func testPruneOlderThanRemovesFeaturePoints() async throws {
        let store = try SQLiteTelemetryStore(url: nil)
        try await store.append(makeEvent(id: "event", offset: 0))
        try await store.append(contentsOf: [
            TelemetryFeaturePoint(id: "old-feature", occurredAt: at(0), signalId: "motion",
                                  featureKind: "activity", bucketSeconds: 60, valueBucket: "quiet"),
            TelemetryFeaturePoint(id: "new-feature", occurredAt: at(1_000), signalId: "motion",
                                  featureKind: "activity", bucketSeconds: 60, valueBucket: "burst"),
        ])

        let deleted = try await store.prune(olderThan: at(500))
        XCTAssertEqual(deleted, 2)
        let remaining = try await store.featurePoints(in: DateInterval(start: at(-1), end: at(2_000)), limit: 10)
        XCTAssertEqual(remaining.map(\.id), ["new-feature"])
    }

    private func at(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_700_000_000 + offset)
    }

    private func utcDate(year: Int, month: Int, day: Int, hour: Int, minute: Int) throws -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return try XCTUnwrap(calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        )))
    }

    private func makeLegacyV2Database(at url: URL) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil), SQLITE_OK)
        guard let db else { return }
        defer { sqlite3_close_v2(db) }

        try execSQL(db, """
            CREATE TABLE telemetry_events (
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
            PRAGMA user_version = 2;
            """)

        for index in 0..<10 {
            let isLive = index < 7 ? 1 : 0
            try execSQL(db, """
                INSERT INTO telemetry_events VALUES (
                    's1-signed-\(index)', 1700000000, 'life_signal', 'ok', 'signed_\(index)',
                    'Signed \(index)', '', 's1', 'root', \(isLive), '{"source":"signed"}'
                );
                """)
        }
        for signalId in ["place", "diurnal", "focus"] {
            try execSQL(db, """
                INSERT INTO telemetry_events VALUES (
                    's1-live-\(signalId)', 1700000000, 'life_signal', 'ok', '\(signalId)',
                    '\(signalId)', '', 's1', 'root', 1, '{"source":"live","observed":"true"}'
                );
                """)
        }
        try execSQL(db, """
            INSERT INTO telemetry_events VALUES (
                's1-checkin', 1700000001, 'check_in', 'ok', NULL, 'continuous', '', 's1', 'root', NULL,
                '{"signals_live":"7","signals_total":"10"}'
            );
            """)
    }

    private func corruptTelemetryColumn(url: URL, set assignment: String) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        guard let db else { return }
        defer { sqlite3_close_v2(db) }
        try execSQL(db, "UPDATE telemetry_events SET \(assignment) WHERE id = 'a';")
    }

    private func execSQL(_ db: OpaquePointer, _ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown SQLite error"
            sqlite3_free(error)
            XCTFail(message)
            return
        }
    }

    func testMetadataDefaultsEmptyWhenAbsent() async throws {
        let store = try SQLiteTelemetryStore(url: nil)
        let event = TelemetryEvent(id: "a", category: .stateTransition, title: "Pulse restored")
        try await store.append(event)
        let loaded = try await store.recent(limit: 1).first
        XCTAssertEqual(loaded?.metadata, [:])
    }
}
