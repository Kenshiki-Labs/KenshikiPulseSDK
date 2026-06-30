import XCTest
@testable import KenshikiPulseSDK

final class ContinuityEvaluatorTests: XCTestCase {
    func testUnavailableAndUnsupportedSignalsDoNotLowerCoverage() {
        let signals = DeviceSignals(
            battery: BatterySignal(support: .available, level: 0.8),
            motion: MotionSignal(support: .unavailable),
            magnetometer: MagnetometerSignal(support: .available,
                                             sampleCount: 1,
                                             fieldMagnitudeMicrotesla: 41,
                                             calibrationAccuracy: "high"),
            barometer: BarometerSignal(support: .notSupported),
            ambientLight: AmbientLightSignal(support: .notCollected),
            deviceSurface: DeviceSurfaceSignal(support: .available,
                                               platform: "iOS",
                                               systemName: "iOS",
                                               simulator: false),
            telephony: TelephonySignal(support: .disabled)
        )

        let evaluation = ContinuityEvaluator.evaluate(signals: signals, previous: nil)

        XCTAssertEqual(evaluation.signalsLive, 3)
        XCTAssertEqual(evaluation.signalsTotal, 3)
        XCTAssertEqual(ContinuityModel.coverage(live: evaluation.signalsLive,
                                                total: evaluation.signalsTotal), 1.0)
        XCTAssertEqual(evaluation.evidenceSnapshot.liveCount, 3)
        XCTAssertEqual(evaluation.evidenceSnapshot.eligibleCount, 3)
        XCTAssertEqual(evaluation.evidenceSnapshot.unavailableCount, 8)
    }

    func testAvailableSignalWithoutSampleStillLowersCoverage() {
        let signals = DeviceSignals(
            battery: BatterySignal(support: .available, level: 0.8),
            motion: MotionSignal(support: .available),
            magnetometer: MagnetometerSignal(support: .unavailable),
            barometer: BarometerSignal(support: .unavailable),
            ambientLight: AmbientLightSignal(support: .unavailable),
            deviceSurface: DeviceSurfaceSignal(support: .available,
                                               platform: "iOS",
                                               systemName: "iOS",
                                               simulator: false)
        )

        let evaluation = ContinuityEvaluator.evaluate(signals: signals, previous: nil)

        XCTAssertEqual(evaluation.signalsLive, 2)
        XCTAssertEqual(evaluation.signalsTotal, 3)
        XCTAssertEqual(ContinuityModel.coverage(live: evaluation.signalsLive,
                                                total: evaluation.signalsTotal), 2.0 / 3.0)
        XCTAssertEqual(evaluation.evidenceSnapshot.points.first { $0.lane == .motion }?.state, .empty)
        XCTAssertEqual(evaluation.evidenceSnapshot.emptyCount, 1)
    }

    func testBluetoothDeniedOnlyIsUnavailableNotPositiveEvidence() {
        let signals = DeviceSignals(
            battery: BatterySignal(support: .available, level: 0.8),
            motion: MotionSignal(support: .unavailable),
            magnetometer: MagnetometerSignal(support: .unavailable),
            barometer: BarometerSignal(support: .unavailable),
            ambientLight: AmbientLightSignal(support: .unavailable),
            bluetooth: BluetoothSignal(support: .available,
                                       authorization: "denied",
                                       radioState: "unauthorized",
                                       scanAvailable: false,
                                       audioRouteClass: "none",
                                       audioRouteConnected: false),
            deviceSurface: DeviceSurfaceSignal(support: .available,
                                               platform: "iOS",
                                               systemName: "iOS",
                                               simulator: false)
        )

        let evaluation = ContinuityEvaluator.evaluate(signals: signals, previous: nil)

        XCTAssertEqual(evaluation.signalsLive, 2)
        XCTAssertEqual(evaluation.signalsTotal, 2)
        XCTAssertEqual(evaluation.evidenceSnapshot.points.first { $0.lane == .bluetooth }?.state, .unavailable)
        XCTAssertEqual(evaluation.evidenceSnapshot.points.first { $0.lane == .bluetooth }?.reason,
                       "bluetooth_denied_without_route")
    }

