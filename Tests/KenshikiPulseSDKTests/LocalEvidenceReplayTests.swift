import XCTest
@testable import KenshikiPulseSDK

final class LocalEvidenceReplayTests: XCTestCase {
    private struct PermissionUnavailableCase {
        let sensor: String
        let laneGroup: String
        let kind: String
        let permission: LocalEvidencePermissionState
    }

    private func at(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_700_000_000 + seconds)
    }

    func testReplayProjectsLakeWindowsIntoContinuityEvidenceSnapshot() {
        let snapshot = LocalEvidenceSnapshot(
            interval: DateInterval(start: at(0), end: at(120)),
            rows: [
                window(sensorId: "device_motion", laneGroup: "movement", evidenceKind: "motion_bucket",
                       quality: .observed, seconds: 10),
                window(sensorId: "connectivity", laneGroup: "network", evidenceKind: "network_path",
                       quality: .empty, seconds: 20),
                window(sensorId: "focus", laneGroup: "attention_focus", evidenceKind: "focus_state",
                       quality: .unavailable, permission: .denied, support: .unavailable, seconds: 30),
            ]
        )

        let evidence = LocalEvidenceReplay.evidenceSnapshot(from: snapshot, now: at(120), freshnessWindow: 300)

        XCTAssertEqual(evidence.points.first { $0.lane == .motion }?.state, .observed)
        XCTAssertEqual(evidence.points.first { $0.lane == .connectivity }?.state, .empty)
        XCTAssertEqual(evidence.points.first { $0.lane == .focus }?.state, .unavailable)
        XCTAssertEqual(evidence.points.first { $0.lane == .focus }?.supportStatus, .unavailable)
    }

    func testReplayUsesNewestWindowPerLane() {
        let snapshot = LocalEvidenceSnapshot(
            interval: DateInterval(start: at(0), end: at(120)),
            rows: [
                window(sensorId: "battery", laneGroup: "power", evidenceKind: "power_state",
                       quality: .empty, seconds: 10),
                window(sensorId: "battery", laneGroup: "power", evidenceKind: "power_state",
                       quality: .observed, seconds: 90),
            ]
        )

        let evidence = LocalEvidenceReplay.evidenceSnapshot(from: snapshot, now: at(120), freshnessWindow: 300)

        XCTAssertEqual(evidence.points.count, 1)
        XCTAssertEqual(evidence.points.first?.lane, .battery)
        XCTAssertEqual(evidence.points.first?.state, .observed)
    }

    func testReplayMarksOldObservedWindowsStaleNotUnavailable() {
        let snapshot = LocalEvidenceSnapshot(
            interval: DateInterval(start: at(0), end: at(120)),
            rows: [
                window(sensorId: "magnetic", laneGroup: "device_environment", evidenceKind: "magnetic_bucket",
                       quality: .observed, seconds: 10),
            ]
        )

        let evidence = LocalEvidenceReplay.evidenceSnapshot(from: snapshot, now: at(1_000), freshnessWindow: 300)

        XCTAssertEqual(evidence.points.first?.lane, .magnetometer)
        XCTAssertEqual(evidence.points.first?.state, .stale)
        XCTAssertEqual(evidence.points.first?.supportStatus, .available)
    }

    func testProofSignalsIgnoreAppOnlyLanesFromLakeReplay() {
        let evidence = ContinuityEvidenceSnapshot(points: [
            ContinuityEvidencePoint(lane: .motion, state: .observed, supportStatus: .available),
            ContinuityEvidencePoint(lane: .place, state: .observed, supportStatus: .available),
            ContinuityEvidencePoint(lane: .focus, state: .observed, supportStatus: .available),
            ContinuityEvidencePoint(lane: .trustedBLEWitness, state: .observed, supportStatus: .available),
        ])

        XCTAssertEqual(ContinuityEvaluator.proofSignals(from: evidence), [true])
    }

    func testSensorReplayIgnoresCompatibilityRows() {
        let snapshot = LocalEvidenceSnapshot(
            interval: DateInterval(start: at(0), end: at(120)),
            rows: [
                window(
                    sensorId: "device_motion",
                    laneGroup: "movement",
                    evidenceKind: "motion_bucket",
                    quality: .observed,
                    seconds: 20,
                    extractorVersion: "pulse.local_evidence_lake.compat_checkin_bundle.v1",
                    collectionSurface: "feature_extractor"
                ),
            ]
        )

        let evidence = LocalEvidenceReplay.sensorEvidenceSnapshot(from: snapshot, now: at(120), freshnessWindow: 300)

        XCTAssertEqual(LocalEvidenceReplay.sensorWriterRowCount(in: snapshot), 0)
        XCTAssertTrue(evidence.points.isEmpty)
    }

    func testSensorReplayUsesOnlyDirectSensorWriterRows() {
        let snapshot = LocalEvidenceSnapshot(
            interval: DateInterval(start: at(0), end: at(120)),
            rows: [
                window(
                    sensorId: "device_motion",
                    laneGroup: "movement",
                    evidenceKind: "motion_bucket",
                    quality: .empty,
                    seconds: 20,
                    extractorVersion: "pulse.local_evidence_lake.compat_checkin_bundle.v1",
                    collectionSurface: "feature_extractor"
                ),
                window(
                    sensorId: "device_motion",
                    laneGroup: "movement",
                    evidenceKind: "motion_bucket",
                    quality: .observed,
                    seconds: 30,
                    extractorVersion: LocalEvidenceReplay.sensorWriterExtractorVersion,
                    collectionSurface: "sensor_monitor"
                ),
            ]
        )

        let evidence = LocalEvidenceReplay.sensorEvidenceSnapshot(from: snapshot, now: at(120), freshnessWindow: 300)

        XCTAssertEqual(LocalEvidenceReplay.sensorWriterRowCount(in: snapshot), 1)
        XCTAssertEqual(evidence.points.count, 1)
        XCTAssertEqual(evidence.points.first?.lane, .motion)
        XCTAssertEqual(evidence.points.first?.state, .observed)
    }

    func testMovementSubstrateRowsCollapseToOneProofLane() {
        let snapshot = LocalEvidenceSnapshot(
            interval: DateInterval(start: at(0), end: at(120)),
            rows: [
                window(
                    sensorId: "device_motion",
                    laneGroup: "movement",
                    evidenceKind: "motion_bucket",
                    quality: .observed,
                    seconds: 20,
                    extractorVersion: LocalEvidenceReplay.sensorWriterExtractorVersion,
                    collectionSurface: "sensor_monitor"
                ),
                window(
                    sensorId: "activity",
                    laneGroup: "movement",
                    evidenceKind: "activity_history_window",
                    quality: .observed,
                    seconds: 30,
                    extractorVersion: LocalEvidenceReplay.sensorWriterExtractorVersion,
                    collectionSurface: "sensor_history_writer"
                ),
                window(
                    sensorId: "pedometer",
                    laneGroup: "movement",
                    evidenceKind: "pedometer_history_window",
                    quality: .observed,
                    seconds: 40,
                    extractorVersion: LocalEvidenceReplay.sensorWriterExtractorVersion,
                    collectionSurface: "sensor_history_writer"
                ),
            ]
        )

        let evidence = LocalEvidenceReplay.sensorEvidenceSnapshot(from: snapshot, now: at(120), freshnessWindow: 300)
        let movementPoints = evidence.points.filter { $0.lane == ContinuityEvidenceLane.motion }

        XCTAssertEqual(LocalEvidenceReplay.sensorWriterRowCount(in: snapshot), 3)
        XCTAssertEqual(movementPoints.count, 1)
        XCTAssertEqual(movementPoints.first?.state, .observed)
        XCTAssertEqual(ContinuityEvaluator.proofSignals(from: evidence), [true])
    }

    func testAppInteractionWriterRowsAreDirectButNotProofSignals() {
        let snapshot = LocalEvidenceSnapshot(
            interval: DateInterval(start: at(0), end: at(120)),
            rows: [
                window(
                    sensorId: "interaction",
                    laneGroup: "attention_focus",
                    evidenceKind: "app_lifecycle",
                    quality: .observed,
                    seconds: 30,
                    extractorVersion: LocalEvidenceReplay.sensorWriterExtractorVersion,
                    collectionSurface: "app_interaction_writer"
                ),
            ]
        )

        let evidence = LocalEvidenceReplay.sensorEvidenceSnapshot(from: snapshot, now: at(120))

        XCTAssertEqual(LocalEvidenceReplay.sensorWriterRowCount(in: snapshot), 1)
        XCTAssertEqual(evidence.points.first?.lane, .interaction)
        XCTAssertEqual(evidence.points.first?.state, .observed)
        XCTAssertEqual(ContinuityEvaluator.proofSignals(from: evidence), [])
    }

    func testTrustedBLEWitnessRowsAreDirectAppOnlyEvidence() {
        let snapshot = LocalEvidenceSnapshot(
            interval: DateInterval(start: at(0), end: at(120)),
            rows: [
                window(
                    sensorId: "trusted_ble_witness",
                    laneGroup: "environment",
                    evidenceKind: "trusted_ble_presence",
                    quality: .observed,
                    seconds: 30,
                    extractorVersion: LocalEvidenceReplay.sensorWriterExtractorVersion,
                    collectionSurface: "trusted_ble_witness_scanner"
                ),
            ]
        )

        let evidence = LocalEvidenceReplay.sensorEvidenceSnapshot(from: snapshot, now: at(120))

        XCTAssertEqual(LocalEvidenceReplay.sensorWriterRowCount(in: snapshot), 1)
        XCTAssertEqual(evidence.points.first?.lane, .trustedBLEWitness)
        XCTAssertEqual(evidence.points.first?.state, .observed)
        XCTAssertEqual(ContinuityEvaluator.proofSignals(from: evidence), [])
    }

    func testPermissionUnavailableMatrixReplaysAsUnavailableNotProof() {
        let cases: [PermissionUnavailableCase] = [
            PermissionUnavailableCase(sensor: "device_motion", laneGroup: "movement", kind: "motion_bucket", permission: .denied),
            PermissionUnavailableCase(sensor: "activity", laneGroup: "movement", kind: "activity_history_window", permission: .restricted),
            PermissionUnavailableCase(
                sensor: "pedometer",
                laneGroup: "movement",
                kind: "pedometer_history_window",
                permission: .notDetermined
            ),
            PermissionUnavailableCase(sensor: "location", laneGroup: "place", kind: "location_context", permission: .denied),
            PermissionUnavailableCase(sensor: "focus", laneGroup: "attention_focus", kind: "focus_state", permission: .restricted),
            PermissionUnavailableCase(sensor: "bluetooth", laneGroup: "network", kind: "bluetooth_context", permission: .denied),
            PermissionUnavailableCase(sensor: "connectivity", laneGroup: "network", kind: "network_path", permission: .unavailable),
            PermissionUnavailableCase(
                sensor: "screen_brightness",
                laneGroup: "device_environment",
                kind: "brightness_bucket",
                permission: .unavailable
            ),
        ]
        let rows = cases.enumerated().map { index, item in
            window(
                sensorId: item.sensor,
                laneGroup: item.laneGroup,
                evidenceKind: item.kind,
                quality: .unavailable,
                permission: item.permission,
                support: .unavailable,
                seconds: TimeInterval(10 + index),
                extractorVersion: LocalEvidenceReplay.sensorWriterExtractorVersion,
                collectionSurface: "sensor_monitor"
            )
        }

        let evidence = LocalEvidenceReplay.sensorEvidenceSnapshot(
            from: LocalEvidenceSnapshot(interval: DateInterval(start: at(0), end: at(120)), rows: rows),
            now: at(120),
            freshnessWindow: 300
        )

        XCTAssertTrue(evidence.points.allSatisfy { $0.state == .unavailable })
        XCTAssertTrue(evidence.points.allSatisfy { $0.supportStatus == .unavailable })
        XCTAssertEqual(ContinuityEvaluator.proofSignals(from: evidence), [])
        XCTAssertEqual(evidence.points.first { $0.lane == ContinuityEvidenceLane.motion }?.reason, "permission_not_determined")
        XCTAssertEqual(evidence.points.first { $0.lane == ContinuityEvidenceLane.place }?.reason, "permission_denied")
        XCTAssertEqual(evidence.points.first { $0.lane == ContinuityEvidenceLane.focus }?.reason, "permission_restricted")
        XCTAssertEqual(evidence.points.first { $0.lane == ContinuityEvidenceLane.connectivity }?.reason, "permission_unavailable")
        XCTAssertEqual(evidence.points.first { $0.lane == ContinuityEvidenceLane.ambientLight }?.reason, "permission_unavailable")
    }

    private func window(
        sensorId: String,
        laneGroup: String,
        evidenceKind: String,
        quality: LocalEvidenceQuality,
        permission: LocalEvidencePermissionState = .authorized,
        support: LocalEvidenceSupportState = .available,
        seconds: TimeInterval,
        extractorVersion: String = "test",
        collectionSurface: String = "unit_test"
    ) -> LocalEvidenceWindow {
        LocalEvidenceWindow(
            capturedAt: at(seconds),
            windowStartAt: at(seconds - 60),
            windowEndAt: at(seconds),
            sensorId: sensorId,
            laneGroup: laneGroup,
            evidenceKind: evidenceKind,
            source: "unit_test",
            collectionSurface: collectionSurface,
            quality: quality,
            permissionState: permission,
            supportState: support,
            freshnessSeconds: 0,
            extractorVersion: extractorVersion,
            privacyClass: .localWindow,
            payload: ["state": quality.rawValue],
            createdAt: at(seconds)
        )
    }
}
