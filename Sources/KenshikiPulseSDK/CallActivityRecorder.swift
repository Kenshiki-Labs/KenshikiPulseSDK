import Foundation

public struct CallActivitySnapshot: Codable, Equatable, Sendable {
    public var eventCount: Int
    public var lastEventAt: Date?
    public var activeCallCount: Int?
    public var connectedCallCount: Int?
    public var heldCallCount: Int?
    public var observerStartedAt: Date?

    public init(
        eventCount: Int,
        lastEventAt: Date?,
        activeCallCount: Int?,
        connectedCallCount: Int? = nil,
        heldCallCount: Int? = nil,
        observerStartedAt: Date?
    ) {
        self.eventCount = eventCount
        self.lastEventAt = lastEventAt
        self.activeCallCount = activeCallCount
        self.connectedCallCount = connectedCallCount
        self.heldCallCount = heldCallCount
        self.observerStartedAt = observerStartedAt
    }
}

/// Content-free call occurrence store. Host apps may feed this from CallKit; the SDK
/// then includes only aggregate occurrence/freshness in the evidence envelope.
public enum CallActivityRecorder {
    private enum Key {
        static let eventCount = "kenshiki.callActivity.eventCount"
        static let lastEventAt = "kenshiki.callActivity.lastEventAt"
        static let activeCallCount = "kenshiki.callActivity.activeCallCount"
        static let connectedCallCount = "kenshiki.callActivity.connectedCallCount"
        static let heldCallCount = "kenshiki.callActivity.heldCallCount"
        static let observerStartedAt = "kenshiki.callActivity.observerStartedAt"
    }

    public static func markObserverStarted(at date: Date = Date()) {
        UserDefaults.standard.set(date.timeIntervalSince1970, forKey: Key.observerStartedAt)
    }

    public static func recordOccurrence(
        at date: Date = Date(),
        activeCallCount: Int? = nil,
        connectedCallCount: Int? = nil,
        heldCallCount: Int? = nil
    ) {
        let nextCount = max(0, UserDefaults.standard.integer(forKey: Key.eventCount)) + 1
        UserDefaults.standard.set(nextCount, forKey: Key.eventCount)
        UserDefaults.standard.set(date.timeIntervalSince1970, forKey: Key.lastEventAt)
        if activeCallCount != nil || connectedCallCount != nil || heldCallCount != nil {
            setCallStateCounts(
                active: activeCallCount,
                connected: connectedCallCount,
                held: heldCallCount
            )
        }
    }

    public static func setActiveCallCount(_ count: Int) {
        setCallStateCounts(active: count, connected: nil, held: nil)
    }

    public static func setCallStateCounts(active: Int?, connected: Int?, held: Int?) {
        if let active {
            UserDefaults.standard.set(max(0, active), forKey: Key.activeCallCount)
        }
        if let connected {
            UserDefaults.standard.set(max(0, connected), forKey: Key.connectedCallCount)
        }
        if let held {
            UserDefaults.standard.set(max(0, held), forKey: Key.heldCallCount)
        }
    }

    public static func snapshot() -> CallActivitySnapshot {
        CallActivitySnapshot(
            eventCount: max(0, UserDefaults.standard.integer(forKey: Key.eventCount)),
            lastEventAt: date(forKey: Key.lastEventAt),
            activeCallCount: UserDefaults.standard.object(forKey: Key.activeCallCount) == nil
                ? nil
                : max(0, UserDefaults.standard.integer(forKey: Key.activeCallCount)),
            connectedCallCount: UserDefaults.standard.object(forKey: Key.connectedCallCount) == nil
                ? nil
                : max(0, UserDefaults.standard.integer(forKey: Key.connectedCallCount)),
            heldCallCount: UserDefaults.standard.object(forKey: Key.heldCallCount) == nil
                ? nil
                : max(0, UserDefaults.standard.integer(forKey: Key.heldCallCount)),
            observerStartedAt: date(forKey: Key.observerStartedAt)
        )
    }

    public static func clear() {
        [
            Key.eventCount,
            Key.lastEventAt,
            Key.activeCallCount,
            Key.connectedCallCount,
            Key.heldCallCount,
            Key.observerStartedAt,
        ].forEach {
            UserDefaults.standard.removeObject(forKey: $0)
        }
    }

    public static func resetForTesting() {
        clear()
    }

    private static func date(forKey key: String) -> Date? {
        let value = UserDefaults.standard.double(forKey: key)
        return value > 0 ? Date(timeIntervalSince1970: value) : nil
    }
}
