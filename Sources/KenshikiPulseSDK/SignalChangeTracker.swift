import Foundation

struct SignalChangeSnapshot: Equatable, Sendable {
    let value: String
    let changeCount: Int
}

enum SignalChangeTracker {
    static func observe(
        keyPrefix: String,
        value: String,
        defaults: UserDefaults = .standard
    ) -> SignalChangeSnapshot {
        let valueKey = "\(keyPrefix).value"
        let countKey = "\(keyPrefix).change.count"
        let previous = defaults.string(forKey: valueKey)
        var count = defaults.integer(forKey: countKey)
        if let previous, previous != value {
            count += 1
            defaults.set(count, forKey: countKey)
        }
        defaults.set(value, forKey: valueKey)
        return SignalChangeSnapshot(value: value, changeCount: count)
    }
}
