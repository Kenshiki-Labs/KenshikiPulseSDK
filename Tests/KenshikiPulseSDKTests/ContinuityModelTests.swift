import XCTest
@testable import KenshikiPulseSDK

final class ContinuityModelTests: XCTestCase {
    private let now = Date()
    private let attested = 1.0   // stateWeight for an attested-continuous device
    private let notAttested = 0.0

    // MARK: - Curves

    func testDaysMaturityIsLogisticAndMonotonic() {
        XCTAssertEqual(ContinuityModel.daysMaturity(45), 0.5, accuracy: 0.01)   // centered at t_half
        XCTAssertLessThan(ContinuityModel.daysMaturity(7), ContinuityModel.daysMaturity(30))
        XCTAssertLessThan(ContinuityModel.daysMaturity(30), ContinuityModel.daysMaturity(90))
        XCTAssertGreaterThan(ContinuityModel.daysMaturity(180), 0.99)
    }

    func testCheckInMaturitySaturates() {
        XCTAssertEqual(ContinuityModel.checkInMaturity(0), 0, accuracy: 0.0001)
        XCTAssertLessThan(ContinuityModel.checkInMaturity(10), ContinuityModel.checkInMaturity(90))
        XCTAssertGreaterThan(ContinuityModel.checkInMaturity(90), 0.9)
    }

    // MARK: - Geometric mean (soft-AND, anti-gaming)

    func testGeometricMeanIsSoftAnd() {
        XCTAssertEqual(ContinuityModel.geometricMean([1, 1, 1]), 1, accuracy: 0.0001)
        let g = ContinuityModel.geometricMean([1, 1, 0.1])
        XCTAssertLessThan(g, 0.55)
    }

    // MARK: - evaluate()

    func testNewInstallScoresLow() {
        let r = ContinuityModel.evaluate(signalsLive: 0, signalsTotal: 6, stateWeight: notAttested,
                                         lastCheckIn: nil, daysContinuous: 0, checkInCount: 0, now: now)
        XCTAssertLessThan(r.mean, 0.1)            // earned, not declared
        XCTAssertLessThanOrEqual(r.lowerBound, r.mean)
    }

    func testMaturedRealUserScoresHighWithConfidence() {
        let r = ContinuityModel.evaluate(signalsLive: 6, signalsTotal: 6, stateWeight: attested,
                                         lastCheckIn: now, daysContinuous: 180, checkInCount: 120, now: now)
        XCTAssertGreaterThan(r.mean, 0.7)
        XCTAssertGreaterThan(r.lowerBound, 0.7)
        XCTAssertGreaterThan(r.confidence, 0.7)   // tight posterior once evidence has accrued
    }

    func testLowerBoundNeverExceedsMean() {
        for days in [0, 7, 30, 90, 200] {
            for checks in [0, 1, 10, 90] {
                let r = ContinuityModel.evaluate(signalsLive: 4, signalsTotal: 6, stateWeight: attested,
                                                 lastCheckIn: now, daysContinuous: days, checkInCount: checks, now: now)
                XCTAssertLessThanOrEqual(r.lowerBound, r.mean + 1e-9, "days=\(days) checks=\(checks)")
            }
        }
    }

    func testMeanIsMonotonicInDays() {
        func mean(_ days: Int) -> Double {
            ContinuityModel.evaluate(signalsLive: 6, signalsTotal: 6, stateWeight: attested,
                                     lastCheckIn: now, daysContinuous: days, checkInCount: 30, now: now).mean
        }
        XCTAssertLessThan(mean(7), mean(30))
        XCTAssertLessThan(mean(30), mean(90))
    }

    func testConfidenceRisesWithCheckIns() {
        func confidence(_ checks: Int) -> Double {
            ContinuityModel.evaluate(signalsLive: 6, signalsTotal: 6, stateWeight: attested,
                                     lastCheckIn: now, daysContinuous: 60, checkInCount: checks, now: now).confidence
        }
        XCTAssertLessThan(confidence(1), confidence(90))   // more evidence → tighter bound
    }

    func testSparseEvidenceBreadthLowersConfidenceWithoutCallingSignalsBad() {
        let full = ContinuityModel.evaluate(signalsLive: 6, signalsTotal: 6, stateWeight: attested,
                                            lastCheckIn: now, daysContinuous: 90, checkInCount: 90,
                                            evidenceWeight: 1.0, now: now)
        let sparse = ContinuityModel.evaluate(signalsLive: 2, signalsTotal: 2, stateWeight: attested,
                                              lastCheckIn: now, daysContinuous: 90, checkInCount: 90,
                                              evidenceWeight: 2.0 / 11.0, now: now)

        XCTAssertEqual(ContinuityModel.coverage(live: 2, total: 2), 1.0)
        XCTAssertLessThan(sparse.mean, full.mean)
        XCTAssertLessThan(sparse.confidence, full.confidence)
        XCTAssertLessThan(sparse.lowerBound, full.lowerBound)
        XCTAssertEqual(sparse.terms.breadth, 2.0 / 11.0, accuracy: 1e-9)
        XCTAssertEqual(sparse.terms.coverage, 1.0, accuracy: 1e-9)
    }

