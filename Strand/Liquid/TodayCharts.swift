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
// on macOS too (Swift Charts ships on macOS 13+). The watch target does not build Strand/, so no watchOS
// guard. The "Heart & Glucose" chart is the zoomable GlucoseHeartTimeline (Screens/GlucoseHeartTimeline.swift).

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
