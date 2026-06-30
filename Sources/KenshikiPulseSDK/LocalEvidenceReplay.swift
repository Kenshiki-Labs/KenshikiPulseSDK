import Foundation

/// Deterministic replay adapter from the local evidence lake into the canonical continuity evidence
/// model. This is the bridge fusion should consume; check-in telemetry is only a derived artifact.
enum LocalEvidenceReplay {
    public static let sensorWriterExtractorVersion = "pulse.local_evidence_lake.sensor_writer.v1"

    public static func evidenceSnapshot(
        from snapshot: LocalEvidenceSnapshot,
        now: Date = Date(),
        freshnessWindow: TimeInterval = 10 * 60
    ) -> ContinuityEvidenceSnapshot {
        let latestByLane = Dictionary(grouping: snapshot.rows.compactMap { row -> (ContinuityEvidenceLane, LocalEvidenceWindow)? in
            guard let lane = lane(for: row) else { return nil }
            return (lane, row)
        }, by: { $0.0 }).compactMapValues { values in
            values.map(\.1).max {
                if $0.windowEndAt == $1.windowEndAt { return $0.id < $1.id }
                return $0.windowEndAt < $1.windowEndAt
            }
        }

        let points = latestByLane.keys.sorted { $0.rawValue < $1.rawValue }.compactMap { lane in
            latestByLane[lane].map { point(for: lane, window: $0, now: now, freshnessWindow: freshnessWindow) }
        }
        return ContinuityEvidenceSnapshot(points: points)
    }

    /// Fusion-grade replay uses only windows emitted directly at the sensor boundary. Compatibility
    /// rows derived from an already-synthesized check-in are migration/debug material, not substrate.
    public static func sensorEvidenceSnapshot(
        from snapshot: LocalEvidenceSnapshot,
        now: Date = Date(),
        freshnessWindow: TimeInterval = 10 * 60
    ) -> ContinuityEvidenceSnapshot {
        evidenceSnapshot(
            from: LocalEvidenceSnapshot(
                interval: snapshot.interval,
                rows: snapshot.rows.filter(isSensorWriterWindow)
            ),
            now: now,
            freshnessWindow: freshnessWindow
        )
    }

    public static func sensorWriterRowCount(in snapshot: LocalEvidenceSnapshot) -> Int {
        snapshot.rows.filter(isSensorWriterWindow).count
    }

    public static func isSensorWriterWindow(_ window: LocalEvidenceWindow) -> Bool {
        window.extractorVersion == sensorWriterExtractorVersion &&
            (window.collectionSurface == "sensor_monitor" ||
                window.collectionSurface == "signed_signal_snapshot_writer" ||
                window.collectionSurface == "headless_sensor_writer" ||
                window.collectionSurface == "sensor_history_writer" ||
                window.collectionSurface == "app_interaction_writer" ||
                window.collectionSurface == "trusted_ble_witness_scanner")
    }

    private static func point(
        for lane: ContinuityEvidenceLane,
        window: LocalEvidenceWindow,
        now: Date,
        freshnessWindow: TimeInterval
    ) -> ContinuityEvidencePoint {
        let baseState = state(from: window.quality)
        let state: ContinuityEvidenceState
        if baseState == .observed, now.timeIntervalSince(window.windowEndAt) > freshnessWindow {
            state = .stale
        } else {
            state = baseState
        }
        return ContinuityEvidencePoint(
            lane: lane,
            state: state,
            supportStatus: supportStatus(from: window),
            reason: reason(from: window, state: state)
        )
    }

    private static func state(from quality: LocalEvidenceQuality) -> ContinuityEvidenceState {
        switch quality {
        case .observed: return .observed
        case .empty: return .empty
        case .unavailable: return .unavailable
        case .stale: return .stale
        case .contradictory: return .contradictory
        }
    }

    private static func supportStatus(from window: LocalEvidenceWindow) -> SignalSupportStatus {
        switch window.supportState {
        case .available:
            return window.permissionState == .denied || window.permissionState == .restricted
                ? .unavailable
                : .available
        case .notCollected:
            return .notCollected
        case .disabledByConfiguration:
            return .disabledByConfiguration
        case .notSupportedByPlatform:
            return .notSupportedByPlatform
        case .unavailable:
            return .unavailable
        }
    }

    private static func reason(from window: LocalEvidenceWindow, state: ContinuityEvidenceState) -> String? {
        if state == .stale { return "lake_window_stale" }
        if let reason = window.payload["reason"] { return reason }
        switch window.permissionState {
        case .denied: return "permission_denied"
        case .restricted: return "permission_restricted"
        case .notDetermined: return "permission_not_determined"
        case .unavailable: return "permission_unavailable"
        case .authorized, .notRequired, .unknown: return nil
        }
    }

    private static func lane(for window: LocalEvidenceWindow) -> ContinuityEvidenceLane? {
        switch window.sensorId {
        case "battery":
            return .battery
        case "device_motion", "activity", "pedometer", "motion":
            return .motion
        case "magnetic", "magnetometer":
            return .magnetometer
        case "pressure", "barometer":
            return .barometer
        case "screen_brightness", "light", "diurnal":
            return .ambientLight
        case "telephony", "phone_service":
            return .telephony
        case "connectivity", "network_path":
            return .connectivity
        case "bluetooth":
            return .bluetooth
        case "trusted_ble_witness":
            return .trustedBLEWitness
        case "media_route", "media_output":
            return .mediaOutput
        case "display_projection":
            return .displayProjection
        case "device_surface":
            return .deviceSurface
        case "location", "place":
            return .place
        case "focus":
            return .focus
        case "interaction":
            return .interaction
        default:
            return laneFromKindOrGroup(window)
        }
    }

    private static func laneFromKindOrGroup(_ window: LocalEvidenceWindow) -> ContinuityEvidenceLane? {
        switch window.evidenceKind {
        case "power_state": return .battery
        case "motion_bucket", "activity_class", "pedometer_bucket": return .motion
        case "magnetic_bucket": return .magnetometer
        case "pressure_bucket": return .barometer
        case "brightness_bucket": return .ambientLight
        case "telephony_summary": return .telephony
        case "network_path": return .connectivity
        case "bluetooth_route": return .bluetooth
        case "trusted_ble_presence": return .trustedBLEWitness
        case "audio_route": return .mediaOutput
        case "display_projection": return .displayProjection
        case "location_context": return .place
        case "focus_state": return .focus
        default:
            switch window.laneGroup {
            case "movement": return .motion
            case "place": return .place
            case "network": return .connectivity
            case "device_environment": return .ambientLight
            case "power": return .battery
            case "attention_focus": return .focus
            default: return nil
            }
        }
    }
}
