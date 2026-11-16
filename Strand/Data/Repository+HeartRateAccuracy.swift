import Foundation
import WhoopProtocol
import WhoopStore
import StrandAnalytics

// MARK: - Heart-rate accuracy: the strap against its own beats, and against the wearer's own baseline
//
// Reads what the "Heart-rate accuracy" screen shows: the last 24 hours of heart rate beside the R-R
// intervals stored with it (is the strap's bpm consistent with its own beat timing?), last night's sleeping
// floor and mean, and the waking range over the last 7 days, so "my heart rate is always high" can be judged
// against the person's own numbers. The arithmetic lives in StrandAnalytics.HeartRateAccuracy.

extension Repository {

    struct HeartRateAccuracyReport: Equatable {
        /// Strap bpm against 60000 / R-R over the last 24 hours; nil when too few seconds could be compared.
        let agreement: HeartRateAccuracy.Agreement?
        /// Last night's sleeping floor and mean; nil without a recent night or enough samples.
        let sleeping: HeartRateAccuracy.SleepHeartRate?
        /// The waking range over the last 7 days; nil with under two hours of waking windows.
        let waking: HeartRateAccuracy.WakingHeartRate?
    }

    func heartRateAccuracyReport(now: Date = Date()) async -> HeartRateAccuracyReport {
        let nowTs = Int(now.timeIntervalSince1970)

        // Last 24 hours: heart rate and the beats stored with it.
        let dayStart = nowTs - 24 * 3600
        let hr = await hrSamples(from: dayStart, to: nowTs, limit: 200_000)
        let rr = await rrIntervals(from: dayStart, to: nowTs)

        // Last night, for the sleeping floor and mean.
        let night = lastNightSession(now: now)
        let nightStart = night?.effectiveStartTs ?? 0
        let nightEnd = night?.endTs ?? 0
        // (An `await` cannot sit to the right of `?:`, hence the explicit branches.)
        let nightHr: [HRSample]
        if night != nil {
            nightHr = await hrSamples(from: nightStart, to: nightEnd, limit: 200_000)
        } else {
            nightHr = []
        }

        // Last 7 days in 5-minute means (aggregated in SQL, so no raw samples), minus every sleep block,
        // naps included, so the waking range is not pulled down by sleep.
        let weekStart = nowTs - 7 * 86_400
        let buckets = await hrBuckets(from: weekStart, to: nowTs, bucketSeconds: 300)
        let blocks = await allSleepSessions(days: 9).map { (start: $0.effectiveStartTs, end: $0.endTs) }

        // The comparisons loop over up to 86k seconds: keep them off the main actor.
        return await Task.detached(priority: .utility) { () -> HeartRateAccuracyReport in
            let agreement = HeartRateAccuracy.rrConsistency(
                hr: hr.map { (ts: $0.ts, bpm: Double($0.bpm)) },
                rr: rr.map { (ts: $0.ts, rrMs: Double($0.rrMs)) })
            let sleeping = nightEnd > nightStart
                ? HeartRateAccuracy.sleeping(hr: nightHr, start: nightStart, end: nightEnd) : nil
            let waking = HeartRateAccuracy.waking(
                windows: buckets.map { (ts: $0.ts, bpm: $0.bpm) }, excluding: blocks)
            return HeartRateAccuracyReport(agreement: agreement, sleeping: sleeping, waking: waking)
        }.value
    }
}
