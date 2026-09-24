import Foundation
import WhoopStore

// VO2maxEngine.swift — maximal oxygen uptake from the wearer's own data, estimated two independent ways.
//
// DURING EXERCISE. Every steady walk or run with a distance, a duration and a heart rate is a single-stage
// submaximal test:
//   • Oxygen cost of the pace — the ACSM metabolic equations for level walking and running (ACSM's Guidelines
//     for Exercise Testing and Prescription, 11th ed., 2021): walking 3.5 + 0.1·S, running 3.5 + 0.2·S, with S
//     in m/min. The grade terms are implemented, but sessions carry no elevation, so level ground is assumed.
//   • Intensity — the fraction of heart-rate reserve equals the fraction of VO2 reserve: intercept −0.1 and
//     slope 1.00 on the cycle ergometer (Swain & Leutholtz, Med Sci Sports Exerc 1997), 1.5 and 1.03 on the
//     treadmill (Swain et al., MSSE 1998). So VO2max = 3.5 + (VO2 − 3.5) / %HRR, the VO2-reserve method,
//     validated from one steady stage at a mean 64% HRR against measured VO2max: r 0.89, SEE 4.0 mL/kg/min,
//     no over- or underestimation (Swain et al., MSSE 2004).
//   • Sessions are combined by their median, so one hot, tired or badly-tracked session cannot move the number.
// Exercise-based estimates are the more accurate family on consumer wearables: bias −0.09, 95% limits of
// agreement −9.9…+9.7 mL/kg/min, against +2.17 and −13.1…+17.4 for resting-based ones (INTERLIVE meta-analysis,
// Molina-Garcia et al., Sports Med 2022).
//
// AT REST. The HUNT non-exercise model (Nes et al., MSSE 2011) from age, sex, waist, resting heart rate and the
// HUNT activity index (FitnessAgeEngine), reported with its standard error of estimate.
//
// Tools/vo2max-validation checks the exercise assumptions on 981 laboratory treadmill tests (PhysioNet,
// University of Malaga): the submaximal HR–VO2 line reaches the measured VO2max at the measured HRmax with a
// bias of +0.85 and an SD of 5.5 mL/kg/min (SD 7.0 with an age-predicted HRmax), and Tanaka's HRmax is unbiased
// there (−0.9 bpm, SD 9.1). Not a medical device: a fitness estimate, not a clinical exercise test.
public enum VO2maxEngine {

    /// Resting oxygen uptake, one MET (mL/kg/min): the VO2-reserve anchor (ACSM; Swain & Leutholtz 1997).
    public static let restingVO2 = 3.5

    // MARK: - Oxygen cost of walking and running (ACSM metabolic equations)

    public enum Gait: String, Sendable, Hashable, CaseIterable { case walking, running }

    /// ACSM walking equation, mL/kg/min: 3.5 + 0.1·S + 1.8·S·G (S m/min, G fractional grade). Most accurate at
    /// 50–100 m/min (3–6 km/h).
    public static func walkingVO2(speedKmh: Double, grade: Double = 0) -> Double {
        let s = speedKmh * 1000 / 60
        return restingVO2 + 0.1 * s + 1.8 * s * grade
    }

    /// ACSM running equation, mL/kg/min: 3.5 + 0.2·S + 0.9·S·G. For speeds above 134 m/min (8 km/h), or from
    /// 80 m/min when the subject is truly jogging.
    public static func runningVO2(speedKmh: Double, grade: Double = 0) -> Double {
        let s = speedKmh * 1000 / 60
        return restingVO2 + 0.2 * s + 0.9 * s * grade
    }

    public static func oxygenCost(_ gait: Gait, speedKmh: Double, grade: Double = 0) -> Double {
        gait == .walking ? walkingVO2(speedKmh: speedKmh, grade: grade) : runningVO2(speedKmh: speedKmh, grade: grade)
    }

    // MARK: - VO2-reserve extrapolation

    /// Fraction of heart-rate reserve (Karvonen), or nil when the reserve is not positive.
    public static func heartRateReserveFraction(hr: Double, restingHR: Double, maxHR: Double) -> Double? {
        guard maxHR > restingHR, restingHR > 0 else { return nil }
        return (hr - restingHR) / (maxHR - restingHR)
    }

    /// VO2max from one steady submaximal effort, taking %HRR = %VO2R (Swain & Leutholtz 1997; Swain et al. 2004).
    public static func vo2max(vo2: Double, hrrFraction: Double) -> Double? {
        guard hrrFraction > 0, vo2 > restingVO2 else { return nil }
        return restingVO2 + (vo2 - restingVO2) / hrrFraction
    }

    // MARK: - One session

    /// A walk or run as a submaximal test: its pace and its steady-state heart rate.
    public struct Session: Sendable, Equatable {
        public let start: Int           // unix seconds
        public let durationS: Double
        public let distanceM: Double
        public let heartRate: Double    // steady-state mean, bpm
        public let gait: Gait
        public init(start: Int, durationS: Double, distanceM: Double, heartRate: Double, gait: Gait) {
            self.start = start; self.durationS = durationS; self.distanceM = distanceM
            self.heartRate = heartRate; self.gait = gait
        }
        public var speedKmh: Double { durationS > 0 ? distanceM / durationS * 3.6 : 0 }
    }

