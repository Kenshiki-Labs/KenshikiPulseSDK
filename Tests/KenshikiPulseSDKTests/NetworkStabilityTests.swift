import XCTest
@testable import KenshikiPulseSDK

final class NetworkStabilityTests: XCTestCase {

    func testStabilityRequiresTokensOnBothSides() {
        let withToken = fingerprint(wifi: "tokenA")
        let noToken = fingerprint(wifi: nil)
        XCTAssertEqual(ContinuityEvaluator.networkStability(previous: nil, current: withToken), .unknown)
        XCTAssertEqual(ContinuityEvaluator.networkStability(previous: noToken, current: withToken), .unknown)
        XCTAssertEqual(ContinuityEvaluator.networkStability(previous: withToken, current: noToken), .unknown)
    }

    func testSameTokenIsStableDifferentIsChanged() {
        let a = fingerprint(wifi: "tokenA")
        let a2 = fingerprint(wifi: "tokenA")
        let b = fingerprint(wifi: "tokenB")
        XCTAssertEqual(ContinuityEvaluator.networkStability(previous: a, current: a2), .stable)
        XCTAssertEqual(ContinuityEvaluator.networkStability(previous: a, current: b), .changed)
    }

    func testCoherenceIsNeutralExceptForChange() {
        XCTAssertEqual(evaluation(.stable).coherence, 1.0, accuracy: 1e-9)
        XCTAssertEqual(evaluation(.unknown).coherence, 1.0, accuracy: 1e-9)   // absence is not a penalty
        XCTAssertEqual(evaluation(.changed).coherence, ContinuityModel.networkChangeCoherence, accuracy: 1e-9)
        XCTAssertLessThan(evaluation(.changed).coherence, 1.0)
    }

    func testChangedNetworkLowersPulseButNeverBreaks() {
        // A changed network nudges the score down a hair, but it is NOT a break (no breakReason).
        XCTAssertNil(evaluation(.changed).breakReason)
        let stable = ContinuityModel.evaluate(signalsLive: 6, signalsTotal: 6, stateWeight: 1.0,
                                              lastCheckIn: Date(), daysContinuous: 90, checkInCount: 30,
                                              coherence: evaluation(.stable).coherence)
        let changed = ContinuityModel.evaluate(signalsLive: 6, signalsTotal: 6, stateWeight: 1.0,
                                              lastCheckIn: Date(), daysContinuous: 90, checkInCount: 30,
                                              coherence: evaluation(.changed).coherence)
        XCTAssertLessThan(changed.mean, stable.mean)
        XCTAssertGreaterThan(changed.mean, stable.mean * 0.95)   // shallow, not punitive
    }

    // MARK: - Fixtures

    private func fingerprint(wifi: String?) -> DeviceFingerprint {
        let off = SignalSupport(status: .notSupportedByPlatform)
        return DeviceFingerprint(from: DeviceSignals(
            battery: BatterySignal(support: off),
            motion: MotionSignal(support: off),
            magnetometer: MagnetometerSignal(support: off),
            barometer: BarometerSignal(support: off),
            ambientLight: AmbientLightSignal(support: off),
            connectivity: ConnectivitySignal(support: SignalSupport(status: .available), wifiNetworkHash: wifi),
            deviceSurface: DeviceSurfaceSignal(support: SignalSupport(status: .available),
                                               platform: "iOS", systemName: "iOS", simulator: true)
        ))
    }

    private func evaluation(_ stability: NetworkStability) -> ContinuityEvaluation {
        ContinuityEvaluation(proofSignals: Array(repeating: true, count: 11), breakReason: nil,
                             networkStability: stability)
    }
}
