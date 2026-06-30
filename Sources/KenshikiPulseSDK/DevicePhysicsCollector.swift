import Foundation

#if os(iOS) && canImport(AVFoundation)
import AVFoundation
#endif

#if os(iOS) && canImport(CoreMotion)
import CoreMotion
#endif

#if os(iOS) && canImport(CoreBluetooth)
import CoreBluetooth
#endif

#if os(iOS) && canImport(CoreTelephony)
import CoreTelephony
#endif

#if os(iOS) && canImport(UIKit)
import UIKit
#endif

#if canImport(Network)
import Network
#endif

public protocol DevicePhysicsCollecting: Sendable {
    func collectEvidence(context: KenshikiSessionContext) async throws -> DeviceEvidenceEnvelope
}

public final class DefaultDevicePhysicsCollector: DevicePhysicsCollecting, @unchecked Sendable {
    private let configuration: KenshikiPulseConfiguration

    public init(configuration: KenshikiPulseConfiguration = KenshikiPulseConfiguration()) {
        self.configuration = configuration
    }

    public func collectEvidence(context: KenshikiSessionContext) async throws -> DeviceEvidenceEnvelope {
        let startedAt = Date()
        async let barometerResult = barometerSignal()
        async let bluetoothResult = bluetoothSignal()
        async let connectivityResult = connectivitySignal()
        async let displayProjectionResult = displayProjectionSignal()
        let (motionResult, magnetometerResult) = try await motionAndMagnetometerSignals()
        let signals = DeviceSignals(
            battery: batterySignal(),
            motion: motionResult,
            magnetometer: magnetometerResult,
            barometer: await barometerResult,
            ambientLight: await ambientLightSignal(),
            mediaOutput: mediaOutputSignal(),
            displayProjection: await displayProjectionResult,
            connectivity: await connectivityResult,
            bluetooth: await bluetoothResult,
            deviceSurface: deviceSurfaceSignal(),
            telephony: telephonySignal()
        )
        let endedAt = Date()
        let duration = max(0, Int(endedAt.timeIntervalSince(startedAt) * 1_000))
        let collection = DeviceEvidenceCollection(
            startedAt: startedAt,
            endedAt: endedAt,
            durationMilliseconds: duration,
            consentPolicy: configuration.consentPolicy
        )
        return DeviceEvidenceEnvelope(
            generatedAt: endedAt,
            session: context,
            collection: collection,
            signals: signals,
            recurrence: deviceRecurrenceReceipt(context: context, now: endedAt)
        )
    }

    /// Salted, tenant-scoped, rotating device pseudonym. Suppressed when disabled or when consent is
    /// withheld for local testing, so an identity-bearing token is never emitted without consent.
    private func deviceRecurrenceReceipt(
        context: KenshikiSessionContext,
        now: Date
    ) -> DeviceRecurrenceReceipt? {
        guard configuration.enableDeviceRecurrence,
              configuration.consentPolicy != .disabledForLocalTesting else {
            return nil
        }
        return DeviceRecurrence.derive(
            tenantId: context.tenantId,
            rotationDays: configuration.deviceRecurrenceRotationDays,
            now: now
        )
    }

    private func sleepForCaptureWindow() async throws {
        let boundedDuration = min(max(configuration.captureDuration, 0.1), 5.0)
        try await Task.sleep(nanoseconds: UInt64(boundedDuration * 1_000_000_000))
    }

    private func batterySignal() -> BatterySignal {
        let support = SignalSupport(status: .available)
        let thermalState = thermalStateName(ProcessInfo.processInfo.thermalState)
        let lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled

        #if os(iOS) && canImport(UIKit)
        let device = UIDevice.current
        let previousMonitoringState = device.isBatteryMonitoringEnabled
        device.isBatteryMonitoringEnabled = true
        defer { device.isBatteryMonitoringEnabled = previousMonitoringState }

        let level = device.batteryLevel >= 0 ? Double(device.batteryLevel) : nil
        return BatterySignal(
            support: support,
            level: level,
            state: batteryStateName(device.batteryState),
            thermalState: thermalState,
            lowPowerModeEnabled: lowPowerMode
        )
        #else
        return BatterySignal(
            support: support,
            thermalState: thermalState,
            lowPowerModeEnabled: lowPowerMode
        )
        #endif
    }