    func testBluetoothDeniedWithAudioRouteStillCarriesRouteContext() {
        let signals = DeviceSignals(
            battery: BatterySignal(support: .available, level: 0.8),
            motion: MotionSignal(support: .unavailable),
            magnetometer: MagnetometerSignal(support: .unavailable),
            barometer: BarometerSignal(support: .unavailable),
            ambientLight: AmbientLightSignal(support: .unavailable),
            bluetooth: BluetoothSignal(support: .available,
                                       authorization: "denied",
                                       radioState: "unauthorized",
                                       scanAvailable: false,
                                       audioRouteClass: "car",
                                       audioRouteConnected: true),
            deviceSurface: DeviceSurfaceSignal(support: .available,
                                               platform: "iOS",
                                               systemName: "iOS",
                                               simulator: false)
        )

        let evaluation = ContinuityEvaluator.evaluate(signals: signals, previous: nil)

        XCTAssertEqual(evaluation.signalsLive, 3)
        XCTAssertEqual(evaluation.signalsTotal, 3)
        XCTAssertEqual(evaluation.evidenceSnapshot.points.first { $0.lane == .bluetooth }?.state, .observed)
    }

    func testProofLaneDenominatorDoesNotChangeWhenAppOnlyLanesExist() {
        XCTAssertEqual(ContinuityEvaluation.possibleProofSignalCount, 11)
        XCTAssertEqual(ContinuityEvidenceLane.proofLanes.count, 11)
        XCTAssertTrue(ContinuityEvidenceLane.allCases.contains(.place))
        XCTAssertTrue(ContinuityEvidenceLane.allCases.contains(.focus))
    }

    func testStaleSnapshotKeepsEligibilityButRemovesLiveCredit() {
        let collectedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let now = collectedAt.addingTimeInterval(4 * 24 * 60 * 60)
        let evaluation = ContinuityEvaluator.evaluate(
            signals: mostlyLiveSignals(),
            previous: nil,
            collectedAt: collectedAt,
            now: now
        )

        XCTAssertGreaterThan(evaluation.evidenceSnapshot.staleCount, 0)
        XCTAssertEqual(evaluation.evidenceSnapshot.liveCount, 0)
        XCTAssertGreaterThan(evaluation.evidenceSnapshot.eligibleCount, 0)
        XCTAssertEqual(evaluation.explanation.staleLanes.sortedByRawValue(),
                       evaluation.evidenceSnapshot.points
                           .compactMap { $0.state == .stale ? $0.lane : nil }
                           .sortedByRawValue())
    }

    func testTelephonyContradictionLowersCoverageAndExplainsIt() {
        let signals = DeviceSignals(
            battery: BatterySignal(support: .available, level: 0.8),
            motion: MotionSignal(support: .unavailable),
            magnetometer: MagnetometerSignal(support: .unavailable),
            barometer: BarometerSignal(support: .unavailable),
            ambientLight: AmbientLightSignal(support: .unavailable),
            deviceSurface: DeviceSurfaceSignal(support: .available,
                                               platform: "iOS",
                                               systemName: "iOS",
                                               simulator: false),
            telephony: TelephonySignal(support: .available,
                                       simInserted: false,
                                       radioGenerations: ["5g"],
                                       serviceCount: 1,
                                       dataServiceAvailable: true)
        )

        let evaluation = ContinuityEvaluator.evaluate(signals: signals, previous: nil)
        let telephony = evaluation.evidenceSnapshot.points.first { $0.lane == .telephony }

        XCTAssertEqual(telephony?.state, .contradictory)
        XCTAssertEqual(telephony?.reason, "sim_absent_with_radio_evidence")
        XCTAssertTrue(evaluation.explanation.contradictoryLanes.contains(.telephony))
        XCTAssertEqual(evaluation.signalsLive, 2)
        XCTAssertEqual(evaluation.signalsTotal, 3)
    }

