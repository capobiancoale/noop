import Foundation
import GRDB

// MARK: - Opt-in compaction of OLD per-second heart-rate rows
//
// WHAT IT DOES
//   For rows OLDER than a caller-supplied `cutoff` (unix seconds) it thins ONLY two tables:
//     * hrSample      -> one row per device per minute: the MEDIAN bpm of that minute, stamped at the
//                        minute start (ts - ts % 60).
//     * ppgHrSample   -> same rule, for the PPG-derived estimate (see "Why ppgHrSample" below).
//   Nothing else is touched. In particular NEVER touched: rrInterval, gravitySample, sleepStateSample,
//   stepSample, strapSpo2Sample, spo2Sample, skinTempSample, respSample, battery, event, rawBatch,
//   dailyMetric, metricSeries, sleepSession, workout, wodLog, journal, labMarker, appleDaily, device,
//   pairedDevice, cursors, liveSession. (A test pins every one of these.)
//   The investigation behind that scope is in the report that accompanied this file: every other
//   per-second stream still has a reader of OLD rows (Deep Timeline tracks, 60-day steps calibration,
//   HRV recomputation, motion/sleep re-staging) that would silently degrade, so they are left alone.
//
// MEDIAN (documented choice)
//   SQLite has no MEDIAN. The median is computed IN SWIFT per minute: values sorted ascending; odd count ->
//   the middle value; even count -> the mean of the two middle values rounded half-up to whole bpm
//   ((a + b + 1) / 2). hrSample.bpm is INTEGER, so the result is always a whole bpm.
//
// WHY ppgHrSample IS THINNED TOGETHER WITH hrSample
//   Every reader (hrSamples, hrBuckets) COALESCEs hrSample with ppgHrSample through an anti-join on the
//   exact (deviceId, ts): "a PPG estimate shows only at a second with NO hrSample row". If hrSample alone
//   were thinned to minute rows, the PPG estimates at the 59 seconds that just lost their hrSample row
//   would suddenly satisfy the anti-join and RE-APPEAR, mixing 1 Hz estimates back into minute data and
//   shifting the bucket means. So the unit of work is the per-minute COALESCED stream the readers saw:
//     - minute has >= 1 hrSample row: median over (hr values + PPG values at seconds with no hr row,
//       rounded to whole bpm, exactly the reader's CAST(ROUND(bpm))); ONE hrSample row at the minute
//       start; ALL ppgHrSample rows of that minute are deleted. (Provenance rule: the estimate that
//       filled a gap is folded into the measured minute value, as the readers already did.)
//     - minute has ONLY ppgHrSample rows (a PPG-only WHOOP 5 night): median bpm (REAL), the MINIMUM conf
//       of the minute (the readers' MIN(conf) "weakest signal" rule), ONE ppgHrSample row at the minute
//       start. It stays a ppgHrSample row, so a PPG-only night is never relabelled "measured".
//
// SAFETY PROPERTIES
//   * One transaction per <= 1 UTC day window (86 400 s, minute-aligned, all devices of that window). A kill
//     between windows leaves a consistent database: finished windows are minute-resolution, the rest are
//     untouched. A transaction that throws rolls back completely.
//   * The effective cutoff is rounded DOWN to a whole minute, so a minute is never half-compacted.
//   * Idempotent: a minute that is already exactly one row stamped at its minute start (and has no PPG
//     rows to fold in) is "already compact" and is not rewritten; a re-run removes 0 rows.
//   * Inside each transaction the post-write row count is checked against the plan; any mismatch throws and
//     rolls the window back.
//   * Refuses a cutoff newer than `minimumAgeSeconds` (14 days): the scoring engine re-reads the last 21 days
//     at full resolution and live screens read today. The app only offers 30+ days, this is a backstop.
//   * `dryRun` runs the SAME plan code in a read transaction and writes nothing, so its counts equal what a
//     real run removes (a test pins this).
//   * After a real run that removed rows the WAL is checkpointed/truncated with the existing
//     `checkpointWAL()`. Deleting rows does NOT shrink the main file (freed pages go to SQLite's free list and
//     are reused by new data); only `reclaimSpace()` (VACUUM) returns them to the OS, and it is never run
//     automatically.

/// A refusal raised before or during compaction. All are non-destructive: a thrown error means the current
/// window was rolled back.
public enum StreamCompactionError: Error, Equatable {
    /// The cutoff is newer than `StreamCompaction.minimumAgeSeconds` before `now`.
    case cutoffTooRecent
    /// The post-write verification of a window did not match the plan (window rolled back).
    case verificationFailed(table: String)
}

