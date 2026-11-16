import Foundation
import WhoopProtocol
import WhoopStore
import StrandAnalytics
import StrandImport

/// Gathers the user's sport and sleep summaries from the on-device store and writes them as the six CSV
/// files Databricks reads (the exact columns, and what is never exported, live in
/// `StrandImport.DatabricksCsv`). Used by the Settings button and by the Shortcuts App Intent.
///
/// No UI and no `Repository`: the intent runs without any of the app's view models, so this reads straight
/// from a `WhoopStore`. Sources are gathered the way `CsvExport` does it, not through the dashboard merge:
/// imported rows under `deviceId` and on-device computed rows under `deviceId + "-noop"`, imports winning
/// per day; sleep through `SleepMerge`; workouts de-duplicated by start and sport; metric series from both
/// ids with the import winning per day and key.
///
/// Only an allowlist is read. The metric series are fetched key by key from `DatabricksCsv.metricAllowlist`
/// (a glucose, insulin, nutrition, blood-pressure, weight, mood or irregular-rhythm series is never even
/// queried), and the CSV builders have no column for notes, journal answers or raw streams. With
/// `includeGlucose` (the user's opt-in in the Shortcuts action) the daily glucose, insulin and carbohydrate
/// series of the Apple Health source are also read, key by key from `DatabricksCsv.glucoseAllowlist`, into a
/// seventh file; without it they are never queried.
enum DatabricksExport {

    /// The store id of the Apple Health import, where Loop's (or a CGM / pump app's) daily glucose, insulin and
    /// carbohydrate summaries are kept. The same value as `Repository.appleHealthSource`, repeated here because
    /// that constant is main-actor isolated and this export runs off the main actor.
    private static let appleHealthId = "apple-health"

    /// A heart-rate window longer than this gets no zone minutes (an all-day import, a hike logged as one
    /// workout): the read would be large and a zone split of it says little about a training session.
    private static let maxZoneWindowSeconds = 6 * 3_600
    /// Cap on the heart-rate rows read for one window: 6 h at 1 Hz is 21,600, with room for PPG fallbacks.
    private static let heartRateRowLimit = 30_000
    private static let rowLimit = 100_000
    private static let folderPrefix = "noop-databricks-"

    /// Writes the six CSVs (all of them, a table with no rows gets just its header), plus the glucose CSV when
    /// `includeGlucose` is on, into a fresh temporary folder and returns their URLs in
    /// `DatabricksCsv.tables(includeGlucose:)` order.
    ///
    /// - Parameters:
    ///   - deviceId: the canonical imported id (`"my-whoop"`); its computed twin is `deviceId + "-noop"`.
    ///   - maxHR: the athlete's maximum heart rate, for the zone minutes; 0 or less leaves them empty.
    ///   - days: 0 (or less) exports the whole history; otherwise only the last `days` local days, today
    ///     included. Late corrections (an edited night, a WOD saved the next morning) are why a daily run
    ///     re-sends a fortnight rather than only yesterday.
    ///   - includeGlucose: the user's opt-in for the daily glucose, insulin and carbohydrate summaries.
    static func writeFiles(store: WhoopStore, deviceId: String, maxHR: Int, days: Int, includeGlucose: Bool = false,
                           now: Date = Date(), timeZone: TimeZone = .current) async throws -> [URL] {
        // The reads hop onto the store's own executor already; the detached task also keeps the zone
        // maths and the CSV building off the main actor when a view calls this.
        try await Task.detached(priority: .utility) {
            try await DatabricksExport.build(store: store, deviceId: deviceId, maxHR: maxHR, days: days,
                                             includeGlucose: includeGlucose, now: now, timeZone: timeZone)
        }.value
    }