    func testFormalAdversarialTraceReplay() {
        let previous = DeviceFingerprint(from: mostlyLiveSignals(wifiNetworkHash: "known-network"))
        let traces: [TraceExpectation] = [
            TraceExpectation(
                name: "all permissions denied",
                signals: allUnavailableSignals(),
                previous: nil,
                expectedBreak: nil,
                expectedNetwork: .unknown,
                expectedUnavailableAtLeast: 10,
                expectedLive: 1
            ),
            TraceExpectation(
                name: "network absent",
                signals: mostlyLiveSignals(wifiNetworkHash: nil),
                previous: previous,
                expectedBreak: nil,
                expectedNetwork: .unknown,
                expectedUnavailableAtLeast: 0
            ),
            TraceExpectation(
                name: "known network changed",
                signals: mostlyLiveSignals(wifiNetworkHash: "other-network"),
                previous: previous,
                expectedBreak: nil,
                expectedNetwork: .changed,
                expectedUnavailableAtLeast: 0
            ),
            TraceExpectation(
                name: "bluetooth denied without route",
                signals: mostlyLiveSignals(bluetooth: BluetoothSignal(support: .available,
                                                                      authorization: "denied",
                                                                      radioState: "unauthorized",
                                                                      scanAvailable: false,
                                                                      audioRouteClass: "none",
                                                                      audioRouteConnected: false)),
                previous: nil,
                expectedBreak: nil,
                expectedNetwork: .unknown,
                expectedUnavailableAtLeast: 1
            ),
            TraceExpectation(
                name: "bluetooth route visible despite denied scan",
                signals: mostlyLiveSignals(bluetooth: BluetoothSignal(support: .available,
                                                                      authorization: "denied",
                                                                      radioState: "unauthorized",
                                                                      scanAvailable: false,
                                                                      audioRouteClass: "car",
                                                                      audioRouteConnected: true)),
                previous: nil,
                expectedBreak: nil,
                expectedNetwork: .unknown,
                expectedUnavailableAtLeast: 0
            )
        ]

        for trace in traces {
            let evaluation = ContinuityEvaluator.evaluate(signals: trace.signals, previous: trace.previous)
            XCTAssertEqual(evaluation.breakReason, trace.expectedBreak, trace.name)
            XCTAssertEqual(evaluation.networkStability, trace.expectedNetwork, trace.name)
            XCTAssertGreaterThanOrEqual(evaluation.evidenceSnapshot.unavailableCount,
                                        trace.expectedUnavailableAtLeast,
                                        trace.name)
            if let expectedLive = trace.expectedLive {
                XCTAssertEqual(evaluation.signalsLive, expectedLive, trace.name)
            }
        }
    }

    func testNetworkChangeDoesNotCreateBreak() {
        let previous = DeviceFingerprint(from: mostlyLiveSignals(wifiNetworkHash: "known-network"))
        let evaluation = ContinuityEvaluator.evaluate(
            signals: mostlyLiveSignals(wifiNetworkHash: "other-network"),
            previous: previous
        )

        XCTAssertNil(evaluation.breakReason)
        XCTAssertEqual(evaluation.networkStability, .changed)
        XCTAssertEqual(evaluation.coherence, ContinuityModel.networkChangeCoherence)
    }

    func testConnectivityInventoryWithoutCurrentPathIsEmptyNotProof() {
        var signals = mostlyLiveSignals()
        signals.connectivity = ConnectivitySignal(
            support: .available,
            availableInterfaceTypes: ["wifi", "cellular"],
            expensive: false,
            constrained: false
        )

        let evaluation = ContinuityEvaluator.evaluate(signals: signals, previous: nil)
        let connectivity = evaluation.evidenceSnapshot.points.first { $0.lane == .connectivity }

        XCTAssertEqual(connectivity?.state, .empty)
        XCTAssertEqual(evaluation.signalsLive, 10)
        XCTAssertEqual(evaluation.signalsTotal, 11)
    }

    func testUnsatisfiedConnectivityIsEmptyNeutralContext() {
        var signals = mostlyLiveSignals()
        signals.connectivity = ConnectivitySignal(
            support: .available,
            pathStatus: "unsatisfied",
            unsatisfiedReason: "not_available",
            availableInterfaceTypes: ["cellular"]
        )

        let evaluation = ContinuityEvaluator.evaluate(signals: signals, previous: nil)
        let connectivity = evaluation.evidenceSnapshot.points.first { $0.lane == .connectivity }

        XCTAssertEqual(connectivity?.state, .empty)
        XCTAssertEqual(evaluation.signalsLive, 10)
        XCTAssertEqual(evaluation.signalsTotal, 11)
        XCTAssertEqual(evaluation.networkStability, .unknown)
    }

