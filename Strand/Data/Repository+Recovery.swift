import Foundation
import StrandAnalytics
import WhoopProtocol
import WhoopStore

// MARK: - Heart-rate recovery after a workout
//
// The data seam for `HeartRateRecoveryEngine`: reads the strap's heart rate around one workout (the last
// minutes of it and up to an hour after) and the person's resting heart rate, and hands both to the engine.
// The maths, its sources and its limits live in StrandAnalytics/HeartRateRecovery.swift.

/// One workout's 1-minute heart-rate drop, for the "recent workouts" chart.
struct RecoveryHistoryPoint: Identifiable, Equatable {
    /// Workout start, Unix seconds (also the identity).
    let start: Int
    /// Peak − HR one minute after the end (bpm).
    let hrr1: Double
    var id: Int { start }
}

extension Repository {

    /// Resting heart rate used for the "back near resting" threshold: the median of the last 7 nights'
    /// resting HR, so one odd night does not move it. nil when no night has one yet.
    private func recoveryRestingHR() -> Double? {
        let recent = days.compactMap { $0.restingHr }.filter { $0 > 0 }.suffix(7).map { Double($0) }.sorted()
        guard !recent.isEmpty else { return nil }
        let n = recent.count
        return n % 2 == 1 ? recent[n / 2] : (recent[n / 2 - 1] + recent[n / 2]) / 2.0
    }

    /// Heart-rate recovery for the workout `[start, end]`, looking `windowMinutes` past its end. nil when the
    /// workout has not ended yet or the strap recorded too little heart rate to say (see the engine).
    func heartRateRecovery(start: Int, end: Int, windowMinutes: Int = 60) async -> HeartRateRecovery? {
        let now = Int(Date().timeIntervalSince1970)
        guard end > start, end < now else { return nil }
        let to = min(now, end + windowMinutes * 60)
        // The last 3 minutes of the workout (the engine looks at the final 2) plus the aftermath.
        let samples = await hrSamples(from: max(start, end - 180), to: to, limit: 20_000)
        guard !samples.isEmpty else { return nil }
        return HeartRateRecoveryEngine.compute(samples: samples, workoutStart: start, workoutEnd: end,
                                               restingHR: recoveryRestingHR(), now: now,
                                               windowMinutes: windowMinutes)
    }

    /// The 1-minute drop of the newest sessions (at least 5 minutes long, ended more than 2 minutes ago) that
    /// have one, oldest → newest. Only the first 3 minutes after each session are read.
    func recentHeartRateRecoveries(limit: Int = 20) async -> [RecoveryHistoryPoint] {
        let now = Int(Date().timeIntervalSince1970)
        // 180 days is far more than the newest `limit` sessions need, and skipping the per-workout HR
        // reconciliation keeps this cheap (it only changes the displayed Avg/Max, not the trace read here).
        let rows = await workoutRows(days: 180, reconcileHr: false)
            .filter { $0.endTs - $0.startTs >= 300 && now - $0.endTs > 120 }
            .prefix(limit)
        var out: [RecoveryHistoryPoint] = []
        for w in rows {
            guard let r = await heartRateRecovery(start: w.startTs, end: w.endTs, windowMinutes: 3),
                  let drop = r.hrr1 else { continue }
            out.append(RecoveryHistoryPoint(start: w.startTs, hrr1: drop))
        }
        return out.sorted { $0.start < $1.start }
    }
}
