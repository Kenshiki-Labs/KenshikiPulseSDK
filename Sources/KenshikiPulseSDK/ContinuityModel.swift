import Foundation

/// Earned-continuity / pulse-strength model — pure and deterministic, so it's fully unit-testable.
///
/// Two ideas replace the old weighted arithmetic sum (which let a maxed component mask a weak one):
///
/// 1. **Geometric mean (soft-AND).** The live components combine multiplicatively, so a near-zero
///    input drags the whole score down. You can't game it by maxing coverage while authenticity is
///    low — the weakest link dominates.
///
/// 2. **Bayesian belief, not a threshold.** Earned continuity is a Beta posterior: its MEAN rises
///    with maturity (a logistic in days + a saturating curve in check-ins), and its UNCERTAINTY
///    shrinks as check-ins accrue. We expose the LOWER credible bound as the conservative "trust
///    floor" — so trust is earned *with confidence*, never declared. `tHalf` (45d) and the 90
///    check-in target are continuous scale parameters, never hard gates.
///
/// `stateWeight` (0…1) is supplied by the host: it maps the continuity state to a weight (1.0 for a
/// fully-attested device down to 0 for not-attested), keeping the host's state model out of the SDK.
/// See `spec/canonical/pulse-continuity-overview.md` for how this maps to the threat model and bureau bands.
public enum ContinuityModel {
    // Tunables — keep tHalfDays in 30...60 (see spec/earned-continuity-maturity-model.md).
    public static let tHalfDays = 45.0
    public static let daysSteepness = 10.0
    public static let checkInTarget = 90.0
    public static let priorEvidence = 2.0      // weak skeptical prior, in pseudo-check-ins
    public static let lowerBoundZ = 1.28       // ~10th percentile (normal approx to the Beta quantile)
    /// Coherence applied when the primary Wi-Fi network changed since the last check-in. Shallow by
    /// design: a changed network is a weak negative corroborator, never a break. Keep in 0.95…1.0.
    public static let networkChangeCoherence = 0.97

    /// The full evaluation: a point estimate (`mean`), a conservative `lowerBound`, and how tight
    /// the posterior is (`confidence`, 0…1).
    public struct Result: Equatable, Sendable {
        public let mean: Double
        public let lowerBound: Double
        public let confidence: Double
        public let terms: Terms

        public init(mean: Double, lowerBound: Double, confidence: Double, terms: Terms? = nil) {
            self.mean = mean
            self.lowerBound = lowerBound
            self.confidence = confidence
            self.terms = terms ?? Terms(
                coverage: mean,
                breadth: 1,
                recency: 1,
                maturity: mean,
                coherence: 1,
                signalAuthenticity: mean,
                posteriorMean: mean,
                lowerCredibleBound: lowerBound,
                confidenceWidth: max(0, mean - lowerBound),
                evidenceWeight: 1,
                effectiveCheckIns: 0
            )
        }
    }

    /// Named statistical terms used to produce `Result`. These are intentionally public so UI,
    /// telemetry, AI explanation, and tests can talk about uncertainty without reverse-engineering
    /// the score.
    public struct Terms: Equatable, Sendable {
        public let coverage: Double
        public let breadth: Double
        public let recency: Double
        public let maturity: Double
        public let coherence: Double
        public let signalAuthenticity: Double
        public let posteriorMean: Double
        public let lowerCredibleBound: Double
        public let confidenceWidth: Double
        public let evidenceWeight: Double
        public let effectiveCheckIns: Double

        public init(coverage: Double,
                    breadth: Double,
                    recency: Double,
                    maturity: Double,
                    coherence: Double,
                    signalAuthenticity: Double,
                    posteriorMean: Double,
                    lowerCredibleBound: Double,
                    confidenceWidth: Double,
                    evidenceWeight: Double,
                    effectiveCheckIns: Double) {
            self.coverage = coverage
            self.breadth = breadth
            self.recency = recency
            self.maturity = maturity
            self.coherence = coherence
            self.signalAuthenticity = signalAuthenticity
            self.posteriorMean = posteriorMean
            self.lowerCredibleBound = lowerCredibleBound
            self.confidenceWidth = confidenceWidth
            self.evidenceWeight = evidenceWeight
            self.effectiveCheckIns = effectiveCheckIns
        }
    }

    // MARK: - Instantaneous components (each 0…1)

    public static func coverage(live: Int, total: Int) -> Double {
        total > 0 ? Double(live) / Double(total) : 0
    }

    public static func recency(lastCheckIn: Date?, now: Date = Date()) -> Double {
        guard let lastCheckIn else { return 0 }
        let ageHours = now.timeIntervalSince(lastCheckIn) / 3600
        return ageHours <= 24 ? 1 : max(0, 1 - (ageHours - 24) / 48)   // decays over the next 48h
    }

    // MARK: - Maturity curves

    /// Logistic 0…1 centered at `tHalfDays` — gradual, no cliff.
    public static func daysMaturity(_ days: Int) -> Double {
        1 / (1 + exp(-(Double(days) - tHalfDays) / daysSteepness))
    }

    /// Saturating toward 1 as check-ins approach the target (~full near `checkInTarget`).
    public static func checkInMaturity(_ count: Int) -> Double {
        1 - exp(-Double(max(0, count)) / (checkInTarget / 3))
    }

    // MARK: - Combination

    /// Geometric mean with a small per-component floor: a single transient zero won't fully nuke
    /// the score, but low components still dominate (the anti-gaming soft-AND).
    public static func geometricMean(_ values: [Double], floor: Double = 0) -> Double {
        guard !values.isEmpty else { return 0 }
        let sum = values.reduce(0.0) { $0 + log(max(floor, min(1, max(0, $1)))) }
        return exp(sum / Double(values.count))
    }