    /// Collects motion and magnetometer from a SINGLE device-motion capture window.
    /// Device-motion already exposes a calibrated magnetic field, so this avoids spinning up
    /// two `CMMotionManager`s and waiting the capture window twice (which doubled collection
    /// latency on the check-in path).
    private func motionAndMagnetometerSignals() async throws -> (MotionSignal, MagnetometerSignal) {
        #if os(iOS) && canImport(CoreMotion)
        let authorization = CMMotionActivityManager.authorizationStatus()
        guard authorization == .authorized else {
            let reason: String
            switch authorization {
            case .notDetermined:
                reason = "Motion & Fitness permission has not been requested."
            case .denied, .restricted:
                reason = "Motion & Fitness permission is not available."
            case .authorized:
                reason = "Motion & Fitness permission is available."
            @unknown default:
                reason = "Motion & Fitness permission status is unknown."
            }
            return (
                MotionSignal(support: SignalSupport(status: .notCollected, reason: reason)),
                MagnetometerSignal(support: SignalSupport(status: .notCollected, reason: reason))
            )
        }

        let manager = CMMotionManager()
        guard manager.isDeviceMotionAvailable else {
            let motion = MotionSignal(support: SignalSupport(status: .unavailable, reason: "Device motion is unavailable."))
            return (motion, try await rawMagnetometerSignal(using: manager))
        }

        manager.deviceMotionUpdateInterval = min(max(configuration.captureDuration, 0.1), 1.0)
        // Prefer a magnetic reference frame so the device-motion magnetic field is calibrated.
        let frames = CMMotionManager.availableAttitudeReferenceFrames()
        if frames.contains(.xMagneticNorthZVertical) {
            manager.startDeviceMotionUpdates(using: .xMagneticNorthZVertical)
        } else {
            manager.startDeviceMotionUpdates()
        }
        defer { manager.stopDeviceMotionUpdates() }

        try await sleepForCaptureWindow()   // one window for both signals

        guard let motion = manager.deviceMotion else {
            let reason = "No device motion sample was produced."
            return (MotionSignal(support: SignalSupport(status: .notCollected, reason: reason)),
                    MagnetometerSignal(support: SignalSupport(status: .notCollected, reason: reason)))
        }

        let motionSignal = MotionSignal(
            support: SignalSupport(status: .available),
            sampleCount: 1,
            userAccelerationMagnitude: magnitude(x: motion.userAcceleration.x, y: motion.userAcceleration.y, z: motion.userAcceleration.z),
            rotationRateMagnitude: magnitude(x: motion.rotationRate.x, y: motion.rotationRate.y, z: motion.rotationRate.z),
            gravityMagnitude: magnitude(x: motion.gravity.x, y: motion.gravity.y, z: motion.gravity.z)
        )

        let field = motion.magneticField.field
        let fieldMagnitude = magnitude(x: field.x, y: field.y, z: field.z)
        let accuracy = magneticAccuracyName(motion.magneticField.accuracy)
        let magnetometerSupport: SignalSupport
        let magnetometerSampleCount: Int
        if motion.magneticField.accuracy == .uncalibrated || !fieldMagnitude.isFinite || fieldMagnitude <= 0 {
            magnetometerSupport = SignalSupport(status: .notCollected, reason: "No calibrated magnetometer sample was produced.")
            magnetometerSampleCount = 0
        } else {
            magnetometerSupport = SignalSupport(status: .available)
            magnetometerSampleCount = 1
        }
        let magnetometerSignal = MagnetometerSignal(
            support: magnetometerSupport,
            sampleCount: magnetometerSampleCount,
            fieldMagnitudeMicrotesla: magnetometerSampleCount > 0 ? fieldMagnitude : nil,
            calibrationAccuracy: accuracy
        )

        return (motionSignal, magnetometerSignal)
        #else
        let reason = "iOS CoreMotion APIs are not available on this platform."
        return (MotionSignal(support: SignalSupport(status: .notSupportedByPlatform, reason: reason)),
                MagnetometerSignal(support: SignalSupport(status: .notSupportedByPlatform, reason: reason)))
        #endif
    }

