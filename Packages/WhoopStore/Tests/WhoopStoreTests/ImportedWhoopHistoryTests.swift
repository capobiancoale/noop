import XCTest
import WhoopProtocol
@testable import WhoopStore

/// NOT RUN when written: no Swift toolchain on the authoring machine. Read it as untested code.
final class ImportedWhoopHistoryTests: XCTestCase {
    private let canon = "my-whoop"
    private let noop = "my-whoop-noop"

    private func day(_ d: String, recovery: Double? = 70) -> DailyMetric {
        DailyMetric(day: d, totalSleepMin: 420, efficiency: 90, deepMin: 80, remMin: 90, lightMin: 250,
                    disturbances: nil, restingHr: 52, avgHrv: 60, recovery: recovery, strain: 40,
                    exerciseCount: nil)
    }

    private func workout(_ start: Int, sport: String, source: String) -> WorkoutRow {
        WorkoutRow(startTs: start, endTs: start + 3600, sport: sport, source: source, durationS: 3600,
                   energyKcal: 300, avgHr: 130, maxHr: 170, strain: 50, distanceM: nil,
                   zonesJSON: nil, notes: nil)
    }

    /// A store holding imported rows, NOOP-computed rows, the strap's own streams, user entries and Apple rows.
    private func seeded() async throws -> WhoopStore {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: canon, mac: nil, name: nil)

        // Imported WHOOP rows under the canonical id.
        _ = try await store.upsertDailyMetrics([day("2026-07-08"), day("2026-07-09")], deviceId: canon)
        _ = try await store.upsertMetricSeries([
            MetricPoint(day: "2026-07-08", key: "sleep_debt_min", value: 30),
            MetricPoint(day: "2026-07-09", key: "sleep_performance", value: 88),
            MetricPoint(day: "2026-07-09", key: "hr_zone3_min", value: 12),
        ], deviceId: canon)
        _ = try await store.upsertSleepSessions([
            CachedSleepSession(startTs: 1_783_000_000, endTs: 1_783_028_000, efficiency: 90,
                               restingHr: nil, avgHrv: nil, stagesJSON: nil),
            CachedSleepSession(startTs: 1_783_100_000, endTs: 1_783_128_000, efficiency: 91,
                               restingHr: nil, avgHrv: nil, stagesJSON: nil),
        ], deviceId: canon)
        _ = try await store.upsertWorkouts([workout(1_783_050_000, sport: "Running", source: "whoop")],
                                           deviceId: canon)
        _ = try await store.upsertJournal([JournalEntry(day: "2026-07-08", question: "Alcohol",
                                                        answeredYes: true, notes: nil)], deviceId: canon)

        // The user's own entries under the SAME id.
        _ = try await store.insertManualSleepSession(deviceId: canon, startTs: 1_783_200_000,
                                                     endTs: 1_783_228_000, efficiency: nil, stagesJSON: nil)
        _ = try await store.upsertSleepSessions([
            CachedSleepSession(startTs: 1_783_300_000, endTs: 1_783_328_000, efficiency: 80,
                               restingHr: nil, avgHrv: nil, stagesJSON: nil, userEdited: true,
                               startTsAdjusted: 1_783_299_000),
        ], deviceId: canon)
        _ = try await store.upsertWorkouts([workout(1_783_060_000, sport: "Back Squat", source: "manual"),
                                            workout(1_783_070_000, sport: "Cycling", source: "apple-health")],
                                           deviceId: canon)
        _ = try await store.upsertMetricSeries([MetricPoint(day: "2026-07-09", key: "sleep_mark", value: 1)],
                                               deviceId: canon)

        // What NOOP computed itself.
        _ = try await store.upsertDailyMetrics([day("2026-11-10")], deviceId: noop)
        _ = try await store.upsertMetricSeries([MetricPoint(day: "2026-11-10", key: "sleep_debt_min", value: 20),
                                                MetricPoint(day: "2026-11-10", key: "avg_hr", value: 70)],
                                               deviceId: noop)
        _ = try await store.upsertSleepSessions([
            CachedSleepSession(startTs: 1_790_000_000, endTs: 1_790_028_000, efficiency: 85,
                               restingHr: nil, avgHrv: nil, stagesJSON: nil),
        ], deviceId: noop)
        _ = try await store.upsertWorkouts([workout(1_790_050_000, sport: "detected", source: noop)],
                                           deviceId: noop)