    private static func build(store: WhoopStore, deviceId: String, maxHR: Int, days: Int, includeGlucose: Bool,
                              now: Date, timeZone: TimeZone) async throws -> [URL] {
        let computedId = deviceId + "-noop"
        let clock = DatabricksCsv.LocalClock(timeZone: timeZone)
        let windowed = days > 0
        let fromTs = windowed ? Int(clock.windowStart(now: now, days: days).timeIntervalSince1970) : 0
        let sinceDay: String? = windowed ? clock.day(fromTs) : nil
        let fromDay = sinceDay ?? "0000-01-01"
        let toDay = "9999-12-31"
        let hi = Int(now.timeIntervalSince1970) + 86_400
        // A night that wakes inside the window may have started up to a day before it.
        let sleepFrom = windowed ? max(0, fromTs - 86_400) : 0

        // Daily rows and the allowlisted series.
        let importedDays = try await store.dailyMetrics(deviceId: deviceId, from: fromDay, to: toDay)
        let computedDays = try await store.dailyMetrics(deviceId: computedId, from: fromDay, to: toDay)
        var importedPoints: [MetricPoint] = []
        var computedPoints: [MetricPoint] = []
        for key in DatabricksCsv.metricAllowlist.sorted() {
            try Task.checkCancellation()
            importedPoints += try await store.metricSeries(deviceId: deviceId, key: key, from: fromDay, to: toDay)
            computedPoints += try await store.metricSeries(deviceId: computedId, key: key, from: fromDay, to: toDay)
        }
        let series = DatabricksCsv.mergeSeries(imported: importedPoints, computed: computedPoints)

        // Sleep and workouts.
        let importedSleep = try await store.sleepSessions(deviceId: deviceId, from: sleepFrom, to: hi, limit: rowLimit)
        let computedSleep = try await store.sleepSessions(deviceId: computedId, from: sleepFrom, to: hi, limit: rowLimit)
        let importedWorkouts = try await store.workouts(deviceId: deviceId, from: fromTs, to: hi, limit: rowLimit)
        let computedWorkouts = try await store.workouts(deviceId: computedId, from: fromTs, to: hi, limit: rowLimit)
        let workouts = DatabricksCsv.uniqueWorkouts(imported: importedWorkouts, computed: computedWorkouts)

        // WODs (user-authored; the log is not tied to a strap id).
        let allWods = try await store.allWods(limit: rowLimit)
        let wods: [WodLogRow]
        if let sinceDay {
            wods = allWods.filter { $0.day >= sinceDay }
        } else {
            wods = allWods
        }

        // Heart-rate zone minutes, only for the workouts and WOD sessions that are being exported.
        let heartRateIds = heartRateSourceIds(store: store, deviceId: deviceId)
        var workoutZones: [String: [Double]] = [:]
        for w in workouts {
            try Task.checkCancellation()
            let minutes = await zoneMinutes(store: store, ids: heartRateIds, from: w.startTs, to: w.endTs, maxHR: maxHR)
            if let minutes { workoutZones[DatabricksCsv.workoutKey(w)] = minutes }
        }
        var wodZones: [String: [Double]] = [:]
        for w in wods {
            try Task.checkCancellation()
            guard let span = w.sessionSpan else { continue }
            let minutes = await zoneMinutes(store: store, ids: heartRateIds, from: span.start, to: span.end, maxHR: maxHR)
            if let minutes { wodZones[w.id] = minutes }
        }

        // One CSV per table, in `DatabricksCsv.tables(includeGlucose:)` order.
        var texts: [String: String] = [
            "days": DatabricksCsv.daysCSV(imported: importedDays, computed: computedDays,
                                          series: series, exportedAt: now),
            "sleeps": DatabricksCsv.sleepsCSV(imported: importedSleep, computed: computedSleep, sinceDay: sinceDay,
                                              exportedAt: now, timeZone: timeZone),
            "workouts": DatabricksCsv.workoutsCSV(workouts, computedId: computedId, zoneMinutes: workoutZones,
                                                  exportedAt: now, timeZone: timeZone),
            "wods": DatabricksCsv.wodsCSV(wods, zoneMinutes: wodZones, exportedAt: now, timeZone: timeZone),
            "wod_movements": DatabricksCsv.wodMovementsCSV(wods, exportedAt: now),
            "metrics": DatabricksCsv.metricsCSV(series: series, exportedAt: now),
        ]

        // The opt-in glucose table: Apple Health's daily summaries, allowlisted keys only, same day window.
        if includeGlucose {
            var glucosePoints: [MetricPoint] = []
            for key in DatabricksCsv.glucoseAllowlist.sorted() {
                try Task.checkCancellation()
                glucosePoints += try await store.metricSeries(deviceId: appleHealthId, key: key, from: fromDay, to: toDay)
            }
            texts[DatabricksCsv.glucoseTable] = DatabricksCsv.glucoseCSV(points: glucosePoints, exportedAt: now)
        }
        return try write(texts, tables: DatabricksCsv.tables(includeGlucose: includeGlucose),
                         exportedAt: now, timeZone: timeZone)
    }