    #if os(iOS) && canImport(CoreMotion)
    /// Fallback for the rare case where device-motion is unavailable: a single raw magnetometer window.
    private func rawMagnetometerSignal(using manager: CMMotionManager) async throws -> MagnetometerSignal {
        guard manager.isMagnetometerAvailable else {
            return MagnetometerSignal(support: SignalSupport(status: .unavailable, reason: "Magnetometer is unavailable."))
        }
        manager.magnetometerUpdateInterval = min(max(configuration.captureDuration, 0.1), 1.0)
        manager.startMagnetometerUpdates()
        defer { manager.stopMagnetometerUpdates() }
        try await sleepForCaptureWindow()
        guard let data = manager.magnetometerData else {
            return MagnetometerSignal(support: SignalSupport(status: .notCollected, reason: "No magnetometer sample was produced."))
        }
        return MagnetometerSignal(
            support: SignalSupport(status: .available),
            sampleCount: 1,
            fieldMagnitudeMicrotesla: magnitude(x: data.magneticField.x, y: data.magneticField.y, z: data.magneticField.z),
            calibrationAccuracy: "raw"
        )
    }
    #endif

    private func barometerSignal() async -> BarometerSignal {
        guard configuration.includeBarometerAvailability else {
            return BarometerSignal(
                support: SignalSupport(status: .disabledByConfiguration, reason: "Barometer availability collection is disabled.")
            )
        }

        #if os(iOS) && canImport(CoreMotion)
        let authorization = CMMotionActivityManager.authorizationStatus()
        guard authorization == .authorized else {
            let reason: String
            switch authorization {
            case .notDetermined:
                reason = "Motion & Fitness permission has not been requested."
            case .denied, .restricted:
                reason = "Motion & Fitness permission is not available."
            case .authorized:
                reason = "Motion & Fitness permission is available."
            @unknown default:
                reason = "Motion & Fitness permission status is unknown."
            }
            return BarometerSignal(support: SignalSupport(status: .notCollected, reason: reason))
        }

        guard CMAltimeter.isRelativeAltitudeAvailable() else {
            return BarometerSignal(support: SignalSupport(status: .unavailable, reason: "Relative altitude is unavailable on this device."))
        }

        let altimeter = CMAltimeter()
        let window = min(max(configuration.captureDuration, 0.1), 5.0) + 0.2
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        return await withCheckedContinuation { continuation in
            let capture = BarometerCapture(altimeter: altimeter, continuation: continuation)
            altimeter.startRelativeAltitudeUpdates(to: queue) { data, error in
                if let data {
                    capture.finish(BarometerSignal(
                        support: SignalSupport(status: .available),
                        relativeAltitudeMeters: data.relativeAltitude.doubleValue,
                        pressureKilopascals: data.pressure.doubleValue
                    ))
                } else if let error {
                    capture.finish(BarometerSignal(
                        support: SignalSupport(status: .notCollected, reason: error.localizedDescription)
                    ))
                }
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + window) {
                capture.finish(BarometerSignal(
                    support: SignalSupport(status: .notCollected, reason: "No barometer sample was produced.")
                ))
            }
        }
        #else
        return BarometerSignal(
            support: SignalSupport(status: .notSupportedByPlatform, reason: "iOS CoreMotion APIs are not available on this platform.")
        )
        #endif
    }

    private func ambientLightSignal() async -> AmbientLightSignal {
        #if os(iOS) && canImport(UIKit)
        return await MainActor.run {
            let brightness = Double(UIScreen.main.brightness)
            let band = Self.brightnessBand(brightness)
            let bandSnapshot = SignalChangeTracker.observe(
                keyPrefix: "kenshiki.light.brightness.band.v1",
                value: band
            )
            return AmbientLightSignal(
                support: SignalSupport(
                    status: .available,
                    reason: "Screen brightness is a bounded proxy, not a raw ambient-light lux sensor."
                ),
                screenBrightnessLevel: brightness,
                proxySource: "UIScreen.main.brightness",
                brightnessBand: bandSnapshot.value,
                brightnessBandChangeCount: bandSnapshot.changeCount
            )
        }
        #else
        return AmbientLightSignal(
            support: SignalSupport(
                status: .notSupportedByPlatform,
                reason: "iOS does not expose a public ambient-light sensor API; host apps may add bounded context separately."
            )
        )
        #endif
    }

