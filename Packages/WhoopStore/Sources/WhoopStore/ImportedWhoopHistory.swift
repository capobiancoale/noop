import Foundation
import GRDB

// MARK: - Remove the history imported from a WHOOP data export
//
// The WHOOP export importer (`WhoopImporter` in the app) writes into FIVE tables under the canonical
// strap id ("my-whoop"): `dailyMetric`, `metricSeries`, `sleepSession`, `workout` and `journal`. Nothing
// else writes `dailyMetric` or `journal` under that id (NOOP's own scores live under "my-whoop-noop", native
// journal answers under "noop-journal", Apple Health under "apple-health"), so those two tables are
// imported-only for the canonical id. The other three share the id with rows the user or the app made, and
// are narrowed like this:
//
//   metricSeries  only the keys `WhoopImporter` writes (`importedMetricSeriesKeys`). User series stored
//                 under the same id (the sleep-mark series "sleep_mark") use other keys and stay.
//   sleepSession  only `userEdited = 0`. A night the user corrected, or added by hand, stays.
//   workout       only `source = 'whoop'` (the importer's literal). "manual" rows (live sessions, added or
//                 edited workouts), Apple, lifting and activity-file rows stay.
//
// NEVER touched: every per-second stream (hrSample, rrInterval, spo2Sample, skinTempSample, respSample,
// gravitySample, stepSample, ppgHrSample, strapSpo2Sample, sleepStateSample), event, battery, rawBatch,
// cursors, the device registry, wodLog, labMarker, appleDaily, dayOwnership, and every row stored under a
// different `deviceId` ("my-whoop-noop", "apple-health", ...). A `deviceId` that is a computed twin
// ("...-noop") is refused outright so a wrong argument can never wipe what NOOP computed.
//
// This is NOT `deleteAllData(deviceId:)`, which empties 18 tables for the id, including the strap's live
// recordings.

/// What the imported WHOOP history holds (a dry run) or what a removal deleted (the result of the delete).
public struct ImportedWhoopHistoryCounts: Equatable, Sendable {
    public var dailyMetrics: Int
    public var metricSeries: Int
    public var sleepSessions: Int
    public var workouts: Int
    public var journalEntries: Int
    /// Earliest / latest local day (`yyyy-MM-dd`) across the counted rows, nil when there are none. Only
    /// filled by the dry run; a delete result reports the range of what it removed too.
    public var firstDay: String?
    public var lastDay: String?

    public init(dailyMetrics: Int = 0, metricSeries: Int = 0, sleepSessions: Int = 0, workouts: Int = 0,
                journalEntries: Int = 0, firstDay: String? = nil, lastDay: String? = nil) {
        self.dailyMetrics = dailyMetrics; self.metricSeries = metricSeries
        self.sleepSessions = sleepSessions; self.workouts = workouts
        self.journalEntries = journalEntries; self.firstDay = firstDay; self.lastDay = lastDay
    }

    public var total: Int { dailyMetrics + metricSeries + sleepSessions + workouts + journalEntries }
    public var isEmpty: Bool { total == 0 }
}

public enum ImportedWhoopHistoryError: Error, Equatable {
    /// The id is empty, or a computed twin ("...-noop"). Nothing was read or deleted.
    case refusedDeviceId(String)
}

extension WhoopStore {

    /// The metricSeries keys the WHOOP export importer writes (`WhoopImporter.importExport`): the cycle
    /// fields, the derived restorative / stress / HR-zone series and the strength minutes. Constants, so they
    /// are embedded in the SQL as literals (no user input reaches the statement).
    static let importedMetricSeriesKeys: [String] = [
        "recovery", "strain", "rhr", "hrv", "spo2", "skin_temp", "resp_rate", "energy_kcal",
        "avg_hr", "max_hr", "sleep_total_min", "in_bed_min", "sleep_deep_min", "sleep_rem_min",
        "sleep_light_min", "awake_min", "sleep_efficiency", "sleep_performance", "sleep_consistency",
        "sleep_need_min", "sleep_debt_min", "restorative_min", "restorative_pct", "hours_vs_needed_pct",
        "stress", "hr_zone1_min", "hr_zone2_min", "hr_zone3_min", "hr_zone4_min", "hr_zone5_min",
        "hr_zones13_min", "hr_zones45_min", "hr_zones_all_min", "strength_min",
    ]

    /// SQL fragment `('recovery','strain',...)` for the key list above.
    private static var importedKeysSQLList: String {
        "(" + importedMetricSeriesKeys.map { "'\($0)'" }.joined(separator: ",") + ")"
    }