    /// Soft-AND of live components → the "right now, is this a live and recent signal" quality.
    /// This is the live-quality core of `signalAuthenticity` below.
    public static func instantaneousQuality(coverage: Double, stateWeight: Double, recency: Double) -> Double {
        geometricMean([coverage, stateWeight, recency], floor: 0.04)
    }

    /// Per-check-in **signal authenticity** (0…1) — how genuine the live evidence is right now.
    /// This is the `signal_authenticity` term the maturity model multiplies earned-continuity by
    /// (see spec/earned-continuity-maturity-model.md). v1 = live-signal quality (coverage·state·recency). The
    /// optional `coherence` factor folds in once the collector can supply it — neutral (1.0) until
    /// then, so it's an honest extension point, not a fabricated score.
    public static func signalAuthenticity(coverage: Double, stateWeight: Double, recency: Double,
                                          coherence: Double = 1.0) -> Double {
        instantaneousQuality(coverage: coverage, stateWeight: stateWeight, recency: recency)
            * min(1, max(0, coherence))
    }

    /// Posterior MEAN = soft-AND of earned maturity and live quality: you need both a matured
    /// history and a live present.
    public static func posteriorMean(maturity: Double, instantaneous: Double) -> Double {
        geometricMean([maturity, instantaneous], floor: 0.02)
    }

    /// Lower credible bound of Beta(μ·c, (1−μ)·c) via a normal approximation, where the
    /// concentration `c` grows with accrued evidence (so the bound tightens toward the mean).
    public static func lowerCredibleBound(mean: Double, evidence: Double) -> Double {
        let mu = min(0.999, max(0.001, mean))
        let c = priorEvidence + max(0, evidence)
        let a = mu * c
        let b = (1 - mu) * c
        let variance = (a * b) / ((a + b) * (a + b) * (a + b + 1))
        return min(1, max(0, mu - lowerBoundZ * variance.squareRoot()))
    }

    // MARK: - Top-level

    // swiftlint:disable function_parameter_count
    /// - Parameter stateWeight: host-supplied continuity-state weight in 0…1 (1.0 fully attested → 0 not attested).
    public static func evaluate(signalsLive: Int, signalsTotal: Int, stateWeight: Double,
                                lastCheckIn: Date?, daysContinuous: Int, checkInCount: Int,
                                coherence: Double = 1.0, evidenceWeight: Double = 1.0,
                                now: Date = Date()) -> Result {
        evaluateFromComponents(coverage: coverage(live: signalsLive, total: signalsTotal),
                               breadth: evidenceWeight,
                               stateWeight: stateWeight,
                               lastCheckIn: lastCheckIn,
                               daysContinuous: daysContinuous,
                               checkInCount: checkInCount,
                               coherence: coherence,
                               now: now)
    }

    // swiftlint:disable function_parameter_count
    public static func evaluateFromComponents(coverage: Double,
                                              breadth: Double,
                                              stateWeight: Double,
                                              lastCheckIn: Date?,
                                              daysContinuous: Int,
                                              checkInCount: Int,
                                              coherence: Double = 1.0,
                                              now: Date = Date()) -> Result {
        let effectiveEvidenceWeight = min(1, max(0, breadth))
        let effectiveCheckIns = Double(max(0, checkInCount)) * effectiveEvidenceWeight
        let coverage = min(1, max(0, coverage))
        let recency = recency(lastCheckIn: lastCheckIn, now: now)
        let coherence = min(1, max(0, coherence))
        let authenticity = signalAuthenticity(
            coverage: coverage,
            stateWeight: stateWeight,
            recency: recency,
            coherence: coherence
        )
        let maturity = 0.6 * daysMaturity(daysContinuous) + 0.4 * checkInMaturity(Int(effectiveCheckIns.rounded(.down)))
        let mean = posteriorMean(maturity: maturity, instantaneous: authenticity)
        let lower = lowerCredibleBound(mean: mean, evidence: effectiveCheckIns)
        let confidence = mean > 0 ? min(1, max(0, lower / mean)) : 0
        return Result(
            mean: mean,
            lowerBound: lower,
            confidence: confidence,
            terms: Terms(
                coverage: coverage,
                breadth: effectiveEvidenceWeight,
                recency: recency,
                maturity: maturity,
                coherence: coherence,
                signalAuthenticity: authenticity,
                posteriorMean: mean,
                lowerCredibleBound: lower,
                confidenceWidth: max(0, mean - lower),
                evidenceWeight: effectiveEvidenceWeight,
                effectiveCheckIns: effectiveCheckIns
            )
        )
    }
    // swiftlint:enable function_parameter_count

    // swiftlint:disable function_parameter_count
    public static func evaluate(snapshot: ContinuityEvidenceSnapshot,
                                stateWeight: Double,
                                lastCheckIn: Date?,
                                daysContinuous: Int,
                                checkInCount: Int,
                                coherence: Double = 1.0,
                                now: Date = Date()) -> Result {
        evaluateFromComponents(coverage: snapshot.groupedEligibleCoverage,
                               breadth: snapshot.groupedEvidenceBreadth,
                               stateWeight: stateWeight,
                               lastCheckIn: lastCheckIn,
                               daysContinuous: daysContinuous,
                               checkInCount: checkInCount,
                               coherence: coherence,
                               now: now)
    }
    // swiftlint:enable function_parameter_count
}
