import XCTest
@testable import StrandAnalytics

final class SleepDebtTests: XCTestCase {

    private func day(_ d: Int) -> String { String(format: "2026-06-%02d", d) }

    /// Three nights at need (8 h = 480 min) → no debt, three counted nights.
    func testOnTargetHasNoDebt() {
        let series: [(day: String, totalSleepMin: Double?)] = [
            ("2026-06-01", 480), ("2026-06-02", 480), ("2026-06-03", 480),
        ]
        let l = SleepDebt.ledger(series: series, needHours: 8.0)
        XCTAssertEqual(l.debtMin, 0.0, accuracy: 1e-9)
        XCTAssertEqual(l.nightCount, 3)
        XCTAssertFalse(l.isDebt)
        XCTAssertTrue(l.isOnTarget)
        XCTAssertEqual(l.needMin, 480.0, accuracy: 1e-9)
    }

    /// A long night repays debt already owed, hour for hour.
    func testLongNightRepaysDebt() {
        let series: [(day: String, totalSleepMin: Double?)] = [
            ("2026-06-01", 360),   // −120 → owes 120
            ("2026-06-02", 540),   // +60  → owes 60
            ("2026-06-03", 420),   // −60  → owes 120
        ]
        let l = SleepDebt.ledger(series: series, needHours: 8.0)
        XCTAssertEqual(l.debtMin, 120.0, accuracy: 1e-9)
        XCTAssertTrue(l.isDebt)
        XCTAssertEqual(l.balanceMin, -120.0, accuracy: 1e-9)
        XCTAssertEqual(l.nights.map { $0.deltaMin }, [-120, 60, -60])
        XCTAssertEqual(l.nights.map { $0.debtMin }, [120, 60, 120])
    }

    /// Sleep is not banked: a long night BEFORE a short one doesn't pre-pay it (the old Σ(slept − need)
    /// read this as a +60 min surplus).
    func testLongNightBeforeDebtIsNotBanked() {
        let series: [(day: String, totalSleepMin: Double?)] = [
            ("2026-06-01", 600),   // +120 → owes 0
            ("2026-06-02", 420),   // −60  → owes 60
        ]
        let l = SleepDebt.ledger(series: series, needHours: 8.0)
        XCTAssertEqual(l.debtMin, 60.0, accuracy: 1e-9)
        XCTAssertEqual(l.nights.map { $0.debtMin }, [0, 60])
    }

    /// A fortnight of nights past the need is "no debt", never a growing surplus.
    func testLongNightsNeverReadAsSurplus() {
        let series: [(day: String, totalSleepMin: Double?)] = (1...14).map { (day($0), Double(500 + $0)) }
        let l = SleepDebt.ledger(series: series, needHours: 8.0)
        XCTAssertEqual(l.debtMin, 0.0, accuracy: 1e-9)
        XCTAssertEqual(l.balanceMin, 0.0, accuracy: 1e-9)
        XCTAssertEqual(l.nightCount, 14)
    }

    /// Nights with no usable sleep are skipped entirely (never zero-filled as debt).
    func testSkipsNoDataNights() {
        let series: [(day: String, totalSleepMin: Double?)] = [
            ("2026-06-01", 480),
            ("2026-06-02", nil),     // skipped
            ("2026-06-03", 0),       // skipped (non-positive)
            ("2026-06-04", 420),     // −60
        ]
        let l = SleepDebt.ledger(series: series, needHours: 8.0)
        XCTAssertEqual(l.nightCount, 2)
        XCTAssertEqual(l.debtMin, 60.0, accuracy: 1e-9)
        XCTAssertEqual(l.nights.map { $0.day }, ["2026-06-01", "2026-06-04"])
    }

    /// The window is the last 14 CALENDAR nights ending on the newest night.
    func testWindowIsFourteenCalendarNights() {
        // 16 nights, each 60 min UNDER need.
        let series: [(day: String, totalSleepMin: Double?)] = (1...16).map { (day($0), Double(420)) }
        let l = SleepDebt.ledger(series: series, needHours: 8.0, window: 14)
        XCTAssertEqual(l.nightCount, 14)
        XCTAssertEqual(l.debtMin, 840.0, accuracy: 1e-9)       // 14 × 60
        XCTAssertEqual(l.nights.first?.day, "2026-06-03")       // oldest kept
        XCTAssertEqual(l.nights.last?.day, "2026-06-16")        // newest kept
    }