        // The strap's own per-second streams under the canonical id.
        _ = try await store.insert(Streams(hr: [HRSample(ts: 1_790_000_000, bpm: 61),
                                                HRSample(ts: 1_790_000_001, bpm: 62)],
                                           gravity: [GravitySample(ts: 1_790_000_000, x: 0, y: 0, z: 1)]),
                                   deviceId: canon)

        // WODs and Apple Health.
        try await store.upsertWod(WodLogRow(id: "w1", ts: 1_783_000_000, day: "2026-07-08", type: "CrossFit",
                                            title: "Fran", createdTs: 1_783_000_000))
        _ = try await store.upsertDailyMetrics([day("2026-07-08")], deviceId: "apple-health")
        _ = try await store.upsertMetricSeries([MetricPoint(day: "2026-07-08", key: "sleep_debt_min", value: 5)],
                                               deviceId: "apple-health")
        _ = try await store.upsertAppleDaily([AppleDaily(day: "2026-07-08", steps: 9000, activeKcal: nil,
                                                         basalKcal: nil, vo2max: nil, avgHr: nil, maxHr: nil,
                                                         walkingHr: nil, weightKg: nil)], deviceId: "apple-health")
        return store
    }

    func testDryRunCountsOnlyImportedRows() async throws {
        let store = try await seeded()
        let c = try await store.countImportedWhoopHistory(deviceId: canon)
        XCTAssertEqual(c.dailyMetrics, 2)
        XCTAssertEqual(c.metricSeries, 3)      // sleep_mark is not an imported key
        XCTAssertEqual(c.sleepSessions, 2)     // the manual and the edited night are not counted
        XCTAssertEqual(c.workouts, 1)          // only source "whoop"
        XCTAssertEqual(c.journalEntries, 1)
        XCTAssertEqual(c.total, 9)
        XCTAssertFalse(c.isEmpty)
        XCTAssertEqual(c.firstDay, "2026-07-08")
        // The dry run wrote nothing.
        let again = try await store.countImportedWhoopHistory(deviceId: canon)
        XCTAssertEqual(again, c)
    }

    func testDeleteRemovesImportedRowsAndReportsCounts() async throws {
        let store = try await seeded()
        let removed = try await store.deleteImportedWhoopHistory(deviceId: canon)
        XCTAssertEqual(removed.dailyMetrics, 2)
        XCTAssertEqual(removed.metricSeries, 3)
        XCTAssertEqual(removed.sleepSessions, 2)
        XCTAssertEqual(removed.workouts, 1)
        XCTAssertEqual(removed.journalEntries, 1)
        XCTAssertEqual(removed.firstDay, "2026-07-08")

        let after = try await store.countImportedWhoopHistory(deviceId: canon)
        XCTAssertTrue(after.isEmpty)
        let days = try await store.dailyMetrics(deviceId: canon, from: "0000-01-01", to: "9999-12-31")
        XCTAssertTrue(days.isEmpty)
        let debt = try await store.metricSeries(deviceId: canon, key: "sleep_debt_min", from: "0000-01-01", to: "9999-12-31")
        XCTAssertTrue(debt.isEmpty)
    }

    func testComputedNoopRowsStay() async throws {
        let store = try await seeded()
        try await store.deleteImportedWhoopHistory(deviceId: canon)
        let days = try await store.dailyMetrics(deviceId: noop, from: "0000-01-01", to: "9999-12-31")
        XCTAssertEqual(days.map(\.day), ["2026-11-10"])
        let debt = try await store.metricSeries(deviceId: noop, key: "sleep_debt_min", from: "0000-01-01", to: "9999-12-31")
        XCTAssertEqual(debt.count, 1)
        let avg = try await store.metricSeries(deviceId: noop, key: "avg_hr", from: "0000-01-01", to: "9999-12-31")
        XCTAssertEqual(avg.count, 1)
        let sleeps = try await store.sleepSessions(deviceId: noop, from: 0, to: Int.max, limit: 100)
        XCTAssertEqual(sleeps.count, 1)
        let w = try await store.workouts(deviceId: noop, from: 0, to: Int.max, limit: 100)
        XCTAssertEqual(w.count, 1)
    }

    func testPerSecondStreamsUnderCanonicalIdStay() async throws {
        let store = try await seeded()
        try await store.deleteImportedWhoopHistory(deviceId: canon)
        let hr = try await store.hrSamples(deviceId: canon, from: 0, to: Int.max, limit: 100)
        XCTAssertEqual(hr.count, 2)
        let counts = try await store.storageStats_rowCountsForTest()
        XCTAssertEqual(counts.hr, 2)
        XCTAssertEqual(counts.gravity, 1)
    }

    func testUserEditedAndManualSleepStay() async throws {
        let store = try await seeded()
        try await store.deleteImportedWhoopHistory(deviceId: canon)
        let sleeps = try await store.sleepSessions(deviceId: canon, from: 0, to: Int.max, limit: 100)
        XCTAssertEqual(Set(sleeps.map(\.startTs)), [1_783_200_000, 1_783_300_000])
        XCTAssertTrue(sleeps.allSatisfy { $0.userEdited })
    }

    func testManualAndOtherSourceWorkoutsAndUserSeriesStay() async throws {
        let store = try await seeded()
        try await store.deleteImportedWhoopHistory(deviceId: canon)
        let w = try await store.workouts(deviceId: canon, from: 0, to: Int.max, limit: 100)
        XCTAssertEqual(Set(w.map(\.source)), ["manual", "apple-health"])
        let mark = try await store.metricSeries(deviceId: canon, key: "sleep_mark", from: "0000-01-01", to: "9999-12-31")
        XCTAssertEqual(mark.count, 1)
    }

    func testWodsAndAppleHealthStay() async throws {
        let store = try await seeded()
        try await store.deleteImportedWhoopHistory(deviceId: canon)
        let wods = try await store.allWods()
        XCTAssertEqual(wods.map(\.id), ["w1"])
        let apple = try await store.dailyMetrics(deviceId: "apple-health", from: "0000-01-01", to: "9999-12-31")
        XCTAssertEqual(apple.count, 1)
        let appleSeries = try await store.metricSeries(deviceId: "apple-health", key: "sleep_debt_min",
                                                       from: "0000-01-01", to: "9999-12-31")
        XCTAssertEqual(appleSeries.count, 1)
        let ad = try await store.appleDaily(deviceId: "apple-health", from: "0000-01-01", to: "9999-12-31")
        XCTAssertEqual(ad.count, 1)
    }

    func testIdempotent() async throws {
        let store = try await seeded()
        let first = try await store.deleteImportedWhoopHistory(deviceId: canon)
        XCTAssertFalse(first.isEmpty)
        let second = try await store.deleteImportedWhoopHistory(deviceId: canon)
        XCTAssertTrue(second.isEmpty)
        XCTAssertNil(second.firstDay)
        let third = try await store.countImportedWhoopHistory(deviceId: canon)
        XCTAssertTrue(third.isEmpty)
    }

    func testRefusesComputedTwinAndEmptyId() async throws {
        let store = try await seeded()
        do {
            _ = try await store.deleteImportedWhoopHistory(deviceId: noop)
            XCTFail("a -noop id must be refused")
        } catch let e as ImportedWhoopHistoryError {
            XCTAssertEqual(e, .refusedDeviceId(noop))
        }
        do {
            _ = try await store.countImportedWhoopHistory(deviceId: "  ")
            XCTFail("an empty id must be refused")
        } catch is ImportedWhoopHistoryError {
        }
        // Still intact.
        let days = try await store.dailyMetrics(deviceId: noop, from: "0000-01-01", to: "9999-12-31")
        XCTAssertEqual(days.count, 1)
    }
}
