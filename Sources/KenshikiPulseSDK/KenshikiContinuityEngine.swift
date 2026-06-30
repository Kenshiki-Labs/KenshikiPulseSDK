import Foundation

/// The continuity state of a device, as a pure logic value (no display copy — host apps supply that).
public enum ContinuityState: String, Codable, Sendable, CaseIterable {
    case attestedContinuous
    case recentBreak
    case extendedBreak
    case anomalous
    case notAttested

    /// Whether continuity is currently intact (the gate for trust-dependent actions).
    public var isLocked: Bool { self == .attestedContinuous }
}

/// What a single check-in did to continuity.
public enum ContinuityOutcome: Equatable, Sendable {
    case firstCheckIn                              // streak established
    case continuous                                // streak held
    case restored                                  // re-attested after a prior break
    case breakDetected(ContinuityBreakReason)      // streak reset by a device/SIM change

    /// Whether this is a successful proof (used by hosts to (re)arm a lapse timer).
    public var isContinuous: Bool {
        switch self {
        case .firstCheckIn, .continuous, .restored: return true
        case .breakDetected: return false
        }
    }
}

/// The persisted continuity state the engine reads at the start of a check-in and writes at the end.
/// Hosts back this with whatever store they like (UserDefaults, a file, the SQLite store).
public struct ContinuityPersistentState: Codable, Equatable, Sendable {
    public var state: ContinuityState
    public var lockedSince: Date?
    public var lastCheckIn: Date?
    public var checkInCount: Int
    public var fingerprint: DeviceFingerprint?

    public init(
        state: ContinuityState = .notAttested,
        lockedSince: Date? = nil,
        lastCheckIn: Date? = nil,
        checkInCount: Int = 0,
        fingerprint: DeviceFingerprint? = nil
    ) {
        self.state = state
        self.lockedSince = lockedSince
        self.lastCheckIn = lastCheckIn
        self.checkInCount = checkInCount
        self.fingerprint = fingerprint
    }
}

/// Injected continuity-state persistence. Async so an actor-backed or file-backed store fits.
public protocol ContinuityStateStore: Sendable {
    func load() async -> ContinuityPersistentState
    func save(_ state: ContinuityPersistentState) async
}

/// Default in-memory store — for tests and headless/ephemeral usage.
actor InMemoryContinuityStateStore: ContinuityStateStore {
    private var current: ContinuityPersistentState

    public init(_ initial: ContinuityPersistentState = ContinuityPersistentState()) {
        self.current = initial
    }

    public func load() async -> ContinuityPersistentState { current }
    public func save(_ state: ContinuityPersistentState) async { current = state }
}

/// The outcome of the pure state machine: the new continuity state and what it means.
public struct ContinuityTransition: Equatable, Sendable {
    public let state: ContinuityState
    public let lockedSince: Date?
    public let checkInCount: Int
    public let outcome: ContinuityOutcome

    public init(state: ContinuityState, lockedSince: Date?, checkInCount: Int, outcome: ContinuityOutcome) {
        self.state = state
        self.lockedSince = lockedSince
        self.checkInCount = checkInCount
        self.outcome = outcome
    }
}

/// The result of one check-in: the signed evidence, the evaluation, and the new continuity state.
public struct ContinuityCheckInResult: Sendable {
    public let envelope: DeviceEvidenceEnvelope
    public let evaluation: ContinuityEvaluation
    public let priorState: ContinuityState
    public let state: ContinuityState
    public let lockedSince: Date?
    public let lastCheckIn: Date
    public let checkInCount: Int
    public let outcome: ContinuityOutcome

    public var breakReason: ContinuityBreakReason? { evaluation.breakReason }

