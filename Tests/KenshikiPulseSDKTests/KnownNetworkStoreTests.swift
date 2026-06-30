import XCTest
@testable import KenshikiPulseSDK

final class KnownNetworkStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var store: KnownNetworkStore!
    private let token = "tok_abc"

    override func setUp() {
        super.setUp()
        // Isolated suite so tests never touch the real device store.
        defaults = UserDefaults(suiteName: "known-network-tests-\(UUID().uuidString)")
        store = KnownNetworkStore(defaults: defaults)
    }

    private func day(_ d: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(d) * 86_400 + 36_000) }
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(secondsFromGMT: 0)!; return c
    }

    func testFirstSightingIsNew() {
        XCTAssertEqual(store.observe(token: token, at: day(0), calendar: utc), .new)
    }

    func testSecondSightingSameDayIsKnown() {
        _ = store.observe(token: token, at: day(0), calendar: utc)
        // Same day, second visit → known (visitCount >= 2), not yet familiar.
        XCTAssertEqual(store.observe(token: token, at: day(0).addingTimeInterval(60), calendar: utc), .known)
    }

    func testRecurringAcrossThreeDaysIsFamiliar() {
        XCTAssertEqual(store.observe(token: token, at: day(0), calendar: utc), .new)
        XCTAssertEqual(store.observe(token: token, at: day(1), calendar: utc), .known)   // 2 distinct days
        XCTAssertEqual(store.observe(token: token, at: day(2), calendar: utc), .familiar) // 3 distinct days
    }

    func testSameDayRepeatsDoNotInflateDistinctDays() {
        _ = store.observe(token: token, at: day(0), calendar: utc)
        _ = store.observe(token: token, at: day(0).addingTimeInterval(100), calendar: utc)
        _ = store.observe(token: token, at: day(0).addingTimeInterval(200), calendar: utc)
        // Three visits but one day → still just "known", never reaches familiar on a single day.
        XCTAssertEqual(store.observe(token: token, at: day(0).addingTimeInterval(300), calendar: utc), .known)
    }

    func testNilOrEmptyTokenIsUnknown() {
        XCTAssertEqual(store.observe(token: nil, at: day(0), calendar: utc), .unknown)
        XCTAssertEqual(store.observe(token: "", at: day(0), calendar: utc), .unknown)
    }

    func testFamiliarityPeekIsReadOnly() {
        _ = store.observe(token: token, at: day(0), calendar: utc)   // recorded once (new)
        // Peeking many times must not advance the classification — only observe() records visits.
        for _ in 0..<5 { XCTAssertEqual(store.familiarity(of: token), .new) }
        // An unseen token peeks as new without being recorded.
        XCTAssertEqual(store.familiarity(of: "never_seen"), .new)
    }

    func testClassifyThresholds() {
        let oneDay = NetworkVisit(firstSeen: day(0), lastSeen: day(0), visitCount: 1, distinctDays: 1, lastCountedDay: day(0))
        XCTAssertEqual(KnownNetworkStore.classify(oneDay), .new)
        let twoVisits = NetworkVisit(firstSeen: day(0), lastSeen: day(0), visitCount: 2, distinctDays: 1, lastCountedDay: day(0))
        XCTAssertEqual(KnownNetworkStore.classify(twoVisits), .known)
        let threeDays = NetworkVisit(firstSeen: day(0), lastSeen: day(2), visitCount: 3, distinctDays: 3, lastCountedDay: day(2))
        XCTAssertEqual(KnownNetworkStore.classify(threeDays), .familiar)
    }
}