    /// A gap in the record doesn't stretch the window back: a short night five weeks earlier is out.
    func testGapDoesNotReachBackOverMonths() {
        let series: [(day: String, totalSleepMin: Double?)] = [
            ("2026-05-01", 300),
            ("2026-06-10", 480),
        ]
        let l = SleepDebt.ledger(series: series, needHours: 8.0)
        XCTAssertEqual(l.nightCount, 1)
        XCTAssertEqual(l.debtMin, 0.0, accuracy: 1e-9)
    }

    /// The window crosses a month (and year) boundary by calendar day.
    func testWindowCrossesYearBoundary() {
        let series: [(day: String, totalSleepMin: Double?)] = [
            ("2025-12-18", 300),   // 15 nights before 2026-01-01 → out
            ("2025-12-19", 420),   // 14th night back → in
            ("2026-01-01", 480),
        ]
        let l = SleepDebt.ledger(series: series, needHours: 8.0)
        XCTAssertEqual(l.nights.map { $0.day }, ["2025-12-19", "2026-01-01"])
        XCTAssertEqual(l.debtMin, 60.0, accuracy: 1e-9)
    }

    /// Empty / all-skipped input → empty ledger, zero debt.
    func testEmptyLedger() {
        let l = SleepDebt.ledger(series: [], needHours: 8.0)
        XCTAssertEqual(l.debtMin, 0.0, accuracy: 1e-9)
        XCTAssertEqual(l.nightCount, 0)
        XCTAssertTrue(l.nights.isEmpty)
        XCTAssertTrue(l.repeatedDays.isEmpty)

        let allNil: [(day: String, totalSleepMin: Double?)] = [("2026-06-01", nil)]
        XCTAssertEqual(SleepDebt.ledger(series: allNil).nightCount, 0)
    }

    /// The default need is AnalyticsEngine.Rest.defaultNeedHours (8 h).
    func testDefaultNeedIsEightHours() {
        let l = SleepDebt.ledger(series: [("2026-06-01", 420)])
        XCTAssertEqual(l.needMin, AnalyticsEngine.Rest.defaultNeedHours * 60.0, accuracy: 1e-9)
        XCTAssertEqual(l.debtMin, 60.0, accuracy: 1e-9)
        XCTAssertEqual(SleepDebt.ledger(nights: [SleepNightInput(day: "2026-06-01", totalSleepMin: 420)]).needMin,
                       480.0, accuracy: 1e-9)
    }

    /// A night's own need (the WHOOP export's) wins over the default; the ledger reports the mean need.
    func testPerNightNeedWins() {
        let nights = [
            SleepNightInput(day: "2026-06-01", totalSleepMin: 480, needMin: 540),   // −60
            SleepNightInput(day: "2026-06-02", totalSleepMin: 480),                 // default 480 → 0
        ]
        let l = SleepDebt.ledger(nights: nights, defaultNeedMin: 480)
        XCTAssertEqual(l.debtMin, 60.0, accuracy: 1e-9)
        XCTAssertEqual(l.nights.map { $0.needMin }, [540, 480])
        XCTAssertEqual(l.needMin, 510.0, accuracy: 1e-9)
    }

    /// Nights repeating the night before exactly (total + deep + REM) are copies: excluded and reported,
    /// the first of the run kept. This is the shape of the reported bug: 13 identical nights.
    func testRepeatedStagedNightsAreExcluded() {
        var nights = (1...13).map {
            SleepNightInput(day: day($0), totalSleepMin: 507, deepMin: 150, remMin: 200)
        }
        nights.append(SleepNightInput(day: day(14), totalSleepMin: 395, deepMin: 70, remMin: 90))
        let l = SleepDebt.ledger(nights: nights, defaultNeedMin: 480)
        XCTAssertEqual(l.nights.map { $0.day }, [day(1), day(14)])
        XCTAssertEqual(l.repeatedDays, (2...13).map { day($0) })
        XCTAssertEqual(l.debtMin, 85.0, accuracy: 1e-9)   // 0 after 06-01, then 480 − 395
    }

    /// Without a stage split equal totals can coincide (whole-minute sources), so they are never flagged.
    func testStagelessEqualTotalsAreKept() {
        let series: [(day: String, totalSleepMin: Double?)] = [
            ("2026-06-01", 450), ("2026-06-02", 450), ("2026-06-03", 450), ("2026-06-04", 470),
        ]
        let l = SleepDebt.ledger(series: series)
        XCTAssertTrue(l.repeatedDays.isEmpty)
        XCTAssertEqual(l.nightCount, 4)
    }

