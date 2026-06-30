import Foundation

public struct BluetoothRouteSnapshot: Equatable, Sendable {
    public let routeClass: String
    public let changeCount: Int

    public init(routeClass: String, changeCount: Int) {
        self.routeClass = routeClass
        self.changeCount = changeCount
    }
}

public enum BluetoothRouteTracker {
    private static let routeKey = "kenshiki.bluetooth.route.class.v1"
    private static let countKey = "kenshiki.bluetooth.route.change.count.v1"

    public static func observe(
        routeClass rawRouteClass: String?,
        defaults: UserDefaults = .standard
    ) -> BluetoothRouteSnapshot {
        let routeClass = normalize(rawRouteClass)
        let previous = defaults.string(forKey: routeKey)
        var count = defaults.integer(forKey: countKey)

        if let previous, previous != routeClass {
            count += 1
            defaults.set(count, forKey: countKey)
        }
        defaults.set(routeClass, forKey: routeKey)

        return BluetoothRouteSnapshot(routeClass: routeClass, changeCount: count)
    }

    private static func normalize(_ value: String?) -> String {
        let cleaned = (value ?? "none")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return cleaned.isEmpty ? "none" : cleaned
    }
}
