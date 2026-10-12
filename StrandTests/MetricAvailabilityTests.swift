import XCTest
import WhoopStore
@testable import Strand

/// The Explore "why is this empty" mapping, the always-listed blood-pressure metrics, and the daily
/// derivations behind the on-device sleep / heart-rate metrics. Pure (no store, no UI).
final class MetricAvailabilityTests: XCTestCase {

    /// Every catalog metric gets a non-empty reason and how-to, so an empty metric never shows a blank card.
    func testEveryCatalogMetricHasANote() {
        for metric in MetricCatalog.all {
            let note = MetricAvailability.note(for: metric)
            XCTAssertFalse(note.reason.isEmpty, "\(metric.id) has no reason")
            XCTAssertFalse(note.howTo.isEmpty, "\(metric.id) has no how-to")
        }
    }

    /// Blood oxygen on a WHOOP 5.0/MG is stated as unavailable, never estimated.
    func testSpo2NoteNamesTheStrap() {
        let note = MetricAvailability.note(key: "spo2", source: "my-whoop")
        XCTAssertTrue(note.reason.contains("5.0/MG"))
    }

    /// The same key under different sources gets the note for its own source (carbs: Apple Health vs a CSV).
    func testSameKeyDifferentSourceDifferentNote() {
        let apple = MetricAvailability.note(key: "carbs_g", source: "apple-health")
        let csv = MetricAvailability.note(key: "carbs_g", source: "nutrition-csv")
        XCTAssertNotEqual(apple, csv)
    }

    /// Only measured blood pressure stays listed when empty (it has the in-place "Add a reading" action).
    func testOnlyBloodPressureIsAlwaysListed() {
        let listed = MetricCatalog.all.filter { MetricAvailability.isAlwaysListed($0) }.map(\.key)
        XCTAssertEqual(Set(listed), ["bp_systolic", "bp_diastolic"])
    }

    // MARK: dailyColumn derivations

    private func night(efficiency: Double?, asleep: Double? = 420, deep: Double? = 80, rem: Double? = 100) -> DailyMetric {
        DailyMetric(day: "2026-06-12", totalSleepMin: asleep, efficiency: efficiency, deepMin: deep,
                    remMin: rem, lightMin: 240, disturbances: nil, restingHr: nil, avgHrv: nil,
                    recovery: nil, strain: nil, exerciseCount: nil)
    }

    /// The on-device engine stores efficiency as a 0-1 fraction; the Explore metric is a percent.
    func testSleepEfficiencyIsAPercent() {
        XCTAssertEqual(Repository.dailyColumn(key: "sleep_efficiency", day: night(efficiency: 0.93))!, 93, accuracy: 1e-9)
        // A WHOOP import already stores a percent: left as it is.
        XCTAssertEqual(Repository.dailyColumn(key: "sleep_efficiency", day: night(efficiency: 93))!, 93, accuracy: 1e-9)
        XCTAssertNil(Repository.dailyColumn(key: "sleep_efficiency", day: night(efficiency: nil)))
    }

    func testTimeInBedIsAsleepOverEfficiency() {
        XCTAssertEqual(Repository.dailyColumn(key: "in_bed_min", day: night(efficiency: 0.9, asleep: 450))!, 500, accuracy: 1e-9)
        XCTAssertEqual(Repository.dailyColumn(key: "in_bed_min", day: night(efficiency: 90, asleep: 450))!, 500, accuracy: 1e-9)
        XCTAssertNil(Repository.dailyColumn(key: "in_bed_min", day: night(efficiency: nil)))
        XCTAssertNil(Repository.dailyColumn(key: "in_bed_min", day: night(efficiency: 0.1)), "implausible efficiency")
        XCTAssertNil(Repository.dailyColumn(key: "in_bed_min", day: night(efficiency: 0.9, asleep: nil)))
    }

    func testRestorativeIsDeepPlusRem() {
        let d = night(efficiency: 0.9, asleep: 400, deep: 80, rem: 120)
        XCTAssertEqual(Repository.dailyColumn(key: "restorative_min", day: d)!, 200, accuracy: 1e-9)
        XCTAssertEqual(Repository.dailyColumn(key: "restorative_pct", day: d)!, 50, accuracy: 1e-9)
        XCTAssertNil(Repository.dailyColumn(key: "restorative_min", day: night(efficiency: 0.9, rem: nil)))
        XCTAssertNil(Repository.dailyColumn(key: "restorative_pct", day: night(efficiency: 0.9, asleep: nil)))
    }

    // MARK: Daily heart-rate statistics

    func testDayHeartRateStatsNeedAnHourOfSamples() {
        XCTAssertNil(IntelligenceEngine.dayHeartRateStats([]))
        XCTAssertNil(IntelligenceEngine.dayHeartRateStats(Array(repeating: 70, count: 3_599)))
        let enough = Array(repeating: 60, count: 3_000) + Array(repeating: 100, count: 600)
        let stats = IntelligenceEngine.dayHeartRateStats(enough)
        XCTAssertEqual(stats?.max, 100)
        XCTAssertEqual(stats?.avg ?? 0, (60.0 * 3_000 + 100.0 * 600) / 3_600, accuracy: 1e-9)
    }
}