/// What a compaction (or a dry run of it) removed / would remove.
public struct StreamCompactionReport: Sendable, Equatable {
    public var dryRun: Bool
    /// Net rows removed from hrSample (rows before minus rows after).
    public var hrRowsRemoved: Int
    /// Net rows removed from ppgHrSample.
    public var ppgRowsRemoved: Int
    /// Minute rows that exist after the run in the processed range (hr + ppg), for information.
    public var minuteRowsKept: Int
    /// Windows (<= 1 day each) that held at least one row.
    public var windowsWithData: Int
    /// Windows examined in total (progress denominator).
    public var windowsTotal: Int
    /// The (minute-aligned) cutoff up to which every window finished; nil if no window finished.
    /// The app records this as "last compacted cutoff" ONLY when `finished && !dryRun`.
    public var completedUpTo: Int?
    /// True when the run examined every window up to the cutoff (not cancelled).
    public var finished: Bool
    /// Rough bytes the removed rows occupied (table cell + the (deviceId, ts) autoindex entry). An ESTIMATE:
    /// the file itself only shrinks after `reclaimSpace()`.
    public var estimatedBytes: Int64

    public var rowsRemoved: Int { hrRowsRemoved + ppgRowsRemoved }

    public init(dryRun: Bool, hrRowsRemoved: Int = 0, ppgRowsRemoved: Int = 0, minuteRowsKept: Int = 0,
                windowsWithData: Int = 0, windowsTotal: Int = 0, completedUpTo: Int? = nil,
                finished: Bool = false, estimatedBytes: Int64 = 0) {
        self.dryRun = dryRun
        self.hrRowsRemoved = hrRowsRemoved
        self.ppgRowsRemoved = ppgRowsRemoved
        self.minuteRowsKept = minuteRowsKept
        self.windowsWithData = windowsWithData
        self.windowsTotal = windowsTotal
        self.completedUpTo = completedUpTo
        self.finished = finished
        self.estimatedBytes = estimatedBytes
    }
}

/// Result of `reclaimSpace()`.
public enum ReclaimOutcome: Sendable, Equatable {
    /// VACUUM ran. Sizes are file + -wal + -shm bytes before and after.
    case reclaimed(before: Int64, after: Int64)
    /// Not enough free disk space for VACUUM's temporary copy (needs >= the database size). Nothing ran.
    case notEnoughFreeSpace(needed: Int64, available: Int64)
    /// SQLite's own quick check found a problem; nothing ran. The string is SQLite's first complaint.
    case integrityProblem(String)
    /// In-memory store, or the free space could not be determined (nothing ran: unknown = refuse).
    case unavailable
}

public enum StreamCompaction {
    /// A cutoff newer than this many seconds before `now` is refused.
    public static let minimumAgeSeconds = 14 * 86_400
    /// Window size: one UTC day, a multiple of 60 so minutes never straddle windows.
    public static let windowSeconds = 86_400
    /// Rough per-row storage estimates for the dry run (table cell + autoindex entry + page overhead).
    public static let estimatedBytesPerHrRow: Int64 = 30
    public static let estimatedBytesPerPpgRow: Int64 = 40

    /// Round `ts` down to its minute start (correct for negative values too).
    public static func minuteFloor(_ ts: Int) -> Int {
        ts - (((ts % 60) + 60) % 60)
    }

    /// Median of an ASCENDING-sorted, non-empty list: odd -> middle; even -> mean of the two middle values
    /// rounded half-up. Precondition: `sorted` is non-empty and sorted.
    public static func medianInt(sorted: [Int]) -> Int {
        let n = sorted.count
        if n % 2 == 1 { return sorted[n / 2] }
        return (sorted[n / 2 - 1] + sorted[n / 2] + 1) / 2
    }

    static func medianDouble(sorted: [Double]) -> Double {
        let n = sorted.count
        if n % 2 == 1 { return sorted[n / 2] }
        return (sorted[n / 2 - 1] + sorted[n / 2]) / 2.0
    }

    // MARK: Pure plan (no database)

    struct HrPoint: Equatable { var ts: Int; var bpm: Int }
    struct PpgPoint: Equatable { var ts: Int; var bpm: Double; var conf: Double }

