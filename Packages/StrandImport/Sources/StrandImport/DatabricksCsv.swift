import Foundation
import WhoopStore

/// Flat CSV tables for the "NOOP to Databricks" export: sport and sleep summaries ONLY.
///
/// The builders are pure. They take rows the app already gathered and return CSV text, so the whole
/// contract (headers, quoting, number and date formats, the metric allowlist) is pinned by
/// DatabricksCsvTests rather than by hoping the app code stays tidy.
///
/// What is exported is an explicit ALLOWLIST, never a denylist: the six tables below carry only the
/// columns listed here, and `metricAllowlist` names the one set of metric-series keys that may leave
/// the device. Glucose, insulin, carbs and other nutrition, blood pressure, weight and body
/// composition, mood, irregular-rhythm screening, journal answers, workout/WOD/movement notes and every
/// per-second raw stream are not representable in these tables, whatever the store holds.
///
/// Format rules shared by every table:
///  - first line is the header (snake_case); fields use WhoopCsvExporter's RFC 4180 quoting;
///  - numbers print with a "." decimal separator and no thousands separator, whatever the user's
///    locale; nil is an empty field; booleans are `true` / `false`;
///  - every row carries `export_ts`, the export moment in ISO 8601 UTC, the same on every row of one
///    export. Each upload is a NEW file, and the Databricks side keeps the row with the newest
///    `export_ts` per key, so an edited night or a corrected WOD simply supersedes its older version;
///  - local date-times are `yyyy-MM-dd HH:mm:ss` in the time zone passed in (the device's);
///  - lines end with "\n" (Spark reads that, "\r\n" and "\r" alike; one terminator keeps a stray CR out
///    of the last column for simpler readers).
public enum DatabricksCsv {

    // MARK: - Tables and file names

    /// The tables of one export, in the order they are written.
    public static let tables: [String] = ["days", "sleeps", "workouts", "wods", "wod_movements", "metrics"]

    /// `<table>__yyyyMMdd-HHmmss.csv` in local time. The timestamp keeps every upload a new file (the
    /// history lives on Databricks), and the double underscore lets one glob per table
    /// (`days__*.csv`) match its own files only (`wods__*` never matches `wod_movements__*`).
    public static func fileName(table: String, exportedAt: Date, timeZone: TimeZone) -> String {
        let clock = LocalClock(timeZone: timeZone)
        let ts = Int(exportedAt.timeIntervalSince1970)
        let day = clock.day(ts).replacingOccurrences(of: "-", with: "")
        let time = clock.time(ts).replacingOccurrences(of: ":", with: "")
        return "\(table)__\(day)-\(time).csv"
    }

    /// The export moment as ISO 8601 UTC (`2026-11-02T09:00:00Z`).
    public static func exportStamp(_ date: Date) -> String {
        let clock = LocalClock(timeZone: LocalClock.utc)
        let ts = Int(date.timeIntervalSince1970)
        return clock.day(ts) + "T" + clock.time(ts) + "Z"
    }

    /// Values of the `source` column: where a row came from. `noop` = computed on the device from the
    /// strap's own streams, `import` = a WHOOP export or another import, `manual` = logged by hand.
    public static let sourceNoop = "noop"
    public static let sourceImport = "import"
    public static let sourceManual = "manual"

    // MARK: - Local clock (calendar maths without formatters)

    /// Local calendar day and time of a unix timestamp in a fixed time zone. Built on `Calendar`
    /// components rather than `DateFormatter`: it is a `Sendable` value, cheap to create, and its output
    /// cannot be bent by the user's locale or calendar (a Buddhist-calendar phone still gets year 2026).
    public struct LocalClock: Sendable {
        private let calendar: Calendar

        /// UTC, for `export_ts`.
        static let utc: TimeZone = TimeZone(secondsFromGMT: 0) ?? TimeZone(identifier: "GMT") ?? TimeZone.current

        public init(timeZone: TimeZone) {
            var c = Calendar(identifier: .gregorian)
            c.timeZone = timeZone
            calendar = c
        }

        private static func pad(_ value: Int, _ width: Int) -> String {
            let s = String(value)
            guard s.count < width else { return s }
            return String(repeating: "0", count: width - s.count) + s
        }

