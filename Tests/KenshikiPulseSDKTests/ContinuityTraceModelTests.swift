import XCTest
@testable import KenshikiPulseSDK

final class ContinuityTraceModelTests: XCTestCase {
    func testGroupsTraceEventsBySessionAndIgnoresContinuityLog() throws {
        let at = Date(timeIntervalSince1970: 1_000)
        let events = [
            TelemetryEvent(
                id: "check",
                occurredAt: at,
                category: .checkIn,
                title: "Check-in",
                sessionId: "session-1",
                merkleRoot: "abcdef1234567890"
            ),
            TelemetryEvent(
                id: "motion",
                occurredAt: at.addingTimeInterval(1),
                category: .lifeSignal,
                signalId: "motion",
                title: "Motion",
                sessionId: "session-1",
                isLive: true,
                metadata: ["source": "signed"]
            ),
            TelemetryEvent(
                id: "focus",
                occurredAt: at.addingTimeInterval(2),
                category: .lifeSignal,
                signalId: "focus",
                title: "Focus",
                sessionId: "session-1",
                isLive: false,
                metadata: ["observed": "false"]
            ),
            TelemetryEvent(
                id: "log",
                occurredAt: at.addingTimeInterval(3),
                category: .continuityLog,
                title: "Log",
                sessionId: "session-1"
            ),
        ]

        let model = ContinuityTraceModel.make(events: events)

        XCTAssertEqual(model.sessions.count, 1)
        let session = try XCTUnwrap(model.sessions.first)
        XCTAssertEqual(session.id, "session-1")
        XCTAssertEqual(session.merkleRootPrefix, "abcdef123456")
        XCTAssertEqual(session.signals["motion"]?.status, .live)
        XCTAssertEqual(session.signals["focus"]?.status, .unobserved)
        XCTAssertEqual(session.liveSignalCount, 1)
        XCTAssertEqual(session.observedSignalCount, 1)
        XCTAssertTrue(model.ungroupedEvents.isEmpty)
    }
}