    // MARK: - Zones

    /// The ids whose heart rate counts: the canonical one, plus the active strap when a re-added strap has
    /// moved the live recording to a fresh id (`Repository.hrSamples` reads the same union).
    private static func heartRateSourceIds(store: WhoopStore, deviceId: String) -> [String] {
        let registry = DeviceRegistryStore(dbQueue: store.registryWriter)
        guard let active = try? registry.activeDeviceId(), !active.isEmpty, active != deviceId else {
            return [deviceId]
        }
        return [active, deviceId]
    }

    /// Minutes in heart-rate zones 1...5 over [from, to], from the strap's own samples and the zones built
    /// from `maxHR`: the computation behind `Repository.workoutZoneMinutes` and the workout screens. nil when
    /// the window is empty, too long, or holds no heart rate.
    private static func zoneMinutes(store: WhoopStore, ids: [String], from: Int, to: Int, maxHR: Int) async -> [Double]? {
        guard maxHR > 0, to > from, to - from <= maxZoneWindowSeconds else { return nil }
        var byTs: [Int: HRSample] = [:]
        for id in ids {
            let rows = (try? await store.hrSamples(deviceId: id, from: from, to: to, limit: heartRateRowLimit)) ?? []
            for s in rows where byTs[s.ts] == nil { byTs[s.ts] = s }
        }
        guard !byTs.isEmpty else { return nil }
        let samples = byTs.values.sorted { $0.ts < $1.ts }
        let zoneSet = HRZones.zones(maxHR: Double(maxHR))
        let inZone = HRZones.timeInZone(samples, zoneSet: zoneSet)
        let minutes = inZone.seconds.map { $0 / 60.0 }
        return minutes.contains(where: { $0 > 0 }) ? minutes : nil
    }

    // MARK: - Files

    /// Writes each of `tables` into a new temporary folder, named `<table>__<local timestamp>.csv`. A failure
    /// part-way removes the folder so no half export is left behind.
    private static func write(_ texts: [String: String], tables: [String], exportedAt: Date,
                              timeZone: TimeZone) throws -> [URL] {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
        pruneOldFolders(in: tmp)
        let folder = tmp.appendingPathComponent(folderPrefix + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            var urls: [URL] = []
            for table in tables {
                let name = DatabricksCsv.fileName(table: table, exportedAt: exportedAt, timeZone: timeZone)
                let url = folder.appendingPathComponent(name)
                try (texts[table] ?? "").write(to: url, atomically: true, encoding: .utf8)
                urls.append(url)
            }
            return urls
        } catch {
            try? fm.removeItem(at: folder)
            throw error
        }
    }

    /// A daily Shortcut leaves one folder per run in the temporary directory; drop the ones older than a day
    /// (the Shortcut has uploaded them long before) so they do not pile up while iOS keeps the app alive.
    private static func pruneOldFolders(in tmp: URL) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil) else { return }
        let cutoff = Date().addingTimeInterval(-86_400)
        for url in entries where url.lastPathComponent.hasPrefix(folderPrefix) {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            if let modified = values?.contentModificationDate, modified < cutoff {
                try? fm.removeItem(at: url)
            }
        }
    }
}
