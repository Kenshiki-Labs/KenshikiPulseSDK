import XCTest
@testable import KenshikiPulseSDK

final class LocalEvidenceLakeStoreTests: XCTestCase {
    private func at(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_700_000_000 + seconds)
    }

    private func window(
        id: String? = nil,
        sensorId: String = "motion",
        evidenceKind: String = "signal_state",
        quality: LocalEvidenceQuality = .observed,
        permissionState: LocalEvidencePermissionState = .authorized,
        payload: [String: String] = ["state": "observed"],
        seconds: TimeInterval = 0
    ) -> LocalEvidenceWindow {
        LocalEvidenceWindow(
            id: id,
            capturedAt: at(seconds),
            windowStartAt: at(seconds),
            windowEndAt: at(seconds + 1),
            sensorId: sensorId,
            laneGroup: "movement",
            evidenceKind: evidenceKind,
            source: "test",
            collectionSurface: "unit_test",
            quality: quality,
            permissionState: permissionState,
            supportState: quality == .unavailable ? .unavailable : .available,
            freshnessSeconds: 0,
            extractorVersion: SQLiteLocalEvidenceLakeStore.defaultExtractorVersion,
            privacyClass: .localWindow,
            payload: payload,
            createdAt: at(seconds)
        )
    }

    func testWindowRoundTripAndSnapshotHash() async throws {
        let store = try SQLiteLocalEvidenceLakeStore(url: nil)
        let first = window(seconds: 0)
        let second = window(sensorId: "focus", quality: .unavailable,
                            permissionState: .denied,
                            payload: ["state": "denied"], seconds: 60)

        try await store.append(contentsOf: [first, second])
        let snapshot = try await store.snapshot(
            in: DateInterval(start: at(-10), end: at(120)),
            limit: 10
        )

        XCTAssertEqual(snapshot.rows, [first, second])
        XCTAssertEqual(snapshot.observedCount, 1)
        XCTAssertEqual(snapshot.unavailableCount, 1)
        XCTAssertEqual(snapshot.inputHash.count, 64)
    }

    func testAppendIsIdempotentOnlyForSamePayload() async throws {
        let store = try SQLiteLocalEvidenceLakeStore(url: nil)
        let original = window(id: "same", payload: ["state": "observed"])
        try await store.append(original)
        try await store.append(original)
        let rows = try await store.recent(sensorId: nil, limit: 10)
        XCTAssertEqual(rows.count, 1)

        do {
            try await store.append(window(id: "same", payload: ["state": "different"]))
            XCTFail("Expected duplicate id with different payload to fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("id collision"))
        }
    }

    func testExtractionRunRoundTrip() async throws {
        let store = try SQLiteLocalEvidenceLakeStore(url: nil)
        let run = LocalEvidenceExtractionRun(
            runAt: at(10),
            windowStartAt: at(0),
            windowEndAt: at(60),
            extractorVersion: "extractor.v1",
            fusionVersion: "fusion.v1",
            inputRowCount: 3,
            inputHash: String(repeating: "a", count: 64),
            outputFeatureCount: 2,
            outputEventCount: 1,
            status: "ok"
        )

        try await store.appendExtractionRun(run)
        let latest = try await store.latestExtractionRun()
        XCTAssertEqual(latest, run)
    }

    func testPruneAndClear() async throws {
        let store = try SQLiteLocalEvidenceLakeStore(url: nil)
        try await store.append(contentsOf: [
            window(seconds: 0),
            window(sensorId: "battery", seconds: 1_000),
        ])

        let deleted = try await store.prune(olderThan: at(500))
        XCTAssertEqual(deleted, 1)
        let remaining = try await store.recent(sensorId: nil, limit: 10).map(\.sensorId)
        XCTAssertEqual(remaining, ["battery"])

        try await store.clear()
        let afterClear = try await store.recent(sensorId: nil, limit: 10)
        XCTAssertTrue(afterClear.isEmpty)
    }

    func testForbiddenPayloadKeysAreRejected() async throws {
        let store = try SQLiteLocalEvidenceLakeStore(url: nil)
        do {
            try await store.append(window(payload: ["latitude": "37.0"]))
            XCTFail("Expected precise-location payload key to fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("forbidden"))
        }
    }
}