    /// The new rows of one (device, window) and whether each table needs rewriting.
    struct Plan: Equatable {
        var hr: [HrPoint] = []
        var ppg: [PpgPoint] = []
        var hrChanged = false
        var ppgChanged = false
    }

    /// Pure: what the window's rows become. `hr` / `ppg` are every row of ONE device inside ONE minute-aligned
    /// window (any order). See the file header for the rule.
    static func plan(hr: [HrPoint], ppg: [PpgPoint]) -> Plan {
        var hrByMinute: [Int: [HrPoint]] = [:]
        for p in hr { hrByMinute[minuteFloor(p.ts), default: []].append(p) }
        var ppgByMinute: [Int: [PpgPoint]] = [:]
        for p in ppg where p.bpm.isFinite && p.conf.isFinite {
            ppgByMinute[minuteFloor(p.ts), default: []].append(p)
        }
        let minutes = Set(hrByMinute.keys).union(ppgByMinute.keys).sorted()
        var out = Plan()
        for m in minutes {
            let h = hrByMinute[m] ?? []
            let p = ppgByMinute[m] ?? []
            if !h.isEmpty {
                let hrTs = Set(h.map { $0.ts })
                var values = h.map { $0.bpm }
                for q in p where !hrTs.contains(q.ts) { values.append(Int(q.bpm.rounded())) }
                values.sort()
                out.hr.append(HrPoint(ts: m, bpm: medianInt(sorted: values)))
                let alreadyCompact = h.count == 1 && h[0].ts == m && p.isEmpty
                if !alreadyCompact { out.hrChanged = true }
                if !p.isEmpty { out.ppgChanged = true }   // folded into the minute row -> deleted
            } else if !p.isEmpty {
                let alreadyCompact = p.count == 1 && p[0].ts == m
                if alreadyCompact {
                    out.ppg.append(p[0])
                } else {
                    let bpms = p.map { $0.bpm }.sorted()
                    let conf = p.map { $0.conf }.min() ?? 0
                    out.ppg.append(PpgPoint(ts: m, bpm: medianDouble(sorted: bpms), conf: conf))
                    out.ppgChanged = true
                }
            }
        }
        // hr rows whose minute has hr are kept via out.hr; hr rows can never be dropped for a minute
        // without a replacement, so if nothing changed the planned rows equal the stored rows.
        return out
    }

    // MARK: One window (all devices) inside an open transaction

    struct WindowResult {
        var hrRemoved = 0
        var ppgRemoved = 0
        var kept = 0
        var hadData = false
    }

    /// Process `[from, to)` for every device inside the caller's transaction. `from` and `to` MUST be multiples
    /// of 60. When `dryRun` is true nothing is written.
    static func processWindow(_ db: Database, devices: [String], from: Int, to: Int,
                              dryRun: Bool) throws -> WindowResult {
        var result = WindowResult()
        for dev in devices {
            var hrRows: [HrPoint] = []
            for r in try Row.fetchAll(db, sql: """
                SELECT ts, bpm FROM hrSample
                WHERE deviceId = ? AND ts >= ? AND ts < ?
                ORDER BY ts
                """, arguments: [dev, from, to]) {
                let ts: Int = r["ts"]
                let bpm: Int = r["bpm"]
                hrRows.append(HrPoint(ts: ts, bpm: bpm))
            }
            var ppgRows: [PpgPoint] = []
            for r in try Row.fetchAll(db, sql: """
                SELECT ts, bpm, conf FROM ppgHrSample
                WHERE deviceId = ? AND ts >= ? AND ts < ?
                ORDER BY ts
                """, arguments: [dev, from, to]) {
                let ts: Int = r["ts"]
                let bpm: Double = r["bpm"]
                let conf: Double = r["conf"]
                ppgRows.append(PpgPoint(ts: ts, bpm: bpm, conf: conf))
            }
            if hrRows.isEmpty && ppgRows.isEmpty { continue }
            result.hadData = true

            let plan = StreamCompaction.plan(hr: hrRows, ppg: ppgRows)
            result.kept += plan.hr.count + plan.ppg.count

            if plan.hrChanged {
                result.hrRemoved += hrRows.count - plan.hr.count
                if !dryRun {
                    try db.execute(sql: """
                        DELETE FROM hrSample WHERE deviceId = ? AND ts >= ? AND ts < ?
                        """, arguments: [dev, from, to])
                    for p in plan.hr {
                        try db.execute(sql: "INSERT INTO hrSample (deviceId, ts, bpm) VALUES (?, ?, ?)",
                                       arguments: [dev, p.ts, p.bpm])
                    }
                    let after = try Int.fetchOne(db, sql: """
                        SELECT COUNT(*) FROM hrSample WHERE deviceId = ? AND ts >= ? AND ts < ?
                        """, arguments: [dev, from, to]) ?? -1
                    if after != plan.hr.count { throw StreamCompactionError.verificationFailed(table: "hrSample") }
                }
            }
            if plan.ppgChanged {
                result.ppgRemoved += ppgRows.count - plan.ppg.count
                if !dryRun {
                    try db.execute(sql: """
                        DELETE FROM ppgHrSample WHERE deviceId = ? AND ts >= ? AND ts < ?
                        """, arguments: [dev, from, to])
                    for p in plan.ppg {
                        try db.execute(sql: """
                            INSERT INTO ppgHrSample (deviceId, ts, bpm, conf) VALUES (?, ?, ?, ?)
                            """, arguments: [dev, p.ts, p.bpm, p.conf])
                    }
                    let after = try Int.fetchOne(db, sql: """
                        SELECT COUNT(*) FROM ppgHrSample WHERE deviceId = ? AND ts >= ? AND ts < ?
                        """, arguments: [dev, from, to]) ?? -1
                    if after != plan.ppg.count { throw StreamCompactionError.verificationFailed(table: "ppgHrSample") }
                }
            }
        }
        return result
    }
}

