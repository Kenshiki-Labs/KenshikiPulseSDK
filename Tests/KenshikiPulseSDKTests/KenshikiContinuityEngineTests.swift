import XCTest
@testable import KenshikiPulseSDK

final class KenshikiContinuityEngineTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Pure state machine (advance)

    func testAdvanceFirstCheckInEstablishesStreak() {
        let prior = ContinuityPersistentState()   // fresh: count 0, notAttested
        let r = KenshikiContinuityEngine.advance(prior: prior, evaluation: live(), now: t0)
        XCTAssertEqual(r.state, .attestedContinuous)
        XCTAssertEqual(r.lockedSince, t0)
        XCTAssertEqual(r.checkInCount, 1)
        XCTAssertEqual(r.outcome, .firstCheckIn)
        XCTAssertTrue(r.state.isLocked)
    }

    func testAdvanceContinuousPreservesLockedSince() {
        let prior = ContinuityPersistentState(state: .attestedContinuous, lockedSince: t0, checkInCount: 5)
        let later = t0.addingTimeInterval(86_400)
        let r = KenshikiContinuityEngine.advance(prior: prior, evaluation: live(), now: later)
        XCTAssertEqual(r.state, .attestedContinuous)
        XCTAssertEqual(r.lockedSince, t0)          // streak origin unchanged
        XCTAssertEqual(r.checkInCount, 6)
        XCTAssertEqual(r.outcome, .continuous)
    }

    func testAdvanceBreakResetsStreak() {
        let prior = ContinuityPersistentState(state: .attestedContinuous, lockedSince: t0, checkInCount: 5)
        let r = KenshikiContinuityEngine.advance(prior: prior, evaluation: broken(.deviceChange), now: t0)
        XCTAssertEqual(r.state, .recentBreak)
        XCTAssertNil(r.lockedSince)                // streak resets
        XCTAssertEqual(r.checkInCount, 6)
        XCTAssertEqual(r.outcome, .breakDetected(.deviceChange))
        XCTAssertFalse(r.state.isLocked)
    }

    func testAdvanceRestoredAfterBreakStartsNewStreak() {
        let prior = ContinuityPersistentState(state: .recentBreak, lockedSince: nil, checkInCount: 5)
        let later = t0.addingTimeInterval(3_600)
        let r = KenshikiContinuityEngine.advance(prior: prior, evaluation: live(), now: later)
        XCTAssertEqual(r.state, .attestedContinuous)
        XCTAssertEqual(r.lockedSince, later)       // new streak origin
        XCTAssertEqual(r.outcome, .restored)
    }

    // MARK: - Full engine (stubbed collector + in-memory store)

    func testCheckInPersistsAndEstablishesStreak() async throws {
        let store = InMemoryContinuityStateStore()
        let engine = KenshikiContinuityEngine(collectEvidence: { _ in self.makeEnvelope() }, store: store)

        let result = try await engine.checkIn(context: KenshikiSessionContext(applicantId: "self"))

        XCTAssertEqual(result.outcome, .firstCheckIn)
        XCTAssertEqual(result.state, .attestedContinuous)
        XCTAssertEqual(result.checkInCount, 1)
        XCTAssertEqual(result.lastCheckIn, t0)
        XCTAssertEqual(result.evaluation.signalsTotal, 5)

        let persisted = await store.load()         // engine wrote through the store
        XCTAssertEqual(persisted.checkInCount, 1)
        XCTAssertEqual(persisted.state, .attestedContinuous)
        XCTAssertNotNil(persisted.fingerprint)
    }

    func testTwoCheckInsHoldStreakViaStore() async throws {
        let store = InMemoryContinuityStateStore()
        let engine = KenshikiContinuityEngine(collectEvidence: { _ in self.makeEnvelope() }, store: store)
        _ = try await engine.checkIn(context: .init(applicantId: "self"))
        let second = try await engine.checkIn(context: .init(applicantId: "self"))

        XCTAssertEqual(second.outcome, .continuous)
        XCTAssertEqual(second.checkInCount, 2)
        XCTAssertEqual(second.lockedSince, t0)      // first check-in's origin, read back from the store
    }

    func testDeviceChangeBetweenCheckInsBreaks() async throws {
        let store = InMemoryContinuityStateStore()
        // First check-in fingerprints an iPhone; the stored fingerprint drives the next break check.
        let phone = KenshikiContinuityEngine(collectEvidence: { _ in self.makeEnvelope(idiom: "phone") }, store: store)
        _ = try await phone.checkIn(context: .init(applicantId: "self"))

        let pad = KenshikiContinuityEngine(collectEvidence: { _ in self.makeEnvelope(idiom: "pad") }, store: store)
        let result = try await pad.checkIn(context: .init(applicantId: "self"))

        XCTAssertEqual(result.outcome, .breakDetected(.deviceChange))
        XCTAssertEqual(result.state, .recentBreak)
        XCTAssertNil(result.lockedSince)
    }

    func testSimSwapBetweenCheckInsBreaks() async throws {
        let store = InMemoryContinuityStateStore()
        let withSim = KenshikiContinuityEngine(collectEvidence: { _ in self.makeEnvelope(simInserted: true) }, store: store)
        _ = try await withSim.checkIn(context: .init(applicantId: "self"))

        let noSim = KenshikiContinuityEngine(collectEvidence: { _ in self.makeEnvelope(simInserted: false) }, store: store)
        let result = try await noSim.checkIn(context: .init(applicantId: "self"))

        XCTAssertEqual(result.outcome, .breakDetected(.simSwap))
    }

    // MARK: - Fixtures

    private func live() -> ContinuityEvaluation {
        ContinuityEvaluation(proofSignals: Array(repeating: true, count: 11), breakReason: nil)
    }

    private func broken(_ reason: ContinuityBreakReason) -> ContinuityEvaluation {
        ContinuityEvaluation(proofSignals: Array(repeating: true, count: 11), breakReason: reason)
    }

    private func makeEnvelope(idiom: String = "phone", simInserted: Bool? = nil) -> DeviceEvidenceEnvelope {
        DeviceEvidenceEnvelope(
            generatedAt: t0,
            session: KenshikiSessionContext(sessionId: "s", applicantId: "self"),
            collection: DeviceEvidenceCollection(
                startedAt: t0, endedAt: t0, durationMilliseconds: 0, consentPolicy: .disabledForLocalTesting
            ),
            signals: DeviceSignals(
                battery: BatterySignal(support: SignalSupport(status: .available), level: 0.72, state: "charging"),
                motion: MotionSignal(support: SignalSupport(status: .available), sampleCount: 1, userAccelerationMagnitude: 0.1),
                magnetometer: MagnetometerSignal(
                    support: SignalSupport(status: .available),
                    sampleCount: 1,
                    fieldMagnitudeMicrotesla: 42.0,
                    calibrationAccuracy: "high"
                ),
                barometer: BarometerSignal(support: SignalSupport(status: .unavailable)),
                ambientLight: AmbientLightSignal(support: SignalSupport(status: .notSupportedByPlatform)),
                deviceSurface: DeviceSurfaceSignal(
                    support: SignalSupport(status: .available),
                    platform: "iOS", systemName: "iOS", systemMajorVersion: 18,
                    interfaceIdiom: idiom, simulator: true
                ),
                telephony: TelephonySignal(
                    support: SignalSupport(status: .available),
                    simInserted: simInserted, radioGenerations: ["4g"], callEventCount: 0, activeCallCount: 0
                )
            )
        )
    }
}