    public init(
        envelope: DeviceEvidenceEnvelope,
        evaluation: ContinuityEvaluation,
        priorState: ContinuityState,
        state: ContinuityState,
        lockedSince: Date?,
        lastCheckIn: Date,
        checkInCount: Int,
        outcome: ContinuityOutcome
    ) {
        self.envelope = envelope
        self.evaluation = evaluation
        self.priorState = priorState
        self.state = state
        self.lockedSince = lockedSince
        self.lastCheckIn = lastCheckIn
        self.checkInCount = checkInCount
        self.outcome = outcome
    }
}

/// Headless continuity engine: collect signed evidence → evaluate against the stored fingerprint →
/// advance the continuity state machine → persist. No UI, no app ledgers — hosts wrap this and apply
/// their own side effects (display log, telemetry, alerts) from the returned `ContinuityCheckInResult`.
///
/// The evidence provider and store are injected, so the whole engine is unit-testable with a stubbed
/// collector and `InMemoryContinuityStateStore`.
public actor KenshikiContinuityEngine {
    private let collectEvidence: @Sendable (KenshikiSessionContext) async throws -> DeviceEvidenceEnvelope
    private let store: ContinuityStateStore

    /// - Parameters:
    ///   - collectEvidence: produces a *signed* envelope (e.g. `{ try await sdk.collectDeviceEvidence(context: $0) }`).
    ///   - store: continuity-state persistence.
    public init(
        collectEvidence: @escaping @Sendable (KenshikiSessionContext) async throws -> DeviceEvidenceEnvelope,
        store: ContinuityStateStore
    ) {
        self.collectEvidence = collectEvidence
        self.store = store
    }

    /// Convenience: drive a `KenshikiPulseSDK` collector directly.
    public init(sdk: KenshikiPulseSDK, store: ContinuityStateStore) {
        self.collectEvidence = { try await sdk.collectDeviceEvidence(context: $0) }
        self.store = store
    }

    public func checkIn(context: KenshikiSessionContext) async throws -> ContinuityCheckInResult {
        let envelope = try await collectEvidence(context)
        let prior = await store.load()
        let now = envelope.generatedAt   // the check-in time is the collection time
        let evaluation = ContinuityEvaluator.evaluate(signals: envelope.signals,
                                                      previous: prior.fingerprint,
                                                      collectedAt: envelope.generatedAt,
                                                      now: now)

        let transition = Self.advance(prior: prior, evaluation: evaluation, now: now)
        let next = ContinuityPersistentState(
            state: transition.state,
            lockedSince: transition.lockedSince,
            lastCheckIn: now,
            checkInCount: transition.checkInCount,
            fingerprint: DeviceFingerprint(from: envelope.signals)
        )
        await store.save(next)

        return ContinuityCheckInResult(
            envelope: envelope,
            evaluation: evaluation,
            priorState: prior.state,
            state: transition.state,
            lockedSince: transition.lockedSince,
            lastCheckIn: now,
            checkInCount: transition.checkInCount,
            outcome: transition.outcome
        )
    }

    /// The pure continuity state machine (no I/O) — exposed `static` so it's directly unit-testable.
    public static func advance(
        prior: ContinuityPersistentState,
        evaluation: ContinuityEvaluation,
        now: Date
    ) -> ContinuityTransition {
        let isFirst = prior.checkInCount == 0
        let count = prior.checkInCount + 1

        if let breakReason = evaluation.breakReason {     // streak resets
            return ContinuityTransition(state: .recentBreak, lockedSince: nil, checkInCount: count,
                                        outcome: .breakDetected(breakReason))
        }
        if isFirst {
            return ContinuityTransition(state: .attestedContinuous, lockedSince: now, checkInCount: count,
                                        outcome: .firstCheckIn)
        }
        if prior.state != .attestedContinuous {           // re-attested after a break
            return ContinuityTransition(state: .attestedContinuous, lockedSince: now, checkInCount: count,
                                        outcome: .restored)
        }
        return ContinuityTransition(state: .attestedContinuous, lockedSince: prior.lockedSince ?? now,
                                    checkInCount: count, outcome: .continuous)
    }
}