    private func mediaOutputSignal() -> MediaOutputSignal {
        #if os(iOS) && canImport(AVFoundation)
        let session = AVAudioSession.sharedInstance()
        let outputs = session.currentRoute.outputs
        let routeClass = Self.audioRouteClass(outputs)
        let otherAudioPlaying = session.isOtherAudioPlaying
        let hasOutputRoute = routeClass != "none"
        let external = outputs.contains { Self.isExternalAudio($0.portType) }
        let routeSnapshot = SignalChangeTracker.observe(
            keyPrefix: "kenshiki.media.route.class.v1",
            value: routeClass
        )
        let externalSnapshot = SignalChangeTracker.observe(
            keyPrefix: "kenshiki.media.external.route.v1",
            value: external ? "external" : "on_device"
        )
        let support = hasOutputRoute || otherAudioPlaying
            ? SignalSupport(status: .available)
            : SignalSupport(status: .notCollected, reason: "No audio output route class was exposed.")

        return MediaOutputSignal(
            support: support,
            routeClass: routeClass,
            external: external,
            otherAudioPlaying: otherAudioPlaying,
            routeChangeCount: routeSnapshot.changeCount,
            externalRouteChangeCount: externalSnapshot.changeCount
        )
        #else
        return MediaOutputSignal(
            support: SignalSupport(status: .notSupportedByPlatform, reason: "AVAudioSession is not available on this platform.")
        )
        #endif
    }

    private func displayProjectionSignal() async -> DisplayProjectionSignal {
        #if os(iOS) && canImport(UIKit)
        return await MainActor.run {
            let screenCaptured = UIScreen.main.isCaptured
            let externalDisplayCount = max(0, UIScreen.screens.count - 1)
            let projectionStatus = screenCaptured
                ? "mirrored_or_recorded"
                : (externalDisplayCount > 0 ? "external_display" : "on_device")
            let projectionSnapshot = SignalChangeTracker.observe(
                keyPrefix: "kenshiki.projection.status.v1",
                value: projectionStatus
            )
            let captureSnapshot = SignalChangeTracker.observe(
                keyPrefix: "kenshiki.projection.capture.v1",
                value: screenCaptured ? "captured" : "clear"
            )

            return DisplayProjectionSignal(
                support: SignalSupport(status: .available),
                screenCaptured: screenCaptured,
                externalDisplayCount: externalDisplayCount,
                projectionStatus: projectionStatus,
                projectionChangeCount: projectionSnapshot.changeCount,
                captureChangeCount: captureSnapshot.changeCount
            )
        }
        #else
        return DisplayProjectionSignal(
            support: SignalSupport(status: .notSupportedByPlatform,
                                   reason: "UIKit screen projection APIs are not available on this platform.")
        )
        #endif
    }

    private func bluetoothSignal() async -> BluetoothSignal {
        #if os(iOS) && canImport(CoreBluetooth) && canImport(AVFoundation)
        let authorization = Self.bluetoothAuthorizationName(CBCentralManager.authorization)
        let radioState = CBCentralManager.authorization == .allowedAlways
            ? await BluetoothStateProbe.snapshot()
            : "not_authorized"
        let session = AVAudioSession.sharedInstance()
        let routeClass = Self.bluetoothAudioRouteClass(session.currentRoute.outputs)
        let routeSnapshot = BluetoothRouteTracker.observe(routeClass: routeClass)
        let routeConnected = routeClass != "none"
        let scanAvailable = authorization == "allowed" && radioState == "powered_on"
        let support: SignalSupport = radioState == "unsupported"
            ? SignalSupport(status: .unavailable, reason: "Bluetooth is not supported on this device.")
            : SignalSupport(status: .available)

        return BluetoothSignal(
            support: support,
            authorization: authorization,
            radioState: radioState,
            scanAvailable: scanAvailable,
            audioRouteClass: routeClass,
            audioRouteConnected: routeConnected,
            audioRouteChangeCount: routeSnapshot.changeCount
        )
        #else
        return BluetoothSignal(
            support: SignalSupport(status: .notSupportedByPlatform,
                                   reason: "CoreBluetooth is not available on this platform.")
        )
        #endif
    }

