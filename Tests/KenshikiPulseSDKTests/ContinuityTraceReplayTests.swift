import XCTest
@testable import KenshikiPulseSDK

final class ContinuityTraceReplayTests: XCTestCase {
    func testAdversarialTracePackReplaysAgainstFormalInvariants() throws {
        let pack = try loadPack(named: "adversarial-v1")
        XCTAssertEqual(pack.schemaVersion, "pulse-continuity-trace.v1")
        XCTAssertFalse(pack.traces.isEmpty)

        for trace in pack.traces {
            let evaluation = ContinuityEvaluator.evaluate(
                signals: trace.signals,
                previous: trace.previousFingerprint,
                collectedAt: Date(timeIntervalSince1970: trace.collectedAtUnix),
                now: Date(timeIntervalSince1970: trace.nowUnix)
            )
            let result = ContinuityModel.evaluate(
                snapshot: evaluation.evidenceSnapshot,
                stateWeight: 1.0,
                lastCheckIn: Date(timeIntervalSince1970: trace.nowUnix),
                daysContinuous: 90,
                checkInCount: 90,
                coherence: evaluation.coherence,
                now: Date(timeIntervalSince1970: trace.nowUnix)
            )

            assert(evaluation, result, matches: trace)
        }
    }

    private func assert(_ evaluation: ContinuityEvaluation,
                        _ result: ContinuityModel.Result,
                        matches trace: ContinuityTrace) {
        let label = "\(trace.id): \(trace.label)"

        XCTAssertEqual(evaluation.breakReason?.rawValue, trace.expected.breakReason, label)
        XCTAssertEqual(evaluation.networkStability.rawValue, trace.expected.networkStability, label)
        XCTAssertGreaterThanOrEqual(evaluation.evidenceSnapshot.unavailableCount,
                                    trace.expected.minUnavailable,
                                    label)
        if let maxUnavailable = trace.expected.maxUnavailable {
            XCTAssertLessThanOrEqual(evaluation.evidenceSnapshot.unavailableCount, maxUnavailable, label)
        }
        XCTAssertGreaterThanOrEqual(evaluation.evidenceSnapshot.contradictoryCount,
                                    trace.expected.minContradictory,
                                    label)
        XCTAssertGreaterThanOrEqual(evaluation.evidenceSnapshot.staleCount,
                                    trace.expected.minStale,
                                    label)
        if let minBreadth = trace.expected.minBreadth {
            XCTAssertGreaterThanOrEqual(result.terms.breadth, minBreadth, label)
        }
        if let maxBreadth = trace.expected.maxBreadth {
            XCTAssertLessThanOrEqual(result.terms.breadth, maxBreadth, label)
        }
        if let minCoverage = trace.expected.minCoverage {
            XCTAssertGreaterThanOrEqual(result.terms.coverage, minCoverage, label)
        }
        if let maxCoverage = trace.expected.maxCoverage {
            XCTAssertLessThanOrEqual(result.terms.coverage, maxCoverage, label)
        }
        if let minConfidence = trace.expected.minConfidence {
            XCTAssertGreaterThanOrEqual(result.confidence, minConfidence, label)
        }
        if let maxConfidence = trace.expected.maxConfidence {
            XCTAssertLessThanOrEqual(result.confidence, maxConfidence, label)
        }
    }

    private func loadPack(named name: String) throws -> ContinuityTracePack {
        let fixtureBundle: Bundle
        #if SWIFT_PACKAGE
        fixtureBundle = Bundle.module
        #else
        fixtureBundle = Bundle(for: Self.self)
        #endif

        let url = fixtureBundle.url(
            forResource: name,
            withExtension: "json",
            subdirectory: "continuity-traces"
        ) ?? fixtureBundle.url(
            forResource: name,
            withExtension: "json",
            subdirectory: "Fixtures/continuity-traces"
        ) ?? fixtureBundle.url(forResource: name, withExtension: "json")
        guard let url else {
            XCTFail("Missing fixture pack \(name).json")
            throw CocoaError(.fileNoSuchFile)
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(ContinuityTracePack.self, from: data)
    }
}

private struct ContinuityTracePack: Decodable {
    let schemaVersion: String
    let suite: String
    let traces: [ContinuityTrace]
}

private struct ContinuityTrace: Decodable {
    let id: String
    let label: String
    let kind: String
    let collectedAtUnix: TimeInterval
    let nowUnix: TimeInterval
    let previousFingerprint: DeviceFingerprint?
    let signals: DeviceSignals
    let expected: ContinuityTraceExpectation
}

private struct ContinuityTraceExpectation: Decodable {
    let breakReason: String?
    let networkStability: String
    let minUnavailable: Int
    let maxUnavailable: Int?
    let minContradictory: Int
    let minStale: Int
    let minBreadth: Double?
    let maxBreadth: Double?
    let minCoverage: Double?
    let maxCoverage: Double?
    let minConfidence: Double?
    let maxConfidence: Double?
}
