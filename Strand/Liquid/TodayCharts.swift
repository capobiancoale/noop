import SwiftUI
import Charts
import StrandImport
import StrandDesign

// MARK: - Home trend charts (below "Show all metrics")
//
// The charts added under the Key Metrics grid on Today. Kept here (importing Swift Charts directly)
// so LiquidTodayView stays free of Charts. Each takes already-loaded data and draws on the app's dark
// palette, matching the TrendChart idiom (catmullRom lines, hairline grid, tertiary-tinted labels).
//
// Cross-platform on purpose: LiquidTodayView is shared with the macOS target, so these types must exist
// on macOS too (Swift Charts ships on macOS 13+). The iOS-only data source (Apple Health glucose/carbs/
// insulin) is fetched in LiquidTodayView behind `#if os(iOS)`; on macOS those arrays stay empty and the
// charts simply draw what they have. The watch target does not build Strand/, so no watchOS guard.

/// One day's Recovery + Strain scores (0–100) for the 30-day trend.
struct DayScore: Identifiable {
    let id: String        // day key
    let date: Date
    let recovery: Double?
    let strain: Double?
}

/// Recovery vs Strain over ~30 days — two lines on a shared 0–100 scale, so the balance of
/// recovery (charge) against training load (effort) reads at a glance.
struct RecoveryStrainChart: View {
    let points: [DayScore]
    var body: some View {
        Chart {
            ForEach(points) { p in
                if let r = p.recovery {
                    LineMark(x: .value("Day", p.date), y: .value("Score", r),
                             series: .value("Series", "Recovery"))
                        .foregroundStyle(StrandPalette.chargeColor)
                        .interpolationMethod(.catmullRom)
                }
            }
            ForEach(points) { p in
                if let s = p.strain {
                    LineMark(x: .value("Day", p.date), y: .value("Score", s),
                             series: .value("Series", "Strain"))
                        .foregroundStyle(StrandPalette.effortColor)
                        .interpolationMethod(.catmullRom)
                }
            }
        }
        .chartYScale(domain: 0...100)
        .chartPlotStyle { plotArea in plotArea.clipped() }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(StrandPalette.hairline.opacity(0.4))
                AxisValueLabel().foregroundStyle(StrandPalette.textTertiary).font(StrandFont.footnote)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 50, 100]) { _ in
                AxisGridLine().foregroundStyle(StrandPalette.hairline.opacity(0.4))
                AxisValueLabel().foregroundStyle(StrandPalette.textTertiary).font(StrandFont.footnote)
            }
        }
        .frame(height: 150)
    }
}

// MARK: - Intraday cross chart ("Heart & Glucose")

/// One heart-rate sample (a 5-min strap bucket) at a moment of the day. Named to avoid the public
/// `HRSample` in WhoopProtocol (a raw stream sample) — this is a plotting point for the home chart only.
struct CrossHRPoint: Identifiable {
    let id = UUID()
    let date: Date
    let bpm: Double
}

/// A workout window, drawn as a shaded band behind the lines so the effort periods read at a glance.
struct WorkoutBand: Identifiable {
    let id = UUID()
    let start: Date
    let end: Date
}

/// Today's heart rate + glucose crossed on one time axis, with training windows shaded and carb / bolus
/// moments marked. Two independent series (bpm and mg/dL) share the plot by normalising each to 0…1 and
/// carrying its own axis — heart on the left (rose), glucose on the right (cyan). It's a *descriptive*
/// overlay, never a forecast: no insulin-on-board / carb-on-board model, and dosing stays with the user
/// and Loop. Degrades gracefully — draws whichever series has data, hides the axis of one that doesn't.
struct TodayCrossChart: View {
    let hr: [CrossHRPoint]
    let glucose: [GlucoseReading]
    let carbs: [CarbEntry]
    let boluses: [InsulinEntry]
    let workouts: [WorkoutBand]

    // Fixed, clinically-legible glucose display range (mg/dL); heart range is 40 up to just past the
    // day's peak so the line uses the full height without clipping.
    private let glLo = 40.0, glHi = 300.0
    private var hrLo: Double { 40 }
    private var hrHi: Double { max(180, ((hr.map(\.bpm).max() ?? 0) / 10).rounded(.up) * 10) }