extension WhoopStore {

    /// Thin hrSample / ppgHrSample rows older than `cutoff` to one row per device per minute. See the file
    /// header for the exact rule and the safety properties.
    ///
    /// - Parameters:
    ///   - cutoff: unix seconds; rows with `ts < cutoff` (rounded down to a whole minute) are compacted. The
    ///     app passes a LOCAL-midnight cutoff so every local day is either fully compacted or untouched.
    ///   - skipBefore: optional lower bound; rows with `ts < skipBefore` are not examined (the app's
    ///     "last compacted cutoff", used by the automatic daily run only). Manual runs pass nil so rows that
    ///     arrived late (a strap history sync, an import) are also compacted.
    ///   - dryRun: count only, write nothing.
    ///   - now: injectable clock (unix seconds) for the minimum-age guard.
    ///   - progress: called after each window with (windowsDone, windowsTotal). Invoked on the store actor.
    public func compactOldStreams(cutoff: Int, skipBefore: Int? = nil, dryRun: Bool = false,
                                  now: Int = Int(Date().timeIntervalSince1970),
                                  progress: (@Sendable (Int, Int) -> Void)? = nil) async throws
        -> StreamCompactionReport {
        let alignedCutoff = StreamCompaction.minuteFloor(cutoff)
        guard alignedCutoff <= now - StreamCompaction.minimumAgeSeconds else {
            throw StreamCompactionError.cutoffTooRecent
        }
        let lower = max(0, skipBefore ?? 0)
        // A minute is never split: round the lower bound UP to a whole minute.
        let alignedLower = lower % 60 == 0 ? lower : StreamCompaction.minuteFloor(lower) + 60

        let devices: [String] = try syncRead { db in
            try String.fetchAll(db, sql: """
                SELECT DISTINCT deviceId FROM hrSample
                UNION
                SELECT DISTINCT deviceId FROM ppgHrSample
                """).sorted()
        }
        var report = StreamCompactionReport(dryRun: dryRun)
        guard !devices.isEmpty, lower < alignedCutoff else {
            report.finished = true
            report.completedUpTo = alignedCutoff
            return report
        }

        // Lowest row timestamp inside [lower, cutoff) across devices and both tables (index range probes).
        let lowest: Int? = try syncRead { db in
            var best: Int? = nil
            for dev in devices {
                for table in ["hrSample", "ppgHrSample"] {
                    let v = try Int.fetchOne(db, sql: """
                        SELECT MIN(ts) FROM \(table) WHERE deviceId = ? AND ts >= ? AND ts < ?
                        """, arguments: [dev, lower, alignedCutoff])
                    if let v = v, best == nil || v < best! { best = v }
                }
            }
            return best
        }
        guard let lowestTs = lowest else {
            report.finished = true
            report.completedUpTo = alignedCutoff
            return report
        }

        let w = StreamCompaction.windowSeconds
        let firstWindow = lowestTs - (((lowestTs % w) + w) % w)
        let total = (alignedCutoff - firstWindow + w - 1) / w
        report.windowsTotal = total

        var windowStart = firstWindow
        var done = 0
        var cancelled = false
        while windowStart < alignedCutoff {
            if Task.isCancelled { cancelled = true; break }
            let windowEnd = min(windowStart + w, alignedCutoff)
            let lo = max(windowStart, alignedLower)
            let res: StreamCompaction.WindowResult
            if lo >= windowEnd {
                res = StreamCompaction.WindowResult()
            } else if dryRun {
                res = try syncRead { db in
                    try StreamCompaction.processWindow(db, devices: devices, from: lo, to: windowEnd,
                                                       dryRun: true)
                }
            } else {
                res = try syncWrite { db in
                    try StreamCompaction.processWindow(db, devices: devices, from: lo, to: windowEnd,
                                                       dryRun: false)
                }
            }
            report.hrRowsRemoved += res.hrRemoved
            report.ppgRowsRemoved += res.ppgRemoved
            report.minuteRowsKept += res.kept
            if res.hadData { report.windowsWithData += 1 }
            report.completedUpTo = windowEnd
            done += 1
            progress?(done, total)
            windowStart = windowEnd
            // Let other callers of this actor (live reads, the Collector's writes) in between windows.
            await Task.yield()
        }
        report.finished = !cancelled
        if !cancelled { report.completedUpTo = alignedCutoff }
        report.estimatedBytes = Int64(report.hrRowsRemoved) * StreamCompaction.estimatedBytesPerHrRow
            + Int64(report.ppgRowsRemoved) * StreamCompaction.estimatedBytesPerPpgRow
        if !dryRun && report.rowsRemoved > 0 {
            try await checkpointWAL()
        }
        return report
    }

