import Foundation

/// Pure continuity-trace view model built from bounded `TelemetryEvent` rows.
///
/// This belongs in the SDK because it is product logic, not sample UI: it groups signed and live
/// lanes by check-in session without depending on SwiftUI, app copy, or platform services.
public struct ContinuityTraceModel: Equatable, Sendable {
    public enum LaneGroup: String, Equatable, Sendable {
        case signed = "Signed core"
        case live = "Live detail"
    }

    public enum SignalStatus: Equatable, Sendable {
        case live
        case notLive
        case unobserved

        public var label: String {
            switch self {
            case .live: return "Live"
            case .notLive: return "Not live"
            case .unobserved: return "Unobserved"
            }
        }
    }

    public struct Lane: Equatable, Identifiable, Sendable {
        public let id: String
        public let title: String
        public let group: LaneGroup
        public let explanation: String
        public let privacyNote: String

        public init(id: String, title: String, group: LaneGroup, explanation: String, privacyNote: String) {
            self.id = id
            self.title = title
            self.group = group
            self.explanation = explanation
            self.privacyNote = privacyNote
        }
    }

    public struct SignalMark: Equatable, Identifiable, Sendable {
        public let laneId: String
        public let status: SignalStatus
        public let source: String
        public let title: String

        public var id: String { laneId }

        public init(laneId: String, status: SignalStatus, source: String, title: String) {
            self.laneId = laneId
            self.status = status
            self.source = source
            self.title = title
        }
    }

    public struct Session: Equatable, Identifiable, Sendable {
        public let id: String
        public let occurredAt: Date
        public let merkleRoot: String?
        public let signals: [String: SignalMark]
        public let checkIn: TelemetryEvent?
        public let breaks: [TelemetryEvent]
        public let stateTransitions: [TelemetryEvent]

        public var merkleRootPrefix: String? {
            guard let merkleRoot, !merkleRoot.isEmpty else { return nil }
            return String(merkleRoot.prefix(12))
        }

        public var liveSignalCount: Int {
            signals.values.filter { $0.status == .live }.count
        }

        public var observedSignalCount: Int {
            signals.values.filter { $0.status != .unobserved }.count
        }

        public init(
            id: String,
            occurredAt: Date,
            merkleRoot: String?,
            signals: [String: SignalMark],
            checkIn: TelemetryEvent?,
            breaks: [TelemetryEvent],
            stateTransitions: [TelemetryEvent]
        ) {
            self.id = id
            self.occurredAt = occurredAt
            self.merkleRoot = merkleRoot
            self.signals = signals
            self.checkIn = checkIn
            self.breaks = breaks
            self.stateTransitions = stateTransitions
        }
    }

    public static let privacyBoundary = KenshikiPulseConstants.privacyBoundary

    public static let lanes: [Lane] = [
        Lane(id: "battery", title: "Battery / thermal", group: .signed,
             explanation: "Checks battery and temperature detail without exposing private data.",
             privacyNote: "No serial numbers or charging history are shown."),
        Lane(id: "motion", title: "Motion", group: .signed,
             explanation: "Shows whether movement detail was available for this check.",
             privacyNote: "No detailed accelerometer, gyroscope, or movement path is stored."),
        Lane(id: "magnetic", title: "Magnetic field", group: .signed,
             explanation: "Shows nearby surroundings around the phone.",
             privacyNote: "No detailed magnetic readings or environmental fingerprints are shown."),
        Lane(id: "pressure", title: "Pressure", group: .signed,
             explanation: "Shows whether air-pressure detail was available.",
             privacyNote: "No pressure stream or altitude trail is stored."),
        Lane(id: "light", title: "Light proxy", group: .signed,
             explanation: "Shows whether local light detail was available.",
             privacyNote: "No camera, image, or screen-content data is used."),
        Lane(id: "service", title: "Phone service", group: .signed,
             explanation: "Shows whether phone service details were visible.",
             privacyNote: "No phone numbers, contacts, carrier identifiers, or call content are stored."),
        Lane(id: "connectivity", title: "Connectivity", group: .signed,
             explanation: "Shows whether connection detail was visible.",
             privacyNote: "No Wi-Fi names, router IDs, internet addresses, network lookup servers, or network identifiers are stored."),
        Lane(id: "bluetooth", title: "Bluetooth radio", group: .signed,
             explanation: "Shows Bluetooth state and broad accessory-route detail.",
             privacyNote: "No accessory names, UUIDs, MAC addresses, advertisements, or nearby-device scans are stored."),
        Lane(id: "media", title: "Media output", group: .signed,
             explanation: "Shows broad audio-route detail.",
             privacyNote: "No media title, audio content, or app name is stored."),
        Lane(id: "projection", title: "Projection", group: .signed,
             explanation: "Shows whether screen sharing or projection was visible.",
             privacyNote: "No screen contents, screenshots, or app names are stored."),
        Lane(id: "surface", title: "Device surface", group: .signed,
             explanation: "Checks broad platform detail.",
             privacyNote: "No stable hardware identifier is shown."),
        Lane(id: "place", title: "Place detail", group: .live,
             explanation: "Shows broad place-detail availability during foreground checks.",
             privacyNote: "No coordinates, addresses, place names, or location trail are stored."),
        Lane(id: "diurnal", title: "Daily light", group: .live,
             explanation: "A live-only signal for the coarse local day/night window.",
             privacyNote: "No precise location or timestamp trail is exposed beyond the check-in time."),
        Lane(id: "focus", title: "Focus / quiet", group: .live,
             explanation: "Shows whether quiet or Focus detail was visible.",
             privacyNote: "No notification contents, app usage, or message data is stored."),
    ]