    private var hasHR: Bool { hr.count >= 2 }
    private var hasGlucose: Bool { glucose.count >= 2 }

    private func nHR(_ v: Double) -> Double { clamp01((v - hrLo) / (hrHi - hrLo)) }
    private func nGl(_ v: Double) -> Double { clamp01((v - glLo) / (glHi - glLo)) }

    var body: some View {
        Chart {
            // Training windows — a soft effort-tinted band behind everything.
            ForEach(workouts) { w in
                RectangleMark(xStart: .value("Start", w.start), xEnd: .value("End", w.end))
                    .foregroundStyle(StrandPalette.effortColor.opacity(0.12))
            }
            // Glucose in-range band 70–180 mg/dL, so time-in-range reads without numbers.
            if hasGlucose {
                RectangleMark(yStart: .value("lo", nGl(70)), yEnd: .value("hi", nGl(180)))
                    .foregroundStyle(StrandPalette.accent.opacity(0.06))
            }
            // Heart-rate line (left axis).
            if hasHR {
                ForEach(hr) { p in
                    LineMark(x: .value("Time", p.date), y: .value("v", nHR(p.bpm)),
                             series: .value("s", "Heart"))
                        .foregroundStyle(StrandPalette.metricRose)
                        .interpolationMethod(.catmullRom)
                }
            }
            // Glucose line (right axis).
            if hasGlucose {
                ForEach(glucose, id: \.ts) { g in
                    LineMark(x: .value("Time", Date(timeIntervalSince1970: g.ts)),
                             y: .value("v", nGl(g.mgdl)), series: .value("s", "Glucose"))
                        .foregroundStyle(StrandPalette.accent)
                        .interpolationMethod(.catmullRom)
                }
            }
            // Carb intake — amber dots near the baseline.
            ForEach(carbs, id: \.ts) { c in
                PointMark(x: .value("Time", Date(timeIntervalSince1970: c.ts)), y: .value("v", 0.05))
                    .symbolSize(45)
                    .symbol(.circle)
                    .foregroundStyle(StrandPalette.metricAmber)
            }
            // Bolus insulin — violet diamonds just above the carbs.
            ForEach(boluses, id: \.ts) { b in
                PointMark(x: .value("Time", Date(timeIntervalSince1970: b.ts)), y: .value("v", 0.12))
                    .symbolSize(40)
                    .symbol(.diamond)
                    .foregroundStyle(StrandPalette.metricPurple)
            }
        }
        .chartYScale(domain: 0...1)
        .chartPlotStyle { plotArea in plotArea.clipped() }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(StrandPalette.hairline.opacity(0.4))
                AxisValueLabel(format: .dateTime.hour())
                    .foregroundStyle(StrandPalette.textTertiary).font(StrandFont.footnote)
            }
        }
        .chartYAxis {
            if hasHR {
                AxisMarks(position: .leading, values: hrTicks.map(nHR)) { value in
                    AxisGridLine().foregroundStyle(StrandPalette.hairline.opacity(0.3))
                    AxisValueLabel {
                        if let p = value.as(Double.self) {
                            Text("\(Int((hrLo + p * (hrHi - hrLo)).rounded()))")
                        }
                    }
                    .foregroundStyle(StrandPalette.metricRose).font(StrandFont.footnote)
                }
            }
            if hasGlucose {
                AxisMarks(position: .trailing, values: glTicks.map(nGl)) { value in
                    AxisValueLabel {
                        if let p = value.as(Double.self) {
                            Text("\(Int((glLo + p * (glHi - glLo)).rounded()))")
                        }
                    }
                    .foregroundStyle(StrandPalette.accent).font(StrandFont.footnote)
                }
            }
        }
        .frame(height: 170)
    }

    /// Heart-rate axis ticks (bpm): a low/mid/high spread, plus 180 when the peak reaches it.
    private var hrTicks: [Double] {
        var t: [Double] = [60, 100, 140]
        if hrHi >= 180 { t.append(180) }
        return t
    }
    /// Glucose axis ticks (mg/dL): the low-alert, upper-target and a high mark.
    private var glTicks: [Double] { [70, 180, 250] }
}

/// Clamp to the unit interval so an out-of-range reading can't push a mark outside the plot.
private func clamp01(_ v: Double) -> Double { min(1, max(0, v)) }