    /// Bytes SQLite holds in its free list (pages freed by deletes but not yet returned to the OS). This is
    /// what `reclaimSpace()` can give back. nil if SQLite did not answer.
    public func reclaimableBytes() async -> Int64? {
        do {
            let pages: Int = try syncRead { db in try Int.fetchOne(db, sql: "PRAGMA freelist_count") ?? 0 }
            let size: Int = try syncRead { db in try Int.fetchOne(db, sql: "PRAGMA page_size") ?? 4096 }
            return Int64(pages) * Int64(size)
        } catch {
            return nil
        }
    }

    /// Free bytes on the volume holding `path` (important-usage capacity first, then plain capacity).
    public static func defaultAvailableBytes(forPath path: String) -> Int64? {
        let url = URL(fileURLWithPath: path).deletingLastPathComponent()
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey,
                                                              .volumeAvailableCapacityKey]) else { return nil }
        if let important = values.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        if let plain = values.volumeAvailableCapacity { return Int64(plain) }
        return nil
    }

    /// Run VACUUM so deleted pages are returned to the OS. EXPLICIT ONLY, never called automatically.
    ///
    /// VACUUM writes a temporary copy of the whole database, so it is refused unless the volume has at least
    /// the database's current size (file + WAL) free. An unknown free size is treated as "not enough". A
    /// SQLite `quick_check` runs first and a problem aborts. `availableBytes` is injectable for tests.
    public func reclaimSpace(availableBytes: (@Sendable (String) -> Int64?)? = nil) async throws
        -> ReclaimOutcome {
        let path = dbWriter.path
        guard path != ":memory:", !path.isEmpty else { return .unavailable }
        guard let before = await databaseFileSizeBytes() else { return .unavailable }
        let available: Int64
        if let injected = availableBytes {
            guard let v = injected(path) else { return .unavailable }
            available = v
        } else {
            guard let v = WhoopStore.defaultAvailableBytes(forPath: path) else { return .unavailable }
            available = v
        }
        guard available >= before else { return .notEnoughFreeSpace(needed: before, available: available) }

        try await checkpointWAL()
        if let complaint = DatabaseIntegrity.quickCheckFailure(atPath: path) {
            return .integrityProblem(complaint)
        }
        try vacuumImpl()
        try await checkpointWAL()
        let after = await databaseFileSizeBytes() ?? before
        return .reclaimed(before: before, after: after)
    }

    /// Non-async so GRDB's synchronous `writeWithoutTransaction` overload is chosen (VACUUM cannot run inside
    /// a transaction), the same shape as `checkpointWALImpl`.
    private func vacuumImpl() throws {
        try dbWriter.writeWithoutTransaction { db in
            try db.execute(sql: "VACUUM")
        }
    }
}