    // The predicates. One definition each, shared by the count and the delete so they can never drift.
    private static let importedDailyWhere = "deviceId = :dev"
    private static var importedSeriesWhere: String { "deviceId = :dev AND key IN \(importedKeysSQLList)" }
    private static let importedSleepWhere = "deviceId = :dev AND userEdited = 0"
    private static let importedWorkoutWhere = "deviceId = :dev AND lower(source) = 'whoop'"
    private static let importedJournalWhere = "deviceId = :dev"

    private static func checkImportedHistoryId(_ deviceId: String) throws {
        let id = deviceId.trimmingCharacters(in: .whitespaces)
        if id.isEmpty || id.lowercased().hasSuffix("-noop") {
            throw ImportedWhoopHistoryError.refusedDeviceId(deviceId)
        }
    }

    /// Dry run: how many imported WHOOP rows exist under `deviceId` (the canonical "my-whoop"), with the same
    /// predicates `deleteImportedWhoopHistory` uses. Writes nothing.
    public func countImportedWhoopHistory(deviceId: String) async throws -> ImportedWhoopHistoryCounts {
        try Self.checkImportedHistoryId(deviceId)
        return try syncRead { db in try Self.importedHistoryCounts(db, deviceId: deviceId) }
    }

    /// Delete the imported WHOOP rows under `deviceId` in ONE transaction (all or nothing) and return how many
    /// rows went, per table. See the file header for exactly what is and is not deleted. Idempotent: a second
    /// call finds nothing and returns zeros. The caller must refresh its caches afterwards.
    @discardableResult
    public func deleteImportedWhoopHistory(deviceId: String) async throws -> ImportedWhoopHistoryCounts {
        try Self.checkImportedHistoryId(deviceId)
        return try syncWrite { db in
            // The range comes from the rows about to go, read inside the same transaction as the delete.
            let before = try Self.importedHistoryCounts(db, deviceId: deviceId)
            var out = ImportedWhoopHistoryCounts(firstDay: before.firstDay, lastDay: before.lastDay)
            let args: StatementArguments = ["dev": deviceId]
            try db.execute(sql: "DELETE FROM dailyMetric WHERE \(Self.importedDailyWhere)", arguments: args)
            out.dailyMetrics = db.changesCount
            try db.execute(sql: "DELETE FROM metricSeries WHERE \(Self.importedSeriesWhere)", arguments: args)
            out.metricSeries = db.changesCount
            try db.execute(sql: "DELETE FROM sleepSession WHERE \(Self.importedSleepWhere)", arguments: args)
            out.sleepSessions = db.changesCount
            try db.execute(sql: "DELETE FROM workout WHERE \(Self.importedWorkoutWhere)", arguments: args)
            out.workouts = db.changesCount
            try db.execute(sql: "DELETE FROM journal WHERE \(Self.importedJournalWhere)", arguments: args)
            out.journalEntries = db.changesCount
            return out
        }
    }

    private static func importedHistoryCounts(_ db: Database, deviceId: String) throws -> ImportedWhoopHistoryCounts {
        let args: StatementArguments = ["dev": deviceId]
        var c = ImportedWhoopHistoryCounts()
        c.dailyMetrics = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM dailyMetric WHERE \(importedDailyWhere)",
                                          arguments: args) ?? 0
        c.metricSeries = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM metricSeries WHERE \(importedSeriesWhere)",
                                          arguments: args) ?? 0
        c.sleepSessions = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sleepSession WHERE \(importedSleepWhere)",
                                           arguments: args) ?? 0
        c.workouts = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM workout WHERE \(importedWorkoutWhere)",
                                      arguments: args) ?? 0
        c.journalEntries = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM journal WHERE \(importedJournalWhere)",
                                            arguments: args) ?? 0
        if c.total > 0 {
            if let row = try Row.fetchOne(db, sql: """
                SELECT MIN(d) AS lo, MAX(d) AS hi FROM (
                    SELECT day AS d FROM dailyMetric WHERE \(importedDailyWhere)
                    UNION ALL SELECT day FROM metricSeries WHERE \(importedSeriesWhere)
                    UNION ALL SELECT date(startTs, 'unixepoch', 'localtime') FROM sleepSession WHERE \(importedSleepWhere)
                    UNION ALL SELECT date(startTs, 'unixepoch', 'localtime') FROM workout WHERE \(importedWorkoutWhere)
                    UNION ALL SELECT day FROM journal WHERE \(importedJournalWhere)
                )
                """, arguments: args) {
                let lo: String? = row["lo"]
                let hi: String? = row["hi"]
                c.firstDay = lo
                c.lastDay = hi
            }
        }
        return c
    }
}
