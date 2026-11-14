import XCTest
import WhoopStore
@testable import StrandImport

/// Pins the Databricks export contract: exact headers, one golden row per table, RFC 4180 quoting, "."
/// decimals, the metric allowlist and the notes that must never leave the device.
final class DatabricksCsvTests: XCTestCase {

    /// 2026-11-02T09:00:00Z.
    private let exportedAt = Date(timeIntervalSince1970: 1_793_610_000)
    /// Rome in November (UTC+1), as a fixed offset so the test does not depend on the tz database.
    private let rome = TimeZone(secondsFromGMT: 3600)!

    private let stamp = "2026-11-02T09:00:00Z"

    /// Lines of a CSV text (header first), without the empty tail after the final newline.
    private func lines(_ csv: String) -> [String] {
        csv.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    /// Minimal RFC 4180 reader, so the quoting is checked by parsing it back rather than by eye.
    private func parse(_ csv: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        let chars = Array(csv)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if quoted {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" { field.append("\""); i += 1 } else { quoted = false }
                } else {
                    field.append(c)
                }
            } else if c == "\"" {
                quoted = true
            } else if c == "," {
                row.append(field); field = ""
            } else if c == "\n" {
                row.append(field); field = ""
                rows.append(row); row = []
            } else {
                field.append(c)
            }
            i += 1
        }
        return rows
    }

    // MARK: - Fixtures

    private func day(_ d: String) -> DailyMetric {
        DailyMetric(day: d, totalSleepMin: 442.5, efficiency: 0.9, deepMin: 88, remMin: 101.25,
                    lightMin: 253.25, disturbances: 3, restingHr: 51, avgHrv: 59.2, recovery: 78,
                    strain: 54.5, exerciseCount: 1, spo2Pct: 96.5, skinTempDevC: -0.3,
                    respRateBpm: 14.8, steps: 10_234, activeKcalEst: nil)
    }

    private func night(start: Int = 1_793_568_600, end: Int = 1_793_595_600, adjusted: Int? = nil,
                       edited: Bool = false) -> CachedSleepSession {
        CachedSleepSession(startTs: start, endTs: end, efficiency: 92.3, restingHr: 50, avgHrv: 61.5,
                           stagesJSON: #"{"light":200,"deep":80,"rem":90,"awake":30}"#,
                           userEdited: edited, startTsAdjusted: adjusted)
    }

    private func workout(sport: String = "CrossFit", start: Int = 1_793_552_400) -> WorkoutRow {
        WorkoutRow(startTs: start, endTs: start + 3600, sport: sport, source: "whoop", durationS: 3600,
                   energyKcal: 540.5, avgHr: 142, maxHr: 178, strain: 62.25, distanceM: nil,
                   zonesJSON: nil, notes: "SECRET WORKOUT NOTE")
    }

    private func fran(endTs: Int? = 1_793_555_100) -> WodLogRow {
        WodLogRow(id: "wod-1", ts: 1_793_550_600, day: "2026-11-01", type: "metcon",
                  title: "Fran, \"the classic\"", format: "for time", timeCapS: 600, resultKind: .time,
                  resultSeconds: 252, rpe: 8.5, rx: true, notes: "SECRET WOD NOTE",
                  movements: [
                    WodMovement(name: "Thruster", reps: 21, scheme: "21-15-9", repsDone: 21,
                                weightKg: 43, rxWeightKg: 43, notes: "SECRET MOVEMENT NOTE"),
                    WodMovement(name: "Pull-up"),
                  ],
                  createdTs: 1_793_550_700, endTs: endTs)
    }

    // MARK: - Tables, headers, names

    func testTablesAndExactHeaders() {
        XCTAssertEqual(DatabricksCsv.tables, ["days", "sleeps", "workouts", "wods", "wod_movements", "metrics"])

        XCTAssertEqual(lines(DatabricksCsv.daysCSV(imported: [], computed: [], series: [], exportedAt: exportedAt)),
                       ["day,export_ts,source,charge,effort,rest,total_sleep_min,sleep_efficiency,deep_min,"
                        + "rem_min,light_min,disturbances,resting_hr,hrv_ms,spo2_pct,resp_rate_bpm,"
                        + "skin_temp_dev_c,steps,active_kcal"])
        XCTAssertEqual(lines(DatabricksCsv.sleepsCSV(imported: [], computed: [], exportedAt: exportedAt, timeZone: rome)),
                       ["session_start_ts,export_ts,start_local,end_local,end_ts,wake_day,in_bed_min,"
                        + "asleep_min,efficiency,deep_min,rem_min,light_min,wake_min,resting_hr,hrv_ms,"
                        + "edited,source"])
        XCTAssertEqual(lines(DatabricksCsv.workoutsCSV([], computedId: "my-whoop-noop", zoneMinutes: [:],
                                                       exportedAt: exportedAt, timeZone: rome)),
                       ["workout_key,export_ts,start_local,end_local,start_ts,end_ts,day,sport,duration_min,"
                        + "avg_hr,max_hr,kcal,strain,z1_min,z2_min,z3_min,z4_min,z5_min,source"])
        XCTAssertEqual(lines(DatabricksCsv.wodsCSV([], zoneMinutes: [:], exportedAt: exportedAt, timeZone: rome)),
                       ["wod_id,export_ts,day,start_local,end_local,title,type,format,time_cap_s,result_kind,"
                        + "result_seconds,result_rounds,result_reps,result_weight_kg,rpe,rx,z1_min,z2_min,"
                        + "z3_min,z4_min,z5_min"])
        XCTAssertEqual(lines(DatabricksCsv.wodMovementsCSV([], exportedAt: exportedAt)),
                       ["wod_id,export_ts,day,position,movement,reps,scheme,reps_done,weight_kg,rx_weight_kg"])
        XCTAssertEqual(lines(DatabricksCsv.metricsCSV(series: [], exportedAt: exportedAt)),
                       ["day,key,export_ts,source,value"])
    }

    func testFileNameIsLocalTimeAndPerTable() {
        // 09:00:00Z is 10:00:00 in UTC+1, same local day.
        XCTAssertEqual(DatabricksCsv.fileName(table: "days", exportedAt: exportedAt, timeZone: rome),
                       "days__20261102-100000.csv")
        XCTAssertEqual(DatabricksCsv.fileName(table: "wod_movements", exportedAt: exportedAt,
                                              timeZone: TimeZone(secondsFromGMT: 0)!),
                       "wod_movements__20261102-090000.csv")
        // Across midnight: 23:30:05Z on the 1st is 00:30:05 on the 2nd at UTC+1.
        let late = Date(timeIntervalSince1970: 1_793_575_805)
        XCTAssertEqual(DatabricksCsv.fileName(table: "sleeps", exportedAt: late, timeZone: rome),
                       "sleeps__20261102-003005.csv")
    }

    func testExportStampIsIsoUtc() {
        XCTAssertEqual(DatabricksCsv.exportStamp(exportedAt), stamp)
        XCTAssertEqual(DatabricksCsv.exportStamp(Date(timeIntervalSince1970: 0)), "1970-01-01T00:00:00Z")
    }

    func testWindowStartCountsTodayAndWholeLocalDays() {
        let clock = DatabricksCsv.LocalClock(timeZone: rome)
        // "now" is 2026-11-02 10:00 local. 1 day = today's midnight; 14 days = 13 midnights back.
        let one = Int(clock.windowStart(now: exportedAt, days: 1).timeIntervalSince1970)
        XCTAssertEqual(clock.dateTime(one), "2026-11-02 00:00:00")
        let fourteen = Int(clock.windowStart(now: exportedAt, days: 14).timeIntervalSince1970)
        XCTAssertEqual(clock.dateTime(fourteen), "2026-10-20 00:00:00")
        let zero = Int(clock.windowStart(now: exportedAt, days: 0).timeIntervalSince1970)
        XCTAssertEqual(zero, one)
    }

    // MARK: - days

    func testDaysGoldenRowImportedWithRest() {
        let series = DatabricksCsv.mergeSeries(
            imported: [MetricPoint(day: "2026-11-01", key: "sleep_performance", value: 84)], computed: [])
        let csv = DatabricksCsv.daysCSV(imported: [day("2026-11-01")], computed: [], series: series,
                                        exportedAt: exportedAt)
        // 0.9 is the stager's fraction form of efficiency: exported as a percentage. active_kcal nil → empty.
        XCTAssertEqual(lines(csv).last,
                       "2026-11-01,\(stamp),import,78,54.5,84,442.5,90,88,101.25,253.25,3,51,59.2,96.5,14.8,-0.3,10234,")
    }

    func testDaysImportedWinsAndComputedFillsOtherDays() {
        let computedOnly = DailyMetric(day: "2026-10-31", totalSleepMin: nil, efficiency: nil, deepMin: nil,
                                       remMin: nil, lightMin: nil, disturbances: nil, restingHr: nil,
                                       avgHrv: nil, recovery: 66, strain: nil, exerciseCount: nil)
        let computedSame = DailyMetric(day: "2026-11-01", totalSleepMin: 1, efficiency: nil, deepMin: nil,
                                       remMin: nil, lightMin: nil, disturbances: nil, restingHr: nil,
                                       avgHrv: nil, recovery: 1, strain: nil, exerciseCount: nil)
        let csv = DatabricksCsv.daysCSV(imported: [day("2026-11-01")], computed: [computedSame, computedOnly],
                                        series: [], exportedAt: exportedAt)
        let rows = parse(csv)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[1][0], "2026-10-31")
        XCTAssertEqual(rows[1][2], "noop")
        XCTAssertEqual(rows[1][3], "66")
        XCTAssertEqual(rows[1][4], "")          // nil effort → empty field
        XCTAssertEqual(rows[2][0], "2026-11-01")
        XCTAssertEqual(rows[2][2], "import")
        XCTAssertEqual(rows[2][3], "78")        // the import's value, not the computed 1
        XCTAssertEqual(rows[2][5], "")          // no Rest series for the day
        XCTAssertTrue(rows.allSatisfy { $0.count == 19 })
    }

    func testDecimalsUseADotWhateverTheLocale() {
        // An Italian formatter writes 59,2; the CSV must not. (The formatter line only documents what
        // the user's phone would do; the assertion that matters is on the CSV.)
        let italian = NumberFormatter()
        italian.locale = Locale(identifier: "it_IT")
        italian.numberStyle = .decimal
        italian.minimumFractionDigits = 1
        italian.maximumFractionDigits = 1
        let csv = DatabricksCsv.daysCSV(imported: [day("2026-11-01")], computed: [], series: [], exportedAt: exportedAt)
        let row = lines(csv)[1]
        XCTAssertTrue(row.contains(",59.2,"))
        XCTAssertFalse(row.contains("59,2"))
        XCTAssertFalse(row.contains("10.234"))   // no thousands separator either
        _ = italian.string(from: 59.2)
    }

    func testSleepEfficiencyAcceptsFractionAndPercent() {
        let fraction = DailyMetric(day: "2026-11-01", totalSleepMin: nil, efficiency: 0.875, deepMin: nil,
                                   remMin: nil, lightMin: nil, disturbances: nil, restingHr: nil, avgHrv: nil,
                                   recovery: nil, strain: nil, exerciseCount: nil)
        let percent = DailyMetric(day: "2026-11-02", totalSleepMin: nil, efficiency: 91.5, deepMin: nil,
                                  remMin: nil, lightMin: nil, disturbances: nil, restingHr: nil, avgHrv: nil,
                                  recovery: nil, strain: nil, exerciseCount: nil)
        let rows = parse(DatabricksCsv.daysCSV(imported: [fraction, percent], computed: [], series: [],
                                               exportedAt: exportedAt))
        XCTAssertEqual(rows[1][7], "87.5")
        XCTAssertEqual(rows[2][7], "91.5")
    }

    // MARK: - sleeps

    func testSleepsGoldenRowUsesEffectiveStartAndKeepsTheDetectedKey() {
        let edited = night(adjusted: 1_793_570_400, edited: true)
        let csv = DatabricksCsv.sleepsCSV(imported: [edited], computed: [], exportedAt: exportedAt, timeZone: rome)
        // Key = detected start. Shown start = corrected onset (22:00Z = 23:00 local), in-bed from it.
        XCTAssertEqual(lines(csv).last,
                       "1793568600,\(stamp),2026-11-01 23:00:00,2026-11-02 06:00:00,1793595600,2026-11-02,"
                       + "420,370,92.3,80,90,200,30,50,61.5,true,import")
    }

    func testSleepsKeepNapsAndLetImportsWinPerWakeDay() {
        let importedNight = night()
        let computedSameDay = night(start: 1_793_569_000, end: 1_793_594_000)          // same wake day → yields
        let nap = night(start: 1_793_678_400, end: 1_793_682_000)                        // wakes the next day
        let csv = DatabricksCsv.sleepsCSV(imported: [importedNight], computed: [computedSameDay, nap],
                                          exportedAt: exportedAt, timeZone: rome)
        let rows = parse(csv)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[1][0], "1793568600")
        XCTAssertEqual(rows[1][16], "import")
        XCTAssertEqual(rows[2][0], "1793678400")
        XCTAssertEqual(rows[2][16], "noop")
        XCTAssertEqual(rows[1][15], "false")
    }

    func testSleepsSinceDayFiltersOnWakeDay() {
        let old = night(start: 1_793_000_000, end: 1_793_027_000)   // wakes 2026-10-26
        let recent = night()
        let csv = DatabricksCsv.sleepsCSV(imported: [old, recent], computed: [], sinceDay: "2026-11-01",
                                          exportedAt: exportedAt, timeZone: rome)
        XCTAssertEqual(parse(csv).count, 2)
        XCTAssertEqual(parse(csv)[1][0], "1793568600")
    }

    // MARK: - workouts

    func testWorkoutsGoldenRowWithZones() {
        let w = workout()
        let zones = [DatabricksCsv.workoutKey(w): [5.0, 10.5, 20.0, 15.256, 1.0]]
        let csv = DatabricksCsv.workoutsCSV([w], computedId: "my-whoop-noop", zoneMinutes: zones,
                                            exportedAt: exportedAt, timeZone: rome)
        XCTAssertEqual(lines(csv).last,
                       "1793552400|CrossFit,\(stamp),2026-11-01 18:00:00,2026-11-01 19:00:00,1793552400,"
                       + "1793556000,2026-11-01,CrossFit,60,142,178,540.5,62.25,5,10.5,20,15.26,1,import")
    }

    func testWorkoutWithoutHeartRateHasEmptyZonesAndQuotedSport() {
        let w = workout(sport: "Run, \"tempo\"")
        let csv = DatabricksCsv.workoutsCSV([w], computedId: "my-whoop-noop", zoneMinutes: [:],
                                            exportedAt: exportedAt, timeZone: rome)
        let row = parse(csv)[1]
        XCTAssertEqual(row[0], "1793552400|Run, \"tempo\"")
        XCTAssertEqual(row[7], "Run, \"tempo\"")
        XCTAssertEqual(Array(row[13...17]), ["", "", "", "", ""])
        XCTAssertEqual(row.count, 19)
    }

    func testWorkoutSourcesAndDedup() {
        let strap = workout()
        let manual = WorkoutRow(startTs: 1_793_560_000, endTs: 1_793_561_000, sport: "Run", source: "manual",
                                durationS: nil, energyKcal: nil, avgHr: nil, maxHr: nil, strain: nil,
                                distanceM: nil, zonesJSON: nil, notes: nil)
        let detected = WorkoutRow(startTs: 1_793_570_000, endTs: 1_793_571_800, sport: "detected",
                                  source: "my-whoop-noop", durationS: nil, energyKcal: nil, avgHr: nil,
                                  maxHr: nil, strain: nil, distanceM: nil, zonesJSON: nil, notes: nil)
        // The same session under both ids counts once, the import's copy winning.
        let twin = WorkoutRow(startTs: strap.startTs, endTs: strap.endTs, sport: strap.sport,
                              source: "my-whoop-noop", durationS: 1, energyKcal: 1, avgHr: 1, maxHr: 1,
                              strain: 1, distanceM: nil, zonesJSON: nil, notes: nil)
        let unique = DatabricksCsv.uniqueWorkouts(imported: [strap, manual], computed: [twin, detected])
        XCTAssertEqual(unique.count, 3)
        let rows = parse(DatabricksCsv.workoutsCSV(unique, computedId: "my-whoop-noop", zoneMinutes: [:],
                                                   exportedAt: exportedAt, timeZone: rome))
        XCTAssertEqual(rows.map { $0[18] }, ["source", "import", "manual", "noop"])
        // Rows without a stored duration derive it from the span (1000 s → 16.67 min).
        XCTAssertEqual(rows[2][8], "16.67")
    }

    // MARK: - wods and movements

    func testWodsGoldenRowQuotesTitleAndLeavesNotesOut() {
        let csv = DatabricksCsv.wodsCSV([fran()], zoneMinutes: [:], exportedAt: exportedAt, timeZone: rome)
        XCTAssertEqual(lines(csv).last,
                       "wod-1,\(stamp),2026-11-01,2026-11-01 17:30:00,2026-11-01 18:45:00,"
                       + "\"Fran, \"\"the classic\"\"\",metcon,for time,600,time,252,,,,8.5,true,,,,,")
        XCTAssertEqual(parse(csv)[1][5], "Fran, \"the classic\"")
    }

    func testWodWithoutSessionSpanHasNoEndAndZonesAreCarriedWhenGiven() {
        let weight = WodLogRow(id: "wod-2", ts: 1_793_550_600, day: "2026-11-01", type: "strength",
                               title: "Back Squat", resultKind: .weight, resultWeightKg: 140, createdTs: 0,
                               endTs: 1_793_550_000)   // end before start → not a span
        let csv = DatabricksCsv.wodsCSV([weight], zoneMinutes: ["wod-2": [1, 2, 3, 4, 5]],
                                        exportedAt: exportedAt, timeZone: rome)
        let row = parse(csv)[1]
        XCTAssertEqual(row[4], "")              // end_local
        XCTAssertEqual(row[9], "weight")
        XCTAssertEqual(row[13], "140")
        XCTAssertEqual(row[15], "")             // rx unset → empty, not false
        XCTAssertEqual(Array(row[16...20]), ["1", "2", "3", "4", "5"])
    }

    func testWodMovementsGoldenRowsAndPositions() {
        let csv = DatabricksCsv.wodMovementsCSV([fran()], exportedAt: exportedAt)
        XCTAssertEqual(Array(lines(csv).dropFirst()), [
            "wod-1,\(stamp),2026-11-01,1,Thruster,21,21-15-9,21,43,43",
            "wod-1,\(stamp),2026-11-01,2,Pull-up,,,,,",
        ])
    }

    func testMultiLineTitleStaysOnOneRow() {
        var w = fran()
        w.title = "Fran\nthe classic\r\n"
        let csv = DatabricksCsv.wodsCSV([w], zoneMinutes: [:], exportedAt: exportedAt, timeZone: rome)
        XCTAssertEqual(parse(csv).count, 2)
        XCTAssertEqual(parse(csv)[1][5], "Fran the classic")
    }

    // MARK: - metrics and the allowlist

    func testMetricsGoldenRowsImportWinsPerDayAndKey() {
        let imported = [MetricPoint(day: "2026-11-01", key: "vo2max_est", value: 47.6)]
        let computed = [MetricPoint(day: "2026-11-01", key: "vo2max_est", value: 41),
                        MetricPoint(day: "2026-11-01", key: "steps_est", value: 9000)]
        let series = DatabricksCsv.mergeSeries(imported: imported, computed: computed)
        let csv = DatabricksCsv.metricsCSV(series: series, exportedAt: exportedAt)
        XCTAssertEqual(Array(lines(csv).dropFirst()), [
            "2026-11-01,steps_est,\(stamp),noop,9000",
            "2026-11-01,vo2max_est,\(stamp),import,47.6",
        ])
    }

    func testAllowlistDropsEverythingNotListed() {
        let forbidden = ["glucose_avg", "insulin_total", "weight", "carbs_g", "irregular_rhythm_pct", "mood"]
        let bad = forbidden.map { MetricPoint(day: "2026-11-01", key: $0, value: 123.456) }
        let good = MetricPoint(day: "2026-11-01", key: "recovery", value: 78)

        let merged = DatabricksCsv.mergeSeries(imported: bad + [good], computed: bad)
        XCTAssertEqual(merged.map { $0.point.key }, ["recovery"])

        // The CSV builder re-applies it, so a caller that skips mergeSeries still cannot leak a key.
        let raw = (bad + [good]).map { DatabricksCsv.SourcedPoint(point: $0, source: "import") }
        let csv = DatabricksCsv.metricsCSV(series: raw, exportedAt: exportedAt)
        XCTAssertEqual(parse(csv).count, 2)
        for key in forbidden { XCTAssertFalse(csv.contains(key), key) }
        XCTAssertFalse(csv.contains("123.456"))

        for key in forbidden { XCTAssertFalse(DatabricksCsv.metricAllowlist.contains(key), key) }
        XCTAssertEqual(DatabricksCsv.metricAllowlist.count, 35)
    }

    func testNonFiniteMetricValuesAreDropped() {
        let pts = [MetricPoint(day: "2026-11-01", key: "recovery", value: .nan),
                   MetricPoint(day: "2026-11-01", key: "strain", value: .infinity)]
        XCTAssertTrue(DatabricksCsv.mergeSeries(imported: pts, computed: []).isEmpty)
    }

    // MARK: - glucose (opt-in)

    func testGlucoseTableIsOnlyAddedOnOptIn() {
        XCTAssertEqual(DatabricksCsv.tables(includeGlucose: false), DatabricksCsv.tables)
        XCTAssertEqual(DatabricksCsv.tables(includeGlucose: true),
                       ["days", "sleeps", "workouts", "wods", "wod_movements", "metrics", "glucose"])
        XCTAssertEqual(lines(DatabricksCsv.glucoseCSV(points: [], exportedAt: exportedAt)),
                       ["day,key,export_ts,source,value"])
        XCTAssertEqual(DatabricksCsv.fileName(table: DatabricksCsv.glucoseTable, exportedAt: exportedAt, timeZone: rome),
                       "glucose__20261102-100000.csv")
    }

    func testGlucoseGoldenRowsSortedByDayThenKey() {
        let pts = [MetricPoint(day: "2026-11-02", key: "glucose_tir", value: 81),
                   MetricPoint(day: "2026-11-01", key: "insulin_bolus", value: 12.3),
                   MetricPoint(day: "2026-11-01", key: "glucose_tir", value: 72.5),
                   MetricPoint(day: "2026-11-01", key: "carbs_g", value: 180)]
        XCTAssertEqual(Array(lines(DatabricksCsv.glucoseCSV(points: pts, exportedAt: exportedAt)).dropFirst()), [
            "2026-11-01,carbs_g,\(stamp),apple_health,180",
            "2026-11-01,glucose_tir,\(stamp),apple_health,72.5",
            "2026-11-01,insulin_bolus,\(stamp),apple_health,12.3",
            "2026-11-02,glucose_tir,\(stamp),apple_health,81",
        ])
    }

    func testGlucoseTableDropsEverythingOutsideItsAllowlist() {
        let forbidden = ["weight", "bp_systolic", "protein_g", "mood", "recovery", "irregular_rhythm_pct", "glucose_reading"]
        let bad = forbidden.map { MetricPoint(day: "2026-11-01", key: $0, value: 123.456) }
        let nonFinite = [MetricPoint(day: "2026-11-01", key: "glucose_cv", value: .nan),
                         MetricPoint(day: "2026-11-01", key: "glucose_avg", value: .infinity)]
        let good = MetricPoint(day: "2026-11-01", key: "glucose_hypos", value: 2)
        let csv = DatabricksCsv.glucoseCSV(points: bad + nonFinite + [good], exportedAt: exportedAt)
        XCTAssertEqual(Array(lines(csv).dropFirst()), ["2026-11-01,glucose_hypos,\(stamp),apple_health,2"])
        for key in forbidden { XCTAssertFalse(csv.contains(key), key) }
        XCTAssertFalse(csv.contains("123.456"))
    }

    func testGlucoseAllowlistNeverWidensTheDefaultExport() {
        XCTAssertTrue(DatabricksCsv.glucoseAllowlist.isDisjoint(with: DatabricksCsv.metricAllowlist))
        XCTAssertEqual(DatabricksCsv.glucoseAllowlist.count, 18)
        // A glucose key handed to the default metrics table is still dropped there.
        let raw = [DatabricksCsv.SourcedPoint(point: MetricPoint(day: "2026-11-01", key: "glucose_tir", value: 70),
                                              source: "import")]
        XCTAssertEqual(parse(DatabricksCsv.metricsCSV(series: raw, exportedAt: exportedAt)).count, 1)
    }

    func testGlucoseRepeatedDayAndKeyKeepsOneRow() {
        let pts = [MetricPoint(day: "2026-11-01", key: "insulin_basal", value: 10),
                   MetricPoint(day: "2026-11-01", key: "insulin_basal", value: 11.5)]
        let rows = Array(lines(DatabricksCsv.glucoseCSV(points: pts, exportedAt: exportedAt)).dropFirst())
        XCTAssertEqual(rows, ["2026-11-01,insulin_basal,\(stamp),apple_health,11.5"])
    }

    // MARK: - Privacy: notes never appear

    func testNoNotesTextAppearsAnywhere() {
        let w = workout()
        let wod = fran()
        let night = night()
        let all = [
            DatabricksCsv.daysCSV(imported: [day("2026-11-01")], computed: [], series: [], exportedAt: exportedAt),
            DatabricksCsv.sleepsCSV(imported: [night], computed: [], exportedAt: exportedAt, timeZone: rome),
            DatabricksCsv.workoutsCSV([w], computedId: "x", zoneMinutes: [:], exportedAt: exportedAt, timeZone: rome),
            DatabricksCsv.wodsCSV([wod], zoneMinutes: [:], exportedAt: exportedAt, timeZone: rome),
            DatabricksCsv.wodMovementsCSV([wod], exportedAt: exportedAt),
            DatabricksCsv.metricsCSV(series: [], exportedAt: exportedAt),
        ].joined()
        XCTAssertFalse(all.contains("SECRET"))
        XCTAssertFalse(all.lowercased().contains("notes"))
    }

    func testEveryRowHasAsManyFieldsAsTheHeader() {
        let tables = [
            DatabricksCsv.daysCSV(imported: [day("2026-11-01")], computed: [], series: [], exportedAt: exportedAt),
            DatabricksCsv.sleepsCSV(imported: [night()], computed: [], exportedAt: exportedAt, timeZone: rome),
            DatabricksCsv.workoutsCSV([workout(sport: "A,\"B\"")], computedId: "x", zoneMinutes: [:],
                                      exportedAt: exportedAt, timeZone: rome),
            DatabricksCsv.wodsCSV([fran()], zoneMinutes: [:], exportedAt: exportedAt, timeZone: rome),
            DatabricksCsv.wodMovementsCSV([fran()], exportedAt: exportedAt),
        ]
        for csv in tables {
            let rows = parse(csv)
            XCTAssertGreaterThan(rows.count, 1)
            XCTAssertTrue(rows.allSatisfy { $0.count == rows[0].count }, csv)
        }
    }
}