    private func deviceSurfaceSignal() -> DeviceSurfaceSignal {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let bundleIdentifier = Bundle.main.bundleIdentifier

        #if targetEnvironment(simulator)
        let simulator = true
        #else
        let simulator = false
        #endif

        #if os(iOS) && canImport(UIKit)
        return DeviceSurfaceSignal(
            support: SignalSupport(status: .available),
            platform: "iOS",
            systemName: UIDevice.current.systemName,
            systemMajorVersion: version.majorVersion,
            interfaceIdiom: interfaceIdiomName(UIDevice.current.userInterfaceIdiom),
            bundleIdentifier: bundleIdentifier,
            simulator: simulator
        )
        #else
        return DeviceSurfaceSignal(
            support: SignalSupport(status: .available),
            platform: "Darwin",
            systemName: ProcessInfo.processInfo.operatingSystemVersionString,
            systemMajorVersion: version.majorVersion,
            bundleIdentifier: bundleIdentifier,
            simulator: simulator
        )
        #endif
    }
}

// Connectivity, telephony, and value-formatting helpers — split out to keep the collector's
// primary type body focused on signal capture.
extension DefaultDevicePhysicsCollector {
    private func connectivitySignal() async -> ConnectivitySignal {
        #if canImport(Network)
        let monitor = NWPathMonitor()
        monitor.start(queue: DispatchQueue(label: "kenshiki.connectivity.snapshot"))
        async let perInterfaceStatuses = Self.requiredInterfacePathStatuses()
        try? await Task.sleep(nanoseconds: 250_000_000)
        let path = monitor.currentPath
        var signal = await Self.connectivitySignal(from: path, perInterfacePathStatuses: perInterfaceStatuses)
        monitor.cancel()
        // Privacy-preserving Wi-Fi continuity token — only meaningful when actually on Wi-Fi. The token
        // also feeds the device-only known-network memory, which classifies how familiar this network is
        // (new / known / familiar). Only the coarse band is exported; the raw token never leaves.
        if path.usesInterfaceType(.wifi) {
            let hash = await WifiNetworkIdentity.currentHash()
            signal.wifiNetworkHash = hash
            signal.wifiFamiliarity = KnownNetworkStore.shared.observe(token: hash).rawValue
        } else {
            signal.wifiFamiliarity = NetworkFamiliarity.unknown.rawValue
        }
        return signal
        #else
        return ConnectivitySignal(
            support: SignalSupport(status: .notSupportedByPlatform, reason: "Network.framework is not available on this platform.")
        )
        #endif
    }

    #if canImport(Network)
    private static func connectivitySignal(
        from path: NWPath,
        perInterfacePathStatuses: [String: String] = [:]
    ) -> ConnectivitySignal {
        let interfaces = Self.connectivityInterfaceTypes(from: path)
        let support = path.status == .requiresConnection && interfaces.isEmpty
            ? SignalSupport(status: .notCollected, reason: "Network path requires a connection and exposed no active interface.")
            : SignalSupport(status: .available)
        return ConnectivitySignal(
            support: support,
            pathStatus: Self.connectivityStatusName(path.status),
            unsatisfiedReason: Self.connectivityUnsatisfiedReasonName(path.unsatisfiedReason),
            interfaceTypes: interfaces,
            availableInterfaceTypes: Self.availableConnectivityInterfaceTypes(from: path),
            perInterfacePathStatuses: perInterfacePathStatuses,
            expensive: path.isExpensive,
            constrained: path.isConstrained,
            supportsDNS: path.supportsDNS,
            supportsIPv4: path.supportsIPv4,
            supportsIPv6: path.supportsIPv6,
            gatewayCount: path.gateways.count,
            availableInterfaceCount: path.availableInterfaces.count
        )
    }