    func testEvaluateFromEvidenceSnapshotUsesCoverageAndBreadth() {
        let snapshot = ContinuityEvidenceSnapshot(points: [
            ContinuityEvidencePoint(lane: .battery, state: .observed, supportStatus: .available),
            ContinuityEvidencePoint(lane: .motion, state: .empty, supportStatus: .available),
            ContinuityEvidencePoint(lane: .magnetometer, state: .unavailable, supportStatus: .unavailable),
            ContinuityEvidencePoint(lane: .barometer, state: .stale, supportStatus: .available),
            ContinuityEvidencePoint(lane: .telephony, state: .contradictory, supportStatus: .available)
        ])

        let result = ContinuityModel.evaluate(snapshot: snapshot,
                                              stateWeight: attested,
                                              lastCheckIn: now,
                                              daysContinuous: 90,
                                              checkInCount: 90,
                                              now: now)

        XCTAssertEqual(result.terms.coverage, 1.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(result.terms.breadth, 3.0 / 6.0, accuracy: 1e-9)
        XCTAssertEqual(result.terms.effectiveCheckIns, 90.0 * 3.0 / 6.0, accuracy: 1e-9)
        XCTAssertEqual(result.terms.posteriorMean, result.mean, accuracy: 1e-9)
        XCTAssertEqual(result.terms.lowerCredibleBound, result.lowerBound, accuracy: 1e-9)
        XCTAssertGreaterThan(result.terms.confidenceWidth, 0)
    }

    func testMoreCoherentObservedEvidenceDoesNotLowerMean() {
        let lowCoverage = ContinuityModel.evaluate(signalsLive: 3, signalsTotal: 6,
                                                   stateWeight: attested,
                                                   lastCheckIn: now,
                                                   daysContinuous: 90,
                                                   checkInCount: 90,
                                                   now: now)
        let highCoverage = ContinuityModel.evaluate(signalsLive: 4, signalsTotal: 6,
                                                    stateWeight: attested,
                                                    lastCheckIn: now,
                                                    daysContinuous: 90,
                                                    checkInCount: 90,
                                                    now: now)

        XCTAssertGreaterThanOrEqual(highCoverage.mean, lowCoverage.mean)
    }

    func testIncreasedStalenessDoesNotIncreaseConfidence() {
        let fresh = ContinuityModel.evaluate(signalsLive: 6, signalsTotal: 6,
                                             stateWeight: attested,
                                             lastCheckIn: now,
                                             daysContinuous: 90,
                                             checkInCount: 90,
                                             now: now)
        let stale = ContinuityModel.evaluate(signalsLive: 6, signalsTotal: 6,
                                             stateWeight: attested,
                                             lastCheckIn: now.addingTimeInterval(-96 * 60 * 60),
                                             daysContinuous: 90,
                                             checkInCount: 90,
                                             now: now)

        XCTAssertLessThanOrEqual(stale.mean, fresh.mean)
        XCTAssertLessThanOrEqual(stale.confidence, fresh.confidence)
    }

    func testCannotGameWithCoverageWhenStateIsWeak() {
        // Full coverage + recency but NOT attested → soft-AND must penalize hard.
        let gamed = ContinuityModel.evaluate(signalsLive: 6, signalsTotal: 6, stateWeight: notAttested,
                                             lastCheckIn: now, daysContinuous: 30, checkInCount: 10, now: now)
        let real = ContinuityModel.evaluate(signalsLive: 6, signalsTotal: 6, stateWeight: attested,
                                            lastCheckIn: now, daysContinuous: 30, checkInCount: 10, now: now)
        XCTAssertLessThan(gamed.mean, real.mean)
        XCTAssertLessThan(gamed.mean, 0.35)
        XCTAssertGreaterThan(real.mean, 0.4)
    }

    // MARK: - signal_authenticity

    func testSignalAuthenticityNeutralCoherenceMatchesLiveQuality() {
        let q = ContinuityModel.instantaneousQuality(coverage: 0.8, stateWeight: 1.0, recency: 1.0)
        let a = ContinuityModel.signalAuthenticity(coverage: 0.8, stateWeight: 1.0, recency: 1.0)
        XCTAssertEqual(a, q, accuracy: 1e-9)
    }

    func testLowerCoherenceLowersAuthenticityAndMean() {
        let high = ContinuityModel.signalAuthenticity(coverage: 1, stateWeight: 1, recency: 1, coherence: 1.0)
        let low = ContinuityModel.signalAuthenticity(coverage: 1, stateWeight: 1, recency: 1, coherence: 0.5)
        XCTAssertLessThan(low, high)

        let coherent = ContinuityModel.evaluate(signalsLive: 6, signalsTotal: 6, stateWeight: attested,
                                                lastCheckIn: now, daysContinuous: 90, checkInCount: 30,
                                                coherence: 1.0, now: now)
        let incoherent = ContinuityModel.evaluate(signalsLive: 6, signalsTotal: 6, stateWeight: attested,
                                                  lastCheckIn: now, daysContinuous: 90, checkInCount: 30,
                                                  coherence: 0.4, now: now)
        XCTAssertLessThan(incoherent.mean, coherent.mean)
    }

    func testAuthenticityStaysInUnitInterval() {
        for coherence in [-1.0, 0.0, 0.3, 1.0, 2.0] {
            let a = ContinuityModel.signalAuthenticity(coverage: 0.7, stateWeight: 0.8, recency: 0.9, coherence: coherence)
            XCTAssertGreaterThanOrEqual(a, 0)
            XCTAssertLessThanOrEqual(a, 1)
        }
    }
}