    private struct TraceExpectation {
        let name: String
        let signals: DeviceSignals
        let previous: DeviceFingerprint?
        let expectedBreak: ContinuityBreakReason?
        let expectedNetwork: NetworkStability
        let expectedUnavailableAtLeast: Int
        let expectedLive: Int?

        init(name: String,
             signals: DeviceSignals,
             previous: DeviceFingerprint?,
             expectedBreak: ContinuityBreakReason?,
             expectedNetwork: NetworkStability,
             expectedUnavailableAtLeast: Int,
             expectedLive: Int? = nil) {
            self.name = name
            self.signals = signals
            self.previous = previous
            self.expectedBreak = expectedBreak
            self.expectedNetwork = expectedNetwork
            self.expectedUnavailableAtLeast = expectedUnavailableAtLeast
            self.expectedLive = expectedLive
        }
    }

    private func mostlyLiveSignals(wifiNetworkHash: String? = nil,
                                   bluetooth: BluetoothSignal = BluetoothSignal(
                                    support: .available,
                                    authorization: "allowed",
                                    radioState: "powered_on",
                                    scanAvailable: true,
                                    audioRouteClass: "none",
                                    audioRouteConnected: false
                                   )) -> DeviceSignals {
        DeviceSignals(
            battery: BatterySignal(support: .available, level: 0.8),
            motion: MotionSignal(support: .available,
                                 sampleCount: 1,
                                 userAccelerationMagnitude: 0.1),
            magnetometer: MagnetometerSignal(support: .available,
                                             sampleCount: 1,
                                             fieldMagnitudeMicrotesla: 41,
                                             calibrationAccuracy: "high"),
            barometer: BarometerSignal(support: .available, pressureKilopascals: 101.2),
            ambientLight: AmbientLightSignal(support: .available, screenBrightnessLevel: 0.4),
            mediaOutput: MediaOutputSignal(support: .available,
                                           routeClass: "speaker",
                                           external: false,
                                           otherAudioPlaying: false),
            displayProjection: DisplayProjectionSignal(support: .available,
                                                       screenCaptured: false,
                                                       externalDisplayCount: 0,
                                                       projectionStatus: "local"),
            connectivity: ConnectivitySignal(support: .available,
                                             pathStatus: "satisfied",
                                             interfaceTypes: ["wifi"],
                                             availableInterfaceTypes: ["wifi", "cellular"],
                                             wifiNetworkHash: wifiNetworkHash),
            bluetooth: bluetooth,
            deviceSurface: DeviceSurfaceSignal(support: .available,
                                               platform: "iOS",
                                               systemName: "iOS",
                                               systemMajorVersion: 18,
                                               interfaceIdiom: "phone",
                                               simulator: false),
            telephony: TelephonySignal(support: .available,
                                       simInserted: true,
                                       radioGenerations: ["5g"],
                                       serviceCount: 1,
                                       radioVisibility: "visible")
        )
    }

    private func allUnavailableSignals() -> DeviceSignals {
        DeviceSignals(
            battery: BatterySignal(support: .unavailable),
            motion: MotionSignal(support: .unavailable),
            magnetometer: MagnetometerSignal(support: .unavailable),
            barometer: BarometerSignal(support: .unavailable),
            ambientLight: AmbientLightSignal(support: .unavailable),
            mediaOutput: MediaOutputSignal(support: .unavailable),
            displayProjection: DisplayProjectionSignal(support: .unavailable),
            connectivity: ConnectivitySignal(support: .unavailable),
            bluetooth: BluetoothSignal(support: .unavailable),
            deviceSurface: DeviceSurfaceSignal(support: .available,
                                               platform: "iOS",
                                               systemName: "iOS",
                                               simulator: false),
            telephony: TelephonySignal(support: .unavailable)
        )
    }
}

private extension SignalSupport {
    static var available: SignalSupport { SignalSupport(status: .available) }
    static var unavailable: SignalSupport { SignalSupport(status: .unavailable) }
    static var notSupported: SignalSupport { SignalSupport(status: .notSupportedByPlatform) }
    static var notCollected: SignalSupport { SignalSupport(status: .notCollected) }
    static var disabled: SignalSupport { SignalSupport(status: .disabledByConfiguration) }
}

private extension Array where Element == ContinuityEvidenceLane {
    func sortedByRawValue() -> [ContinuityEvidenceLane] {
        sorted { $0.rawValue < $1.rawValue }
    }
}
