import Foundation
import WhoopProtocol
import WhoopStore
import StrandAnalytics

// MARK: - Night heart rhythm: the strap's beats while asleep, screened for an irregular rhythm
//
// For each of the last 14 nights this reads the beat-to-beat (R-R) intervals stored inside the night's main
// sleep and runs `StrandAnalytics.IrregularRhythm` on them: a screen for a rhythm that is irregular the way
// atrial fibrillation is (Dash et al., Ann Biomed Eng 2009), reported with how much of the night it covered
// (the Fitbit Heart Study idea of persistence, Lubitz et al., Circulation 2022). It is a screen, never a
// diagnosis: only an ECG can confirm atrial fibrillation. The maths, thresholds and their validation live in
// the engine; this file only picks the nights, reads the beats and keeps the heavy work off the main actor.
//
// A "night" is the longest sleep session of a wake day (the same rule as `lastNightSession`), and only
// sessions of two hours or more count: a nap is not a night. The sessions come from `sleeps`, the merged
// dashboard cache, so an imported or hand-edited night is screened over the window the person sees.

extension Repository {

    /// Nights the card's strip and the Explore series look back over.
    static let heartRhythmNights = 14
    /// A main sleep shorter than this is a nap, not a night.
    static let heartRhythmMinSleepSeconds = 2 * 3600

    /// One wake day's main sleep: the window to screen.
    struct MainSleep: Equatable {
        /// Local wake day, `yyyy-MM-dd` (the key daily metrics use).
        let day: String
        /// Unix seconds.
        let start: Int
        let end: Int
    }

    /// A night's screening result with the window it was run on.
    struct IrregularRhythmNight: Equatable, Identifiable {
        let day: String
        let start: Int
        let end: Int
        let result: IrregularRhythm.NightResult
        var id: String { day }
    }

    /// What the "Night heart rhythm" card shows.
    struct HeartRhythmReport: Equatable {
        /// The nights of the last 14 days that have a main sleep, oldest first.
        let nights: [IrregularRhythmNight]
        /// The newest of them.
        var lastNight: IrregularRhythmNight? { nights.last }
    }

    /// The main sleep of each wake day in the last `lastDays` days (today included), oldest first.
    func mainSleeps(lastDays: Int = Repository.heartRhythmNights, now: Date = Date()) -> [MainSleep] {
        let nowTs = Int(now.timeIntervalSince1970)
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -(lastDays - 1), to: now) ?? now
        let cutoff = Self.localDayKey(cutoffDate)
        var longestByDay: [String: CachedSleepSession] = [:]
        // `sleeps` holds the whole history: skip the old rows before the (slower) time-zone lookup.
        let oldest = nowTs - (lastDays + 1) * 86_400
        for s in sleeps where s.endTs <= nowTs + 3600 && s.endTs >= oldest {
            let offset = TimeZone.current.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(s.endTs)))
            let day = AnalyticsEngine.dayString(s.endTs, offsetSec: offset)
            guard day >= cutoff else { continue }
            let length = s.endTs - s.effectiveStartTs
            guard length >= Self.heartRhythmMinSleepSeconds else { continue }
            if let best = longestByDay[day], best.endTs - best.effectiveStartTs >= length { continue }
            longestByDay[day] = s
        }
        return longestByDay.keys.sorted().compactMap { day in
            longestByDay[day].map { MainSleep(day: day, start: $0.effectiveStartTs, end: $0.endTs) }
        }
    }

    /// Screen one night: read the beats inside the sleep and run the engine off the main actor.
    func irregularRhythm(for sleep: MainSleep) async -> IrregularRhythm.NightResult {
        let rr = await rrIntervals(from: sleep.start, to: sleep.end)
        let window = IrregularRhythm.Window(start: sleep.start, end: sleep.end)
        return await Task.detached(priority: .utility) {
            IrregularRhythm.screen(rr: rr, windows: [window])
        }.value
    }

    /// The last 14 nights, screened. Both places that show the card (Health and Heart-rate accuracy) ask for
    /// the same thing in the same refresh, so the answer is kept until the data reloads or the day changes.
    func heartRhythmReport(now: Date = Date()) async -> HeartRhythmReport {
        let key = "\(refreshSeq)|\(Self.localDayKey(now))|\(sleeps.count)"
        if let cached = heartRhythmReportCache, cached.key == key { return cached.report }
        var nights: [IrregularRhythmNight] = []
        for sleep in mainSleeps(now: now) {
            let result = await irregularRhythm(for: sleep)
            nights.append(IrregularRhythmNight(day: sleep.day, start: sleep.start, end: sleep.end, result: result))
        }
        let report = HeartRhythmReport(nights: nights)
        heartRhythmReportCache = (key: key, report: report)
        return report
    }
}

/// The last report `heartRhythmReport` built and the data state it was built for.
@MainActor private var heartRhythmReportCache: (key: String, report: Repository.HeartRhythmReport)?