    private static func requiredInterfacePathStatuses() async -> [String: String] {
        let types: [NWInterface.InterfaceType] = [.wifi, .cellular, .wiredEthernet, .loopback, .other]
        let monitors = types.map { type in
            (type: type, monitor: NWPathMonitor(requiredInterfaceType: type))
        }
        let queue = DispatchQueue(label: "kenshiki.connectivity.per-interface.snapshot")
        monitors.forEach { $0.monitor.start(queue: queue) }
        try? await Task.sleep(nanoseconds: 250_000_000)
        let statuses = Dictionary(uniqueKeysWithValues: monitors.map { item in
            (Self.connectivityInterfaceName(item.type), Self.connectivityStatusName(item.monitor.currentPath.status))
        })
        monitors.forEach { $0.monitor.cancel() }
        return statuses
    }

    private static func connectivityInterfaceTypes(from path: NWPath) -> [String] {
        [NWInterface.InterfaceType.wifi, .cellular, .wiredEthernet, .loopback, .other]
            .filter { path.usesInterfaceType($0) }
            .map(Self.connectivityInterfaceName)
    }

    private static func availableConnectivityInterfaceTypes(from path: NWPath) -> [String] {
        let available = Set(path.availableInterfaces.map(\.type))
        return [NWInterface.InterfaceType.wifi, .cellular, .wiredEthernet, .loopback, .other]
            .filter { available.contains($0) }
            .map(Self.connectivityInterfaceName)
    }

    private static func connectivityStatusName(_ status: NWPath.Status) -> String {
        switch status {
        case .satisfied: return "satisfied"
        case .unsatisfied: return "unsatisfied"
        case .requiresConnection: return "requires_connection"
        @unknown default: return "unknown"
        }
    }

    private static func connectivityUnsatisfiedReasonName(_ reason: NWPath.UnsatisfiedReason) -> String? {
        switch reason {
        case .notAvailable:
            return "not_available"
        case .cellularDenied:
            return "cellular_denied"
        case .wifiDenied:
            return "wifi_denied"
        case .localNetworkDenied:
            return "local_network_denied"
        case .vpnInactive:
            return "vpn_inactive"
        @unknown default:
            return "unknown"
        }
    }

    private static func connectivityInterfaceName(_ type: NWInterface.InterfaceType) -> String {
        switch type {
        case .wifi: return "wifi"
        case .cellular: return "cellular"
        case .wiredEthernet: return "wired"
        case .loopback: return "loopback"
        case .other: return "other"
        @unknown default: return "unknown"
        }
    }
    #endif

    // MARK: - Telephony / radio (CoreTelephony)

    /// Coarse radio snapshot. iOS exposes no cell-tower, signal-strength, baseband,
    /// IMEI, carrier identity, or ICCID to third-party apps, so we capture only:
    /// radio-access generation, carrier-descriptor SIM presence, and cellular-data state.
    private func telephonySignal() -> TelephonySignal {
        #if os(iOS) && canImport(CoreTelephony)
        let networkInfo = CTTelephonyNetworkInfo()

        var generations: Set<String> = []
        let serviceCount: Int?
        if let ratByService = networkInfo.serviceCurrentRadioAccessTechnology {
            serviceCount = ratByService.count
            for raw in ratByService.values {
                generations.insert(RadioAccessGeneration.label(for: raw))
            }
        } else {
            serviceCount = nil
        }

        var simInserted: Bool?
        if #available(iOS 18.0, *) {
            // isSIMInserted is scoped to SIMs matching the app's Info.plist carrier
            // descriptors (MCC/MNC/GIDs); for a non-carrier app it is of limited value.
            let subscribers = CTSubscriberInfo.subscribers()
            if !subscribers.isEmpty {
                simInserted = subscribers.contains { $0.isSIMInserted }
            }
        }

        let restricted = Self.cellularDataStateName(CTCellularData().restrictedState)
        let dataService = TelephonyDataServiceTracker.observe(identifier: networkInfo.dataServiceIdentifier)
        let callSnapshot = CallActivityRecorder.snapshot()
        let hasCellularState = restricted != "unknown"
        let hasCallCoverage = callSnapshot.observerStartedAt != nil ||
            callSnapshot.eventCount > 0 ||
            callSnapshot.activeCallCount != nil ||
            callSnapshot.connectedCallCount != nil ||
            callSnapshot.heldCallCount != nil
        let hasTelephonySample = !generations.isEmpty || simInserted != nil || hasCellularState || hasCallCoverage
        let radioVisibility = Self.radioVisibilityName(
            hasRadioGeneration: !generations.isEmpty,
            serviceCount: serviceCount,
            hasCellularState: hasCellularState,
            hasCallCoverage: hasCallCoverage
        )
        let support = hasTelephonySample
            ? SignalSupport(status: .available)
            : SignalSupport(status: .notCollected, reason: "iOS exposed no radio, SIM, cellular-data, or call-observer sample.")