    public let lanes: [Lane]
    public let sessions: [Session]
    public let ungroupedEvents: [TelemetryEvent]

    public var isEmpty: Bool { sessions.isEmpty && ungroupedEvents.isEmpty }

    public init(lanes: [Lane], sessions: [Session], ungroupedEvents: [TelemetryEvent]) {
        self.lanes = lanes
        self.sessions = sessions
        self.ungroupedEvents = ungroupedEvents
    }

    public static func make(events: [TelemetryEvent]) -> ContinuityTraceModel {
        let laneIds = Set(lanes.map(\.id))
        let traceEvents = events.filter { event in
            switch event.category {
            case .lifeSignal, .checkIn, .breakEvent, .stateTransition:
                return true
            case .continuityLog:
                return false
            }
        }

        var grouped: [String: [TelemetryEvent]] = [:]
        var ungrouped: [TelemetryEvent] = []
        for event in traceEvents {
            if let sessionId = event.sessionId, !sessionId.isEmpty {
                grouped[sessionId, default: []].append(event)
            } else {
                ungrouped.append(event)
            }
        }

        let sessions = grouped.map { sessionId, events in
            makeSession(sessionId: sessionId, events: events, laneIds: laneIds)
        }
        .sorted { lhs, rhs in
            if lhs.occurredAt == rhs.occurredAt { return lhs.id < rhs.id }
            return lhs.occurredAt < rhs.occurredAt
        }

        return ContinuityTraceModel(
            lanes: lanes,
            sessions: sessions,
            ungroupedEvents: ungrouped.sorted { lhs, rhs in
                if lhs.occurredAt == rhs.occurredAt { return lhs.id < rhs.id }
                return lhs.occurredAt < rhs.occurredAt
            }
        )
    }

    public func lane(id: String) -> Lane? {
        lanes.first { $0.id == id }
    }

    private static func makeSession(
        sessionId: String,
        events: [TelemetryEvent],
        laneIds: Set<String>
    ) -> Session {
        let orderedEvents = events.sorted { lhs, rhs in
            if lhs.occurredAt == rhs.occurredAt { return lhs.id < rhs.id }
            return lhs.occurredAt < rhs.occurredAt
        }
        let checkIn = orderedEvents.first { $0.category == .checkIn }
        let occurredAt = checkIn?.occurredAt ?? orderedEvents.first?.occurredAt ?? Date(timeIntervalSince1970: 0)
        let merkleRoot = checkIn?.merkleRoot ?? orderedEvents.first { $0.merkleRoot != nil }?.merkleRoot

        let signals = orderedEvents.reduce(into: [String: SignalMark]()) { result, event in
            guard event.category == .lifeSignal,
                  let signalId = event.signalId,
                  laneIds.contains(signalId)
            else { return }
            result[signalId] = SignalMark(
                laneId: signalId,
                status: signalStatus(from: event),
                source: event.metadata["source"] ?? "unknown",
                title: event.title
            )
        }

        return Session(
            id: sessionId,
            occurredAt: occurredAt,
            merkleRoot: merkleRoot,
            signals: signals,
            checkIn: checkIn,
            breaks: orderedEvents.filter { $0.category == .breakEvent },
            stateTransitions: orderedEvents.filter { $0.category == .stateTransition }
        )
    }

    private static func signalStatus(from event: TelemetryEvent) -> SignalStatus {
        if event.metadata["observed"] == "false" { return .unobserved }
        return event.isLive == true ? .live : .notLive
    }
}