        /// `yyyy-MM-dd` of the local day the timestamp falls on.
        public func day(_ ts: Int) -> String {
            let c = calendar.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: TimeInterval(ts)))
            let y = Self.pad(c.year ?? 0, 4)
            let m = Self.pad(c.month ?? 0, 2)
            let d = Self.pad(c.day ?? 0, 2)
            return "\(y)-\(m)-\(d)"
        }

        /// `HH:mm:ss` of the local time.
        public func time(_ ts: Int) -> String {
            let c = calendar.dateComponents([.hour, .minute, .second], from: Date(timeIntervalSince1970: TimeInterval(ts)))
            let h = Self.pad(c.hour ?? 0, 2)
            let m = Self.pad(c.minute ?? 0, 2)
            let s = Self.pad(c.second ?? 0, 2)
            return "\(h):\(m):\(s)"
        }

        /// `yyyy-MM-dd HH:mm:ss`.
        public func dateTime(_ ts: Int) -> String { day(ts) + " " + time(ts) }

        /// Start of the oldest local day of a "last `days` days, today included" window: `days = 1` is
        /// today's midnight, `days = 14` is 13 midnights back. Values below 1 count as 1.
        public func windowStart(now: Date, days: Int) -> Date {
            let today = calendar.startOfDay(for: now)
            let back = -(max(days, 1) - 1)
            return calendar.date(byAdding: .day, value: back, to: today) ?? today
        }
    }

    // MARK: - Metric series allowlist

    /// The metric-series keys that may be exported (the `metrics` table, and the `rest` column of
    /// `days`). Anything else in the store is dropped, so a glucose, insulin, nutrition, blood-pressure,
    /// weight, mood or irregular-rhythm series can never ride along by accident.
    public static let metricAllowlist: Set<String> = [
        "vo2max_est", "vo2max_exercise", "fitness_age", "body_age", "vitality",
        "sleep_performance", "sleep_consistency", "sleep_need_min", "sleep_debt_min", "sleep_total_min",
        "sleep_efficiency", "sleep_deep_min", "sleep_rem_min", "sleep_light_min", "in_bed_min",
        "awake_min", "restorative_min", "restorative_pct", "hours_vs_needed_pct",
        "recovery", "strain", "stress", "hrv", "rhr", "resp_rate", "spo2", "skin_temp",
        "avg_hr", "max_hr", "energy_kcal", "steps_est",
        "hr_zones13_min", "hr_zones45_min", "hr_zones_all_min", "strength_min",
    ]

    /// One metric-series point with where it came from.
    public struct SourcedPoint: Equatable, Sendable {
        public let point: MetricPoint
        public let source: String
        public init(point: MetricPoint, source: String) { self.point = point; self.source = source }
    }

    /// Imported plus on-device points, one per (day, key) with the import winning (the same precedence
    /// the dashboards use), keeping only allowlisted keys and finite values, sorted by day then key.
    public static func mergeSeries(imported: [MetricPoint], computed: [MetricPoint]) -> [SourcedPoint] {
        var merged: [String: SourcedPoint] = [:]
        for p in computed where metricAllowlist.contains(p.key) && p.value.isFinite {
            merged["\(p.day)|\(p.key)"] = SourcedPoint(point: p, source: sourceNoop)
        }
        for p in imported where metricAllowlist.contains(p.key) && p.value.isFinite {
            merged["\(p.day)|\(p.key)"] = SourcedPoint(point: p, source: sourceImport)
        }
        return merged.values.sorted { ($0.point.day, $0.point.key) < ($1.point.day, $1.point.key) }
    }

    // MARK: - Field formatting

    /// Free text as one CSV field: line breaks and surrounding blanks become plain spaces (a multi-line
    /// title would otherwise split a row for readers that do not parse quoted newlines), then
    /// WhoopCsvExporter's quoting.
    private static func text(_ raw: String?) -> String {
        guard let raw else { return "" }
        let flat = String(raw.map { $0.isNewline ? " " : $0 })
        return WhoopCsvExporter.field(flat.trimmingCharacters(in: .whitespaces))
    }

    private static func fmt(_ v: Double?) -> String {
        guard let v, v.isFinite else { return "" }
        return WhoopCsvExporter.num(v)
    }

    private static func fmtInt(_ v: Int?) -> String { WhoopCsvExporter.num(v) }

    /// Minutes with at most two decimals: a zone split computed from seconds would otherwise print as
    /// 12.333333333333334.
    private static func fmtMin(_ v: Double?) -> String {
        guard let v, v.isFinite else { return "" }
        return WhoopCsvExporter.num((v * 100).rounded() / 100)
    }

    /// Efficiency as a percentage. The strap stager stores a 0...1 fraction while imports store 0...100;
    /// `Repository` reads both with this same rule (a real efficiency never sits at or below 1 percent),
    /// so the column holds one unit for the charts.
    private static func fmtPercent(_ v: Double?) -> String {
        guard let v, v.isFinite else { return "" }
        return WhoopCsvExporter.num(v > 0 && v <= 1.0 ? v * 100.0 : v)
    }

    private static func fmtBool(_ v: Bool?) -> String {
        guard let v else { return "" }
        return v ? "true" : "false"
    }

    /// Five zone cells (Z1...Z5 minutes), all empty when the zones are unknown.
    private static func zoneCells(_ minutes: [Double]?) -> [String] {
        guard let minutes, minutes.count == 5 else { return Array(repeating: "", count: 5) }
        return minutes.map { fmtMin($0) }
    }

    private static func csv(_ columns: [String], _ rows: [[String]]) -> String {
        var out = columns.joined(separator: ",") + "\n"
        for row in rows { out += row.joined(separator: ",") + "\n" }
        return out
    }

    // MARK: - days

    static let daysColumns: [String] = [
        "day", "export_ts", "source", "charge", "effort", "rest", "total_sleep_min", "sleep_efficiency",
        "deep_min", "rem_min", "light_min", "disturbances", "resting_hr", "hrv_ms", "spo2_pct",
        "resp_rate_bpm", "skin_temp_dev_c", "steps", "active_kcal",
    ]

    /// One row per day: the imported row when there is one, else the on-device one (the CSV export's
    /// precedence). `rest` is the day's `sleep_performance` series value, taken from `series` (as built
    /// by `mergeSeries`), because the daily row itself does not carry the Rest score.
    public static func daysCSV(imported: [DailyMetric], computed: [DailyMetric],
                               series: [SourcedPoint], exportedAt: Date) -> String {
        var byDay: [String: DailyMetric] = [:]
        var sourceByDay: [String: String] = [:]
        for d in computed { byDay[d.day] = d; sourceByDay[d.day] = sourceNoop }
        for d in imported { byDay[d.day] = d; sourceByDay[d.day] = sourceImport }
        var rest: [String: Double] = [:]
        for p in series where p.point.key == "sleep_performance" { rest[p.point.day] = p.point.value }

        let stamp = exportStamp(exportedAt)
        var rows: [[String]] = []
        for d in byDay.values.sorted(by: { $0.day < $1.day }) {
            var r: [String] = [text(d.day), stamp, sourceByDay[d.day] ?? ""]
            r += [fmt(d.recovery), fmt(d.strain), fmt(rest[d.day])]
            r += [fmtMin(d.totalSleepMin), fmtPercent(d.efficiency)]
            r += [fmtMin(d.deepMin), fmtMin(d.remMin), fmtMin(d.lightMin), fmtInt(d.disturbances)]
            r += [fmtInt(d.restingHr), fmt(d.avgHrv), fmt(d.spo2Pct), fmt(d.respRateBpm)]
            r += [fmt(d.skinTempDevC), fmtInt(d.steps), fmt(d.activeKcalEst)]
            rows.append(r)
        }
        return csv(daysColumns, rows)
    }

    // MARK: - sleeps

    static let sleepsColumns: [String] = [
        "session_start_ts", "export_ts", "start_local", "end_local", "end_ts", "wake_day", "in_bed_min",
        "asleep_min", "efficiency", "deep_min", "rem_min", "light_min", "wake_min", "resting_hr", "hrv_ms",
        "edited", "source",
    ]

    /// Every sleep session (naps and nights alike), imported ones taking precedence per wake day
    /// (`SleepMerge`, the rule the CSV export and the dashboards share). `session_start_ts` is the
    /// session's immutable detected start: it is the key the Databricks side de-duplicates on, so an
    /// onset the user later corrects replaces the old row instead of adding a second night. The shown
    /// start (`start_local`) and `in_bed_min` use the corrected onset when there is one.
    /// `sinceDay` keeps only sessions whose wake day is on or after it (`yyyy-MM-dd`).
    public static func sleepsCSV(imported: [CachedSleepSession], computed: [CachedSleepSession],
                                 sinceDay: String? = nil, exportedAt: Date, timeZone: TimeZone) -> String {
        let clock = LocalClock(timeZone: timeZone)
        let merged = SleepMerge.merge(imported: imported, computed: computed, endDay: { clock.day($0.endTs) })
        let importedStarts = Set(imported.map { $0.startTs })
        let stamp = exportStamp(exportedAt)
        var rows: [[String]] = []
        for s in merged {
            let wakeDay = clock.day(s.endTs)
            if let sinceDay, wakeDay < sinceDay { continue }
            let start = s.effectiveStartTs
            let stages = WhoopCsvExporter.stageMinutes(s.stagesJSON)
            let inBed: Double? = s.endTs > start ? Double(s.endTs - start) / 60.0 : nil
            var r: [String] = [String(s.startTs), stamp, clock.dateTime(start), clock.dateTime(s.endTs)]
            r += [String(s.endTs), wakeDay, fmtMin(inBed), fmtMin(stages.asleep), fmtPercent(s.efficiency)]
            r += [fmtMin(stages.deep), fmtMin(stages.rem), fmtMin(stages.light), fmtMin(stages.awake)]
            r += [fmtInt(s.restingHr), fmt(s.avgHrv)]
            r += [fmtBool(s.userEdited || s.startTsAdjusted != nil)]
            r += [importedStarts.contains(s.startTs) ? sourceImport : sourceNoop]
            rows.append(r)
        }
        return csv(sleepsColumns, rows)
    }

    // MARK: - workouts

    static let workoutsColumns: [String] = [
        "workout_key", "export_ts", "start_local", "end_local", "start_ts", "end_ts", "day", "sport",
        "duration_min", "avg_hr", "max_hr", "kcal", "strain", "z1_min", "z2_min", "z3_min", "z4_min",
        "z5_min", "source",
    ]

    /// The natural key of a workout across exports: start time plus sport.
    public static func workoutKey(_ w: WorkoutRow) -> String { "\(w.startTs)|\(w.sport)" }

    /// Imported workouts first, then on-device ones, one per `workoutKey`: the same session can sit
    /// under both ids (a re-imported export plus a strap detection), and would otherwise count twice.
    public static func uniqueWorkouts(imported: [WorkoutRow], computed: [WorkoutRow]) -> [WorkoutRow] {
        var seen = Set<String>()
        return (imported + computed).filter { seen.insert(workoutKey($0)).inserted }
    }

    /// `zoneMinutes` is keyed by `workoutKey` and holds Z1...Z5 minutes; a workout without an entry
    /// (no heart rate in its window) exports empty zone cells. `computedId` is the on-device source id,
    /// used to label rows the strap detected (sport "detected") `noop`.
    public static func workoutsCSV(_ rows: [WorkoutRow], computedId: String, zoneMinutes: [String: [Double]],
                                   exportedAt: Date, timeZone: TimeZone) -> String {
        let clock = LocalClock(timeZone: timeZone)
        let stamp = exportStamp(exportedAt)
        var out: [[String]] = []
        for w in rows.sorted(by: { ($0.startTs, $0.sport) < ($1.startTs, $1.sport) }) {
            let durationS = w.durationS ?? Double(w.endTs - w.startTs)
            var r: [String] = [text(workoutKey(w)), stamp, clock.dateTime(w.startTs), clock.dateTime(w.endTs)]
            r += [String(w.startTs), String(w.endTs), clock.day(w.startTs), text(w.sport)]
            r += [fmtMin(durationS / 60.0), fmtInt(w.avgHr), fmtInt(w.maxHr), fmt(w.energyKcal), fmt(w.strain)]
            r += zoneCells(zoneMinutes[workoutKey(w)])
            r += [workoutSource(w, computedId: computedId)]
            out.append(r)
        }
        return csv(workoutsColumns, out)
    }

    private static func workoutSource(_ w: WorkoutRow, computedId: String) -> String {
        if w.source == "manual" { return sourceManual }
        if w.source == computedId || w.sport == "detected" { return sourceNoop }
        return sourceImport
    }

    // MARK: - wods and their movements

    static let wodsColumns: [String] = [
        "wod_id", "export_ts", "day", "start_local", "end_local", "title", "type", "format", "time_cap_s",
        "result_kind", "result_seconds", "result_rounds", "result_reps", "result_weight_kg", "rpe", "rx",
        "z1_min", "z2_min", "z3_min", "z4_min", "z5_min",
    ]

    /// One row per logged WOD. The free-text `notes` of the WOD and of its movements are NOT exported.
    /// `end_local` is set only when the user timed the whole session; `zoneMinutes` (keyed by WOD id,
    /// Z1...Z5) is computed by the caller over that session span, and a WOD without one exports empty
    /// zone cells.
    public static func wodsCSV(_ wods: [WodLogRow], zoneMinutes: [String: [Double]],
                               exportedAt: Date, timeZone: TimeZone) -> String {
        let clock = LocalClock(timeZone: timeZone)
        let stamp = exportStamp(exportedAt)
        var rows: [[String]] = []
        for w in wods.sorted(by: { ($0.ts, $0.id) < ($1.ts, $1.id) }) {
            let end: String = w.sessionSpan.map { clock.dateTime($0.end) } ?? ""
            var r: [String] = [text(w.id), stamp, text(w.day), clock.dateTime(w.ts), end]
            r += [text(w.title), text(w.type), text(w.format), fmtInt(w.timeCapS), w.resultKind.rawValue]
            r += [fmtInt(w.resultSeconds), fmtInt(w.resultRounds), fmtInt(w.resultReps)]
            r += [fmt(w.resultWeightKg), fmt(w.rpe), fmtBool(w.rx)]
            r += zoneCells(zoneMinutes[w.id])
            rows.append(r)
        }
        return csv(wodsColumns, rows)
    }

    static let wodMovementsColumns: [String] = [
        "wod_id", "export_ts", "day", "position", "movement", "reps", "scheme", "reps_done", "weight_kg",
        "rx_weight_kg",
    ]

    /// One row per movement of each WOD, `position` counting from 1 in the order logged.
    public static func wodMovementsCSV(_ wods: [WodLogRow], exportedAt: Date) -> String {
        let stamp = exportStamp(exportedAt)
        var rows: [[String]] = []
        for w in wods.sorted(by: { ($0.ts, $0.id) < ($1.ts, $1.id) }) {
            for (index, m) in w.movements.enumerated() {
                var r: [String] = [text(w.id), stamp, text(w.day), String(index + 1), text(m.name)]
                r += [fmtInt(m.reps), text(m.scheme), fmtInt(m.repsDone), fmt(m.weightKg), fmt(m.rxWeightKg)]
                rows.append(r)
            }
        }
        return csv(wodMovementsColumns, rows)
    }

    // MARK: - metrics

    static let metricsColumns: [String] = ["day", "key", "export_ts", "source", "value"]

    /// The allowlisted metric-series points. `series` normally comes from `mergeSeries`; the allowlist is
    /// applied again here so a caller that skips the merge still cannot export a key outside it.
    public static func metricsCSV(series: [SourcedPoint], exportedAt: Date) -> String {
        let stamp = exportStamp(exportedAt)
        var rows: [[String]] = []
        for p in series where metricAllowlist.contains(p.point.key) && p.point.value.isFinite {
            rows.append([text(p.point.day), text(p.point.key), stamp, p.source, fmt(p.point.value)])
        }
        return csv(metricsColumns, rows)
    }
}