    /// Why a session was not used. Each gate keeps the session inside the conditions the method was validated in.
    public enum Rejection: String, Error, Sendable, Hashable, CaseIterable {
        /// No usable distance, duration or heart rate, or no resting heart rate / HRmax to scale it by.
        case missingData
        /// Under 10 minutes or 1 km: no steady state yet (Swain et al. 2004 read the 5th–6th minute).
        case tooShort
        /// Over 90 minutes: cardiovascular drift raises the heart rate at the same pace.
        case tooLong
        /// Average pace outside the speeds the ACSM equation for that gait holds for.
        case paceOutOfRange
        /// Below 50% of heart-rate reserve: the extrapolation to 100% gets long, so a few bpm of error move
        /// the estimate by more than 5%.
        case tooEasy
        /// Above 85% of heart-rate reserve: no longer a steady submaximal effort.
        case tooHard
    }

    /// A session that passed the gates, with the numbers that produced its VO2max.
    public struct SessionEstimate: Sendable, Equatable {
        public let session: Session
        public let restingHR: Double
        public let maxHR: Double
        public let vo2: Double          // oxygen cost of the session's pace, mL/kg/min
        public let hrrFraction: Double  // 0–1
        public let vo2max: Double
    }

    public static let minDurationS: Double = 600
    public static let maxDurationS: Double = 5_400
    public static let minDistanceM: Double = 1_000
    public static let minHRRFraction = 0.50
    public static let maxHRRFraction = 0.85
    /// ACSM walking holds for 50–100 m/min (3–6 km/h); a little headroom for brisk walkers.
    public static let walkingSpeedKmh: ClosedRange<Double> = 3.0...6.5
    /// Continuous running: from 7 km/h (the walk–run transition is about 7.2 km/h; ACSM's running equation
    /// applies from 80 m/min when truly jogging) to elite pace.
    public static let runningSpeedKmh: ClosedRange<Double> = 7.0...22.0

    /// Evaluate one session against the gates and, if it passes, estimate VO2max from it.
    public static func evaluate(_ s: Session, restingHR: Double, maxHR: Double) -> Result<SessionEstimate, Rejection> {
        guard s.durationS > 0, s.distanceM > 0, s.heartRate > 0, restingHR > 0, maxHR > restingHR else {
            return .failure(.missingData)
        }
        guard s.durationS >= minDurationS, s.distanceM >= minDistanceM else { return .failure(.tooShort) }
        guard s.durationS <= maxDurationS else { return .failure(.tooLong) }
        let speed = s.speedKmh
        guard (s.gait == .walking ? walkingSpeedKmh : runningSpeedKmh).contains(speed) else {
            return .failure(.paceOutOfRange)
        }
        guard let f = heartRateReserveFraction(hr: s.heartRate, restingHR: restingHR, maxHR: maxHR) else {
            return .failure(.missingData)
        }
        guard f >= minHRRFraction else { return .failure(.tooEasy) }
        guard f <= maxHRRFraction else { return .failure(.tooHard) }
        let vo2 = oxygenCost(s.gait, speedKmh: speed)
        guard let v = vo2max(vo2: vo2, hrrFraction: f) else { return .failure(.missingData) }
        return .success(SessionEstimate(session: s, restingHR: restingHR, maxHR: maxHR, vo2: vo2,
                                        hrrFraction: f, vo2max: v))
    }

    // MARK: - Inputs from the wearer's data

    /// Walking or running from a workout's sport name, or nil for anything else. Hikes, trail runs, rucks and
    /// mountain sessions are left out: the level-ground equations cannot see their climbing.
    public static func gait(forSport sport: String) -> Gait? {
        let s = sport.lowercased()
        if ["trail", "hik", "ruck", "mountain", "climb"].contains(where: { s.contains($0) }) { return nil }
        if s.contains("run") || s.contains("jog") { return .running }
        if s.contains("walk") { return .walking }
        return nil
    }

    /// Seconds ignored at the start of a session while the heart rate rises to its steady state.
    public static let heartRateOnsetS = 180
    /// Share of the steady part a heart-rate record must cover to be used.
    public static let minHeartRateCoverage = 0.8

    /// Steady-state mean heart rate of a session from per-minute (or finer) buckets of the wearer's heart rate:
    /// the mean from `heartRateOnsetS` after the start to the end, or nil when buckets cover less than
    /// `minHeartRateCoverage` of that span.
    public static func steadyHeartRate(_ buckets: [HRBucket], start: Int, end: Int, bucketSeconds: Int = 60) -> Double? {
        let from = start + heartRateOnsetS
        guard end - from >= bucketSeconds, bucketSeconds > 0 else { return nil }
        // A bucket is keyed by its start: keep those that begin inside the steady part.
        let inside = buckets.filter { $0.ts >= from && $0.ts < end && $0.bpm > 0 }
        guard !inside.isEmpty,
              Double(inside.count * bucketSeconds) >= minHeartRateCoverage * Double(end - from) else { return nil }
        return inside.map(\.bpm).reduce(0, +) / Double(inside.count)
    }