        return TelephonySignal(
            support: support,
            simInserted: simInserted,
            radioGenerations: generations.sorted(),
            serviceCount: serviceCount,
            radioVisibility: radioVisibility,
            cellularDataRestricted: restricted,
            dataServiceAvailable: dataService.available,
            dataServiceChangeCount: dataService.changeCount,
            callEventCount: callSnapshot.eventCount,
            lastCallEventAt: callSnapshot.lastEventAt,
            activeCallCount: callSnapshot.activeCallCount,
            connectedCallCount: callSnapshot.connectedCallCount,
            heldCallCount: callSnapshot.heldCallCount,
            callObserverStartedAt: callSnapshot.observerStartedAt,
            callObserverCoverageSeconds: Self.callObserverCoverageSeconds(
                startedAt: callSnapshot.observerStartedAt,
                now: Date()
            )
        )
        #else
        return TelephonySignal(
            support: SignalSupport(status: .notSupportedByPlatform, reason: "CoreTelephony is not available on this platform.")
        )
        #endif
    }

    #if os(iOS) && canImport(CoreTelephony)
    private static func cellularDataStateName(_ state: CTCellularDataRestrictedState) -> String {
        switch state {
        case .restricted:
            return "restricted"
        case .notRestricted:
            return "not_restricted"
        case .restrictedStateUnknown:
            return "unknown"
        @unknown default:
            return "unknown"
        }
    }

    private static func radioVisibilityName(
        hasRadioGeneration: Bool,
        serviceCount: Int?,
        hasCellularState: Bool,
        hasCallCoverage: Bool
    ) -> String {
        if hasRadioGeneration {
            return "visible"
        }
        if (serviceCount ?? 0) > 0 || hasCellularState || hasCallCoverage {
            return "hidden_by_ios"
        }
        return "not_observed"
    }

    private static func callObserverCoverageSeconds(startedAt: Date?, now: Date) -> Int? {
        guard let startedAt else { return nil }
        return max(0, Int(now.timeIntervalSince(startedAt)))
    }
    #endif

    #if os(iOS) && canImport(CoreMotion)
    private func magneticAccuracyName(_ accuracy: CMMagneticFieldCalibrationAccuracy) -> String {
        switch accuracy {
        case .uncalibrated:
            return "uncalibrated"
        case .low:
            return "low"
        case .medium:
            return "medium"
        case .high:
            return "high"
        @unknown default:
            return "unknown"
        }
    }
    #endif

    private func magnitude(x: Double, y: Double, z: Double) -> Double {
        (x * x + y * y + z * z).squareRoot()
    }

    private func thermalStateName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal:
            return "nominal"
        case .fair:
            return "fair"
        case .serious:
            return "serious"
        case .critical:
            return "critical"
        @unknown default:
            return "unknown"
        }
    }

    #if os(iOS) && canImport(AVFoundation)
    private static func audioRouteClass(_ outputs: [AVAudioSessionPortDescription]) -> String {
        guard let first = outputs.first else { return "none" }
        return audioPortClass(first.portType)
    }

    private static func audioPortClass(_ type: AVAudioSession.Port) -> String {
        switch type {
        case .bluetoothA2DP, .bluetoothLE, .bluetoothHFP:
            return "bluetooth"
        case .airPlay:
            return "airplay"
        case .carAudio:
            return "car"
        case .headphones, .headsetMic:
            return "wired"
        case .builtInSpeaker:
            return "speaker"
        case .builtInReceiver:
            return "receiver"
        case .HDMI, .displayPort:
            return "display"
        case .usbAudio:
            return "usb"
        default:
            return "other"
        }
    }

    private static func isExternalAudio(_ type: AVAudioSession.Port) -> Bool {
        switch type {
        case .bluetoothA2DP, .bluetoothLE, .bluetoothHFP, .airPlay, .carAudio,
             .headphones, .HDMI, .displayPort, .usbAudio:
            return true
        default:
            return false
        }
    }

    private static func bluetoothAudioRouteClass(_ outputs: [AVAudioSessionPortDescription]) -> String {
        let classes = outputs.map { audioPortClass($0.portType) }
        if classes.contains("car") { return "car" }
        if classes.contains("bluetooth") { return "bluetooth" }
        return "none"
    }

    private static func brightnessBand(_ brightness: Double) -> String {
        switch brightness {
        case ..<0.18: return "dim"
        case ..<0.45: return "low"
        case ..<0.72: return "medium"
        default: return "bright"
        }
    }
    #endif

    #if os(iOS) && canImport(CoreBluetooth)
    private static func bluetoothAuthorizationName(_ authorization: CBManagerAuthorization) -> String {
        switch authorization {
        case .allowedAlways:
            return "allowed"
        case .denied:
            return "denied"
        case .restricted:
            return "restricted"
        case .notDetermined:
            return "not_determined"
        @unknown default:
            return "unknown"
        }
    }

    private static func bluetoothStateName(_ state: CBManagerState) -> String {
        switch state {
        case .poweredOn:
            return "powered_on"
        case .poweredOff:
            return "powered_off"
        case .unauthorized:
            return "unauthorized"
        case .unsupported:
            return "unsupported"
        case .resetting:
            return "resetting"
        case .unknown:
            return "unknown"
        @unknown default:
            return "unknown"
        }
    }

    private final class BluetoothStateProbe: NSObject, @preconcurrency CBCentralManagerDelegate {
        private var manager: CBCentralManager?
        private var continuation: CheckedContinuation<String, Never>?

        static func snapshot() async -> String {
            let probe = BluetoothStateProbe()
            return await probe.snapshot()
        }

        private func snapshot() async -> String {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                self.manager = CBCentralManager(
                    delegate: self,
                    queue: nil,
                    options: [CBCentralManagerOptionShowPowerAlertKey: false]
                )
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    self.finishIfNeeded()
                }
            }
        }

        @MainActor
        func centralManagerDidUpdateState(_ central: CBCentralManager) {
            finishIfNeeded(state: central.state)
        }

        @MainActor
        private func finishIfNeeded(state: CBManagerState? = nil) {
            guard let continuation else { return }
            let resolved = state ?? manager?.state ?? .unknown
            self.continuation = nil
            manager?.delegate = nil
            manager = nil
            continuation.resume(returning: DefaultDevicePhysicsCollector.bluetoothStateName(resolved))
        }
    }
    #endif

    #if os(iOS) && canImport(UIKit)
    private func batteryStateName(_ state: UIDevice.BatteryState) -> String {
        switch state {
        case .unknown:
            return "unknown"
        case .unplugged:
            return "unplugged"
        case .charging:
            return "charging"
        case .full:
            return "full"
        @unknown default:
            return "unknown"
        }
    }

    private func interfaceIdiomName(_ idiom: UIUserInterfaceIdiom) -> String {
        switch idiom {
        case .unspecified:
            return "unspecified"
        case .phone:
            return "phone"
        case .pad:
            return "pad"
        case .tv:
            return "tv"
        case .carPlay:
            return "car_play"
        case .mac:
            return "mac"
        case .vision:
            return "vision"
        @unknown default:
            return "unknown"
        }
    }
    #endif
}

#if os(iOS) && canImport(CoreMotion)
private final class BarometerCapture: @unchecked Sendable {
    private let altimeter: CMAltimeter
    private let continuation: CheckedContinuation<BarometerSignal, Never>
    private let lock = NSLock()
    private var finished = false

    init(altimeter: CMAltimeter, continuation: CheckedContinuation<BarometerSignal, Never>) {
        self.altimeter = altimeter
        self.continuation = continuation
    }

    func finish(_ signal: BarometerSignal) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        lock.unlock()
        altimeter.stopRelativeAltitudeUpdates()
        continuation.resume(returning: signal)
    }
}
#endif
