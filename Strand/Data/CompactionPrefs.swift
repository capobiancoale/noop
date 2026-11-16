import Foundation

/// Settings and bookkeeping for the OPT-IN compaction of old per-second heart-rate rows
/// (`WhoopStore.compactOldStreams`). Everything here is pure or takes `UserDefaults` / a clock as a
/// parameter so it is unit-testable. Nothing runs by itself: the default is "Never".
enum CompactionPrefs {

    // MARK: Keys
    static let keepDaysKey = "compaction.keepFullResolutionDays"
    /// Unix seconds: the cutoff up to which the last FINISHED real run compacted.
    static let lastCompactedCutoffKey = "compaction.lastCompactedCutoff"
    /// True once the user has pressed "Compact now" (and it finished) at least once.
    static let userRanOnceKey = "compaction.userRanOnce"
    /// Unix seconds of the last automatic daily run attempt.
    static let lastAutoRunKey = "compaction.lastAutoRun"

    /// Choices for `keepFullResolutionDays`; 0 means "Never".
    static let choices: [Int] = [0, 30, 60, 90, 180]

    /// SAFETY SWITCH, now `true`. A full-history rescore (the one-shot `maxDays: 4000` passes, the #547
    /// timestamp re-heal) would rebuild compacted days from minute heart rate and its reconcile steps would
    /// delete stored sessions / detected workouts / daily rows it no longer "detects". What made it safe:
    /// `IntelligenceEngine.analyzeRecent` now clamps its window ONCE, at entry, with `clampedMaxDays` below
    /// (via `IntelligenceEngine.scanWindow`, one day of margin for the 30 h look-back) against
    /// `lastCompactedCutoff()`, and every window it derives (per-day scan, `oldestDay`, session / workout /
    /// daily-row reconciles, `windowStart`) comes from that clamped value, `windowStart` additionally floored
    /// at the oldest scanned day. With no compaction ever run the window is unchanged. Pinned by
    /// `CompactionEngineGuardTests`; keep it `true` only while that clamp stays in place.
    static let engineGuardInstalled = true

    // MARK: Setting

    static func keepFullResolutionDays(defaults: UserDefaults = .standard) -> Int {
        let v = defaults.integer(forKey: keepDaysKey)
        return choices.contains(v) ? v : 0
    }

    static func setKeepFullResolutionDays(_ days: Int, defaults: UserDefaults = .standard) {
        defaults.set(choices.contains(days) ? days : 0, forKey: keepDaysKey)
    }

    // MARK: Cutoff

    /// The cutoff (unix seconds) for "keep `keepDays` days at full resolution": LOCAL midnight `keepDays` days
    /// before today's local midnight, so every local day is either fully compacted or untouched. nil for
    /// Never (0) or an unknown value.
    static func cutoff(now: Date, keepDays: Int, calendar: Calendar = .current) -> Int? {
        guard keepDays > 0, choices.contains(keepDays) else { return nil }
        let today = calendar.startOfDay(for: now)
        guard let d = calendar.date(byAdding: .day, value: -keepDays, to: today) else { return nil }
        return Int(d.timeIntervalSince1970)
    }

    // MARK: Bookkeeping

    static func lastCompactedCutoff(defaults: UserDefaults = .standard) -> Int? {
        let v = defaults.integer(forKey: lastCompactedCutoffKey)
        return v > 0 ? v : nil
    }

    /// Raised BEFORE a real run touches any row, so a run that is cancelled or still going is already
    /// fenced off from the engine's full rescores (`engineCutoff`). Kept apart from the finished cutoff,
    /// which the daily run uses as `skipBefore` and must not move past days a cancelled run never reached.
    static let startedCutoffKey = "compaction.startedCutoff"

    static func markRunStarting(cutoff: Int, defaults: UserDefaults = .standard) {
        let prev = defaults.integer(forKey: startedCutoffKey)
        defaults.set(max(prev, cutoff), forKey: startedCutoffKey)
    }

    /// The newest cutoff any real run has started or finished: the fence for the engine's rescores.
    static func engineCutoff(defaults: UserDefaults = .standard) -> Int? {
        let v = max(defaults.integer(forKey: startedCutoffKey), lastCompactedCutoff(defaults: defaults) ?? 0)
        return v > 0 ? v : nil
    }

    static func userRanOnce(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: userRanOnceKey)
    }

    /// Record a FINISHED real run (never a dry run, never a cancelled one).
    static func recordFinishedRun(cutoff: Int, defaults: UserDefaults = .standard) {
        let prev = lastCompactedCutoff(defaults: defaults) ?? 0
        defaults.set(max(prev, cutoff), forKey: lastCompactedCutoffKey)
        defaults.set(true, forKey: userRanOnceKey)
    }

    // MARK: Automatic daily run

    /// True when the launch hook may start a run: switch on, setting not Never, the user has compacted by
    /// hand at least once, and no attempt in the last 24 h.
    static func autoRunDue(now: Date, defaults: UserDefaults = .standard) -> Bool {
        guard engineGuardInstalled,
              keepFullResolutionDays(defaults: defaults) > 0,
              userRanOnce(defaults: defaults) else { return false }
        let last = defaults.double(forKey: lastAutoRunKey)
        return last <= 0 || now.timeIntervalSince1970 - last >= 86_400
    }

    static func markAutoRunAttempt(now: Date, defaults: UserDefaults = .standard) {
        defaults.set(now.timeIntervalSince1970, forKey: lastAutoRunKey)
    }

    // MARK: Engine clamp (for IntelligenceEngine.analyzeRecent)

    /// The largest `maxDays` the scoring scan may use so it never re-scores a compacted day. With offset `d`
    /// the scanned day starts at `nowLocalMidnight - d * 86400`; it is safe when that is >= the last compacted
    /// cutoff + one day. Returns `maxDays` unchanged when nothing was compacted. Pure.
    static func clampedMaxDays(_ maxDays: Int, nowLocalMidnight: Int, lastCutoff: Int?) -> Int {
        guard let cutoff = lastCutoff else { return maxDays }
        return min(maxDays, max(0, (nowLocalMidnight - cutoff) / 86_400))
    }
}

/// What the Storage screen shows after a real run.
struct CompactionRunSummary: Equatable, Sendable {
    var rowsRemoved: Int
    var finished: Bool
    var dbBefore: Int64?
    var dbAfter: Int64?
    var reclaimableAfter: Int64?
}