    /// Nights of resting heart rate the session is scaled by (the ones up to and including its day).
    public static let restingHRNights = 14

    /// Resting heart rate for a session: the median of the nightly values available in the preceding
    /// `restingHRNights` days, so a single short or feverish night does not shift it.
    public static func restingHeartRate(_ nightly: [Double]) -> Double? {
        median(nightly.filter { $0 > 0 })
    }

    // MARK: - HRmax

    public enum MaxHRSource: String, Sendable, Hashable { case userSet, observed, agePredicted }

    public struct MaxHR: Sendable, Equatable {
        public let bpm: Double
        public let source: MaxHRSource
        public init(bpm: Double, source: MaxHRSource) { self.bpm = bpm; self.source = source }
    }

    /// Standard error of an age-predicted HRmax, bpm (Nes et al., Scand J Med Sci Sports 2013, n = 3,320 with
    /// a verified maximal effort). It bounds which workout peaks are believable.
    public static let hrMaxPredictionSD = 10.8

    /// The HRmax the estimate scales by. The user's own setting wins (a measured value). Otherwise the
    /// second-highest workout peak, which discards a single optical spike, provided at least three peaks lie
    /// within 3 SD of the age prediction and it is no more than 2 SD below it (lower means no maximal effort was
    /// recorded yet). Otherwise Tanaka's 208 − 0.7·age (J Am Coll Cardiol 2001), unbiased on the validation data.
    public static func maxHR(userSet: Double?, workoutPeaks: [Double], age: Double?) -> MaxHR? {
        if let u = userSet, u > 0 { return MaxHR(bpm: u, source: .userSet) }
        guard let age, age > 0 else { return nil }
        let predicted = StrainScorer.tanakaHRmax(age: age)
        let believable = workoutPeaks.filter { abs($0 - predicted) <= 3 * hrMaxPredictionSD }.sorted(by: >)
        if believable.count >= 3, believable[1] >= predicted - 2 * hrMaxPredictionSD {
            return MaxHR(bpm: believable[1], source: .observed)
        }
        return MaxHR(bpm: predicted, source: .agePredicted)
    }

    // MARK: - Combining sessions

    /// The current estimate: the median of the most recent qualifying sessions.
    public struct Estimate: Sendable, Equatable {
        public let vo2max: Double
        public let low: Double                  // lowest session value used
        public let high: Double                 // highest session value used
        public let sessions: [SessionEstimate]  // newest first
    }

    /// Sessions older than this no longer describe current fitness.
    public static let windowDays = 90
    /// At most this many of the newest sessions are combined.
    public static let maxSessions = 5

    /// The estimate as of `asOf` (unix seconds): the median of the newest `maxSessions` sessions that started
    /// in the `windowDays` before it. nil when there are none.
    public static func summarize(_ estimates: [SessionEstimate], asOf: Int) -> Estimate? {
        let recent = estimates
            .filter { $0.session.start <= asOf && $0.session.start > asOf - windowDays * 86_400 }
            .sorted { $0.session.start > $1.session.start }
            .prefix(maxSessions)
        guard let v = median(recent.map(\.vo2max)) else { return nil }
        let values = recent.map(\.vo2max)
        return Estimate(vo2max: v, low: values.min() ?? v, high: values.max() ?? v, sessions: Array(recent))
    }

    /// The estimate after each qualifying session, oldest first: what the number read on the day of each one.
    public static func trend(_ estimates: [SessionEstimate]) -> [(start: Int, estimate: Estimate)] {
        estimates.map(\.session.start).sorted().compactMap { t in summarize(estimates, asOf: t).map { (t, $0) } }
    }

    // MARK: - At rest

    public struct RestingEstimate: Sendable, Equatable {
        public let vo2max: Double
        public let standardError: Double   // Nes 2011 SEE, mL/kg/min
        public let paIndex: Double
    }

    /// The HUNT non-exercise estimate (Nes et al. 2011, waist model) with its standard error, or nil without a
    /// waist measurement, an age or a resting heart rate.
    public static func restingEstimate(age: Double, sex: String, waistCm: Double, restingHR: Double,
                                       paIndex: Double) -> RestingEstimate? {
        guard age > 0, waistCm > 0, restingHR > 0 else { return nil }
        let v = FitnessAgeEngine.estimateVO2max(age: age, sex: sex, waistCm: waistCm, restingHR: restingHR,
                                                paIndex: paIndex)
        let see = sex.lowercased() == "female" ? FitnessAgeEngine.seeWomen : FitnessAgeEngine.seeMen
        return RestingEstimate(vo2max: v, standardError: see, paIndex: paIndex)
    }

    // MARK: - Helpers

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let s = values.sorted(), n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }
}
