import XCTest
@testable import KenshikiPulseSDK

final class LocalEvidenceDurableWriterTests: XCTestCase {
    func testFailedWriteStaysPendingAndRetriesWithNextAppend() async throws {
        let store = FlakyEvidenceStore(failuresRemaining: 1)
        let writer = LocalEvidenceDurableWriter(store: store, maxPendingRows: 10)

        let first = await writer.append(window("motion"))
        XCTAssertFalse(first.success)
        XCTAssertEqual(first.pendingRowCount, 1)
        let firstIDs = await store.appendedIDs()
        XCTAssertEqual(firstIDs, [])

        let second = await writer.append(window("battery"))
        XCTAssertTrue(second.success)
        XCTAssertEqual(second.attemptedRowCount, 2)
        XCTAssertEqual(second.pendingRowCount, 0)
        let secondIDs = await store.appendedIDs()
        XCTAssertEqual(secondIDs, ["motion", "battery"])
    }

    func testPendingQueueIsBoundedAndReportsDrops() async throws {
        let store = FlakyEvidenceStore(failuresRemaining: 10)
        let writer = LocalEvidenceDurableWriter(store: store, maxPendingRows: 2)

        _ = await writer.append(window("one"))
        _ = await writer.append(window("two"))
        let health = await writer.append(window("three"))

        XCTAssertFalse(health.success)
        XCTAssertEqual(health.pendingRowCount, 2)
        XCTAssertEqual(health.droppedRowCount, 1)
        let pendingCount = await writer.pendingCount()
        XCTAssertEqual(pendingCount, 2)
    }

    func testOverlappingAppendsDoNotTrapWhenFlushIsSuspended() async throws {
        let store = PausingEvidenceStore()
        let writer = LocalEvidenceDurableWriter(store: store, maxPendingRows: 10)

        let first = Task { await writer.append(window("one")) }
        await store.waitUntilAppendCallCount(1)

        let second = Task { await writer.append(window("two")) }
        await waitUntilPendingCount(1, writer: writer)
        let third = Task { await writer.append(window("three")) }
        await waitUntilPendingCount(2, writer: writer)

        await store.waitUntilPendingContinuationCount(1)
        await store.releaseNextAppend()

        let firstHealth = await first.value
        let secondHealth = await second.value
        let thirdHealth = await third.value
        let pendingCount = await writer.pendingCount()
        let appendedIDs = await store.appendedIDs()

        XCTAssertTrue(firstHealth.success)
        XCTAssertEqual(pendingCount, 0)
        XCTAssertEqual(appendedIDs, ["one", "two", "three"])
        XCTAssertEqual(secondHealth.error, nil)
        XCTAssertEqual(thirdHealth.error, nil)
    }

    private func waitUntilPendingCount(
        _ target: Int,
        writer: LocalEvidenceDurableWriter,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<1_000 {
            if await writer.pendingCount() >= target { return }
            await Task.yield()
        }
        let pending = await writer.pendingCount()
        XCTFail("Timed out waiting for \(target) pending rows; saw \(pending).", file: file, line: line)
    }

    private func window(_ id: String) -> LocalEvidenceWindow {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        return LocalEvidenceWindow(
            id: id,
            capturedAt: now,
            windowStartAt: now.addingTimeInterval(-60),
            windowEndAt: now,
            sensorId: id,
            laneGroup: "system",
            evidenceKind: "unit_test",
            source: "unit_test",
            collectionSurface: "unit_test",
            quality: .observed,
            permissionState: .notRequired,
            supportState: .available,
            freshnessSeconds: 0,
            extractorVersion: "test",
            privacyClass: .localWindow,
            payload: ["id": id],
            createdAt: now
        )
    }
}

private actor FlakyEvidenceStore: LocalEvidenceLakeStoring {
    private var failuresRemaining: Int
    private var ids: [String] = []

    init(failuresRemaining: Int) {
        self.failuresRemaining = failuresRemaining
    }

    func append(_ window: LocalEvidenceWindow) async throws {
        try await append(contentsOf: [window])
    }

    func append(contentsOf windows: [LocalEvidenceWindow]) async throws {
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw KenshikiPulseError.storageFailed("synthetic failure")
        }
        ids.append(contentsOf: windows.map(\.id))
    }

    func snapshot(in interval: DateInterval, limit: Int) async throws -> LocalEvidenceSnapshot {
        LocalEvidenceSnapshot(interval: interval, rows: [])
    }

    func recent(sensorId: String?, limit: Int) async throws -> [LocalEvidenceWindow] { [] }

    func appendExtractionRun(_ run: LocalEvidenceExtractionRun) async throws {}

    func latestExtractionRun() async throws -> LocalEvidenceExtractionRun? { nil }

    func prune(olderThan cutoff: Date) async throws -> Int { 0 }

    func clear() async throws {}

    func appendedIDs() -> [String] { ids }
}

private actor PausingEvidenceStore: LocalEvidenceLakeStoring {
    private var ids: [String] = []
    private var appendCallCount = 0
    private var appendContinuations: [CheckedContinuation<Void, Never>] = []
    private var callCountWaiters: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var continuationCountWaiters: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func append(_ window: LocalEvidenceWindow) async throws {
        try await append(contentsOf: [window])
    }

    func append(contentsOf windows: [LocalEvidenceWindow]) async throws {
        appendCallCount += 1
        resumeSatisfiedWaiters()
        if appendCallCount == 1 {
            await withCheckedContinuation { continuation in
                appendContinuations.append(continuation)
                resumeSatisfiedWaiters()
            }
        }
        ids.append(contentsOf: windows.map(\.id))
    }

    func waitUntilAppendCallCount(_ target: Int) async {
        guard appendCallCount < target else { return }
        await withCheckedContinuation { continuation in
            callCountWaiters.append((target, continuation))
        }
    }

    func waitUntilPendingContinuationCount(_ target: Int) async {
        guard appendContinuations.count < target else { return }
        await withCheckedContinuation { continuation in
            continuationCountWaiters.append((target, continuation))
        }
    }

    func releaseNextAppend() {
        guard !appendContinuations.isEmpty else { return }
        appendContinuations.removeFirst().resume()
    }

    func snapshot(in interval: DateInterval, limit: Int) async throws -> LocalEvidenceSnapshot {
        LocalEvidenceSnapshot(interval: interval, rows: [])
    }

    func recent(sensorId: String?, limit: Int) async throws -> [LocalEvidenceWindow] { [] }

    func appendExtractionRun(_ run: LocalEvidenceExtractionRun) async throws {}

    func latestExtractionRun() async throws -> LocalEvidenceExtractionRun? { nil }

    func prune(olderThan cutoff: Date) async throws -> Int { 0 }

    func clear() async throws {}

    func appendedIDs() -> [String] { ids }

    private func resumeSatisfiedWaiters() {
        let readyCallWaiters = callCountWaiters.filter { appendCallCount >= $0.target }
        callCountWaiters.removeAll { appendCallCount >= $0.target }
        readyCallWaiters.forEach { $0.continuation.resume() }

        let readyContinuationWaiters = continuationCountWaiters.filter { appendContinuations.count >= $0.target }
        continuationCountWaiters.removeAll { appendContinuations.count >= $0.target }
        readyContinuationWaiters.forEach { $0.continuation.resume() }
    }
}
