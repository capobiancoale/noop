import Foundation
import WhoopProtocol
import WhoopStore
import StrandAnalytics

// MARK: - Why Charge is missing: what last night actually recorded
//
// Charge compares last night's HRV with the person's own baseline, and the HRV comes from the beat-to-beat
// (R-R) intervals stored during sleep. On a WHOOP 5.0/MG those arrive over the live heart-rate stream while
// the phone is connected, so a night with the phone asleep has heart rate but no beats, and Charge stays
// empty. This reads the facts the "Why there's no Charge yet" sheet shows: nights with a usable HRV in the
// last 7 days, and for last night's main sleep the hours of heart rate, the R-R beats and the share of the
// night they cover. The arithmetic lives in StrandAnalytics.NightCoverage.

extension Repository {

    /// Everything the sheet shows. `coverage` is nil when no main sleep ended in the last 18 hours.
    struct RecoveryDiagnostics: Equatable {
        /// Nights among the last 7 days whose nightly HRV counts toward Charge's baseline.
        let usableNightsLast7: Int
        /// Nights Charge needs before it starts (`Baselines.minNightsSeed`).
        let nightsNeeded: Int
        let sleepStart: Int?
        let sleepEnd: Int?
        let coverage: NightCoverage.Summary?

        var fixes: NightCoverage.Fixes { NightCoverage.suggestedFixes(for: coverage) }
    }

    /// R-R intervals over `[from, to]` from the active strap and the canonical "my-whoop" namespace, the
    /// same union `hrSamples` reads, so the beats are looked up wherever the night's heart rate was banked
    /// (a re-added strap writes under its own id, #814). A beat present under both ids is counted once;
    /// ascending by time. A single-device install reads one id.
    func rrIntervals(from: Int, to: Int, limit: Int = 200_000) async -> [RRInterval] {
        guard let store = await storeHandle() else { return [] }
        let ids = deviceId == Self.whoopSource ? [deviceId] : [deviceId, Self.whoopSource]
        var seen = Set<String>()
        var out: [RRInterval] = []
        for id in ids {
            let rows = (try? await store.rrIntervals(deviceId: id, from: from, to: to, limit: limit)) ?? []
            for r in rows where seen.insert("\(r.ts)/\(r.rrMs)").inserted { out.append(r) }
        }
        return out.sorted { $0.ts < $1.ts }
    }

    /// Last night's main sleep: the longest session that ended within the last 18 hours (a nap that
    /// ended later does not displace the night). Nil when there is none.
    func lastNightSession(now: Date = Date()) -> CachedSleepSession? {
        let nowTs = Int(now.timeIntervalSince1970)
        let recent = sleeps.filter { $0.endTs >= nowTs - 18 * 3600 && $0.endTs <= nowTs + 3600 }
        return recent.max { ($0.endTs - $0.effectiveStartTs) < ($1.endTs - $1.effectiveStartTs) }
    }

    func recoveryDiagnostics(now: Date = Date()) async -> RecoveryDiagnostics {
        // Nights keyed by wake day: today's logical day and the six before it.
        let calendar = Calendar.current
        let sixBack = calendar.date(byAdding: .day, value: -6, to: Self.logicalDay(now)) ?? now
        let cutoff = Self.localDayKey(sixBack)
        let usable = NightCoverage.usableHrvNights(nightlyHrv: days.filter { $0.day >= cutoff }.map(\.avgHrv))

        guard let night = lastNightSession(now: now) else {
            return RecoveryDiagnostics(usableNightsLast7: usable, nightsNeeded: Baselines.minNightsSeed,
                                       sleepStart: nil, sleepEnd: nil, coverage: nil)
        }
        let start = night.effectiveStartTs
        let end = night.endTs
        let hr = await hrSamples(from: start, to: end, limit: 200_000)
        let rr = await rrIntervals(from: start, to: end)
        let stamps = hr.map(\.ts)
        // The window-by-window HRV gate is a few thousand short filters: keep it off the main actor.
        let coverage = await Task.detached(priority: .utility) {
            NightCoverage.summarize(hrTimestamps: stamps, rr: rr, start: start, end: end)
        }.value
        return RecoveryDiagnostics(usableNightsLast7: usable, nightsNeeded: Baselines.minNightsSeed,
                                   sleepStart: start, sleepEnd: end, coverage: coverage)
    }
}