    /// Real nights that only share the total (different stages) are not repeats.
    func testSameTotalDifferentStagesIsKept() {
        let nights = [
            SleepNightInput(day: "2026-06-01", totalSleepMin: 450, deepMin: 80, remMin: 100),
            SleepNightInput(day: "2026-06-02", totalSleepMin: 450, deepMin: 95, remMin: 88),
        ]
        XCTAssertTrue(SleepDebt.repeatedDays(nights).isEmpty)
    }

    /// The window still ends on the newest night even when that night is a copy, so a run of copies
    /// can't pull months-old nights into "the last 14 nights".
    func testWindowAnchorsOnNewestNightEvenIfRepeated() {
        var nights = (1...5).map { SleepNightInput(day: day($0), totalSleepMin: 300 + Double($0)) }
        nights += (20...30).map { SleepNightInput(day: day($0), totalSleepMin: 507, deepMin: 150, remMin: 200) }
        let l = SleepDebt.ledger(nights: nights, defaultNeedMin: 480)
        XCTAssertEqual(l.nights.map { $0.day }, [day(20)])
        XCTAssertEqual(l.repeatedDays.count, 10)
        XCTAssertEqual(l.debtMin, 0.0, accuracy: 1e-9)
    }

    /// The history's last point equals the ledger headline; repeated nights get no point.
    func testDebtSeriesMatchesLedger() {
        var nights = (1...20).map {
            SleepNightInput(day: day($0), totalSleepMin: $0 % 3 == 0 ? 540 : 420,
                            deepMin: 60 + Double($0), remMin: 90)
        }
        nights.append(SleepNightInput(day: day(21), totalSleepMin: 420, deepMin: 80, remMin: 90))   // copy of 06-20
        nights.append(SleepNightInput(day: day(22), totalSleepMin: 400, deepMin: 70, remMin: 85))
        let series = SleepDebt.debtSeries(nights: nights, defaultNeedMin: 480)
        let l = SleepDebt.ledger(nights: nights, defaultNeedMin: 480)
        XCTAssertEqual(series.count, 21)
        XCTAssertFalse(series.contains { $0.day == day(21) })
        XCTAssertEqual(series.last?.day, day(22))
        XCTAssertEqual(series.last?.debtMin ?? -1, l.debtMin, accuracy: 1e-9)
        // Every point is the ledger over the 14 nights ending there.
        let atTen = SleepDebt.ledger(nights: Array(nights.prefix(10)), defaultNeedMin: 480)
        XCTAssertEqual(series[9].debtMin, atTen.debtMin, accuracy: 1e-9)
    }

    /// Day keys map to days since 1970-01-01 by plain integer arithmetic.
    func testDayOrdinal() {
        XCTAssertEqual(SleepDebt.dayOrdinal("1970-01-01"), 0)
        XCTAssertEqual(SleepDebt.dayOrdinal("1970-01-02"), 1)
        XCTAssertEqual(SleepDebt.dayOrdinal("2000-03-01"), 11_017)
        XCTAssertEqual(SleepDebt.dayOrdinal("2024-03-01")! - SleepDebt.dayOrdinal("2024-02-28")!, 2)   // leap day
        XCTAssertEqual(SleepDebt.dayOrdinal("2026-01-01")! - SleepDebt.dayOrdinal("2025-12-31")!, 1)
        XCTAssertNil(SleepDebt.dayOrdinal("2026-13-01"))
        XCTAssertNil(SleepDebt.dayOrdinal("not-a-day"))
        XCTAssertNil(SleepDebt.dayOrdinal("2026-06"))
    }

    /// A debt that lands on an exact half-tenth rounds AWAY from zero (0.05 → 0.1), the documented
    /// `round1` contract the Kotlin mirror must match (audit #6).
    func testHalfTieDebtRoundsAwayFromZero() {
        let l = SleepDebt.ledger(series: [("2026-06-01", 0.05)], needHours: 0.1 / 60.0)
        XCTAssertEqual(l.debtMin, 0.1, accuracy: 1e-9)
    }

    /// round1 is pinned on directly-constructed values too, both signs + a non-tie.
    func testRound1HalfTiesAwayFromZero() {
        XCTAssertEqual(SleepDebt.round1(-0.05), -0.1, accuracy: 1e-9)
        XCTAssertEqual(SleepDebt.round1(0.05), 0.1, accuracy: 1e-9)
        XCTAssertEqual(SleepDebt.round1(-0.04), 0.0, accuracy: 1e-9)
        XCTAssertEqual(SleepDebt.round1(-0.25), -0.3, accuracy: 1e-9)
    }
}
