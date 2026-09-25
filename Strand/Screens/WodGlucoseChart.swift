#if os(iOS)
import SwiftUI
import Charts
import StrandDesign
import StrandImport

// MARK: - Glucose around a WOD
//
// The CGM trace on a clock centred on the WOD (model: StrandImport.WodGlucoseTimeline): the WOD's own span
// shaded and labelled, the axis counting hours before its start and after its end (as the panel's
// "2h before → 4h after" says), the 70–180 mg/dL target band, the time below 70 filled, the lowest
// reading labelled, and carbs and bolus insulin as markers on a lane underneath on the same clock (never on
// a second y-axis). Touch and drag reads any point. Informational only: nothing here suggests carbs or
// insulin.

struct WodGlucoseChart: View {
    let timeline: WodGlucoseTimeline
    @State private var selectedMinutes: Double?

    init(timeline: WodGlucoseTimeline) { self.timeline = timeline }

    private static let low = WodGlucoseTimeline.lowThreshold
    private static let high = 180.0
    /// Width of the y-axis labels, the same in both charts so their plots line up.
    private static let axisWidth: CGFloat = 30
    /// The card behind the chart (an inset-grouped list row), for the ring around markers.
    private var surface: Color { Color(uiColor: .secondarySystemGroupedBackground) }

    private var wodEnd: Double { max(timeline.window.durationMinutes, 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            glucoseChart
            if !timeline.carbs.isEmpty || !timeline.boluses.isEmpty { eventLane }
            legend
        }
    }

    // MARK: Glucose

    private var glucoseChart: some View {
        let x = timeline.xDomain, y = timeline.yDomain
        return Chart {
            RectangleMark(xStart: .value("From", x.lowerBound), xEnd: .value("To", x.upperBound),
                          yStart: .value("Target low", Self.low), yEnd: .value("Target high", Self.high))
                .foregroundStyle(StrandPalette.statusPositive.opacity(0.09))
            RectangleMark(xStart: .value("WOD start", 0.0), xEnd: .value("WOD end", wodEnd),
                          yStart: .value("Bottom", y.lowerBound), yEnd: .value("Top", y.upperBound))
                .foregroundStyle(StrandPalette.textTertiary.opacity(0.16))
                .annotation(position: .overlay, alignment: .top) {
                    Text(verbatim: "WOD")
                        .font(StrandFont.footnote.weight(.semibold))
                        .foregroundStyle(StrandPalette.textSecondary)
                        .padding(.top, 2)
                }
            ForEach(timeline.lowArea) { p in
                AreaMark(x: .value("Minutes", p.minutes),
                         yStart: .value("Glucose", p.mgdl),
                         yEnd: .value("Low", Self.low),
                         series: .value("Segment", p.segment))
                    .foregroundStyle(StrandPalette.statusCritical.opacity(0.28))
                    .interpolationMethod(.linear)
            }
            ForEach(timeline.readings) { r in
                LineMark(x: .value("Minutes", r.minutes), y: .value("Glucose", r.mgdl),
                         series: .value("Segment", r.segment))
                    .foregroundStyle(StrandPalette.chartGlucose)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.linear)
            }
            if let n = timeline.nadir {
                PointMark(x: .value("Minutes", n.minutes), y: .value("Glucose", n.mgdl))
                    .symbol { dot(n.mgdl < Self.low ? StrandPalette.statusCritical : StrandPalette.chartGlucose) }
                    .annotation(position: labelSide(n.minutes), alignment: .center, spacing: 4) {
                        Text(verbatim: "\(Int(n.mgdl.rounded()))")
                            .font(StrandFont.captionNumber.weight(.semibold))
                            .foregroundStyle(StrandPalette.textPrimary)
                    }
            }
            if let m = selectedMinutes, let r = nearest(to: m) {
                RuleMark(x: .value("Selected", r.minutes))
                    .foregroundStyle(StrandPalette.textTertiary.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: .top, alignment: .center, spacing: 0,
                                overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        readout(r)
                    }
                PointMark(x: .value("Minutes", r.minutes), y: .value("Glucose", r.mgdl))
                    .symbol { dot(StrandPalette.chartGlucose) }
            }
        }
        .chartXScale(domain: x)
        .chartYScale(domain: y)
        .chartXAxis {
            AxisMarks(values: timeline.ticks.map(\.minutes)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(StrandPalette.hairline)
                AxisValueLabel {
                    if let m = value.as(Double.self) { Text(verbatim: tickLabel(m)) }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: yTicks) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(StrandPalette.hairline)
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(verbatim: "\(Int(v))").frame(width: Self.axisWidth, alignment: .trailing)
                    }
                }
            }
        }
        .chartXSelection(value: $selectedMinutes)
        .frame(height: 190)
        .accessibilityLabel(Text("Glucose around this WOD"))
    }

    /// The lines worth a label: the target range's edges, plus round values up to the top.
    private var yTicks: [Double] {
        [40, Self.low, Self.high, 250, 300, 350].filter { timeline.yDomain.contains($0) }
    }

    /// "−2h" / "−1h" before the WOD's start, "+1h" … "+4h" after its end.
    private func tickLabel(_ minutes: Double) -> String {
        guard let t = timeline.ticks.first(where: { abs($0.minutes - minutes) < 0.5 }) else { return "" }
        return t.anchor == .beforeStart ? "−\(t.hours)h" : "+\(t.hours)h"
    }

    /// A label goes on the side of its point with more room: right in the chart's first half, else left.
    private func labelSide(_ minutes: Double) -> AnnotationPosition {
        let middle = (timeline.xDomain.lowerBound + timeline.xDomain.upperBound) / 2
        return minutes < middle ? .trailing : .leading
    }

    private func nearest(to minutes: Double) -> WodGlucoseTimeline.Reading? {
        timeline.readings.min { abs($0.minutes - minutes) < abs($1.minutes - minutes) }
    }

    /// The reading under the finger: its value, the clock time and where it sits against the WOD.
    private func readout(_ r: WodGlucoseTimeline.Reading) -> some View {
        VStack(spacing: 1) {
            Text(verbatim: "\(Int(r.mgdl.rounded())) mg/dL")
                .font(StrandFont.captionNumber.weight(.semibold))
                .foregroundStyle(StrandPalette.textPrimary)
            Text(verbatim: Date(timeIntervalSince1970: r.ts).formatted(date: .omitted, time: .shortened)
                 + " · " + relative(r.minutes))
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(StrandPalette.surfaceOverlay, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(StrandPalette.hairline, lineWidth: 1))
    }

    private func relative(_ minutes: Double) -> String {
        if minutes < 0 { return String(localized: "\(Int((-minutes).rounded())) min before the WOD") }
        if minutes <= wodEnd { return String(localized: "during the WOD") }
        return String(localized: "\(Int((minutes - wodEnd).rounded())) min after the WOD")
    }

    /// A data marker: filled, with a ring in the card's colour so it stays legible on the line.
    private func dot(_ color: Color) -> some View {
        Circle().fill(color)
            .overlay(Circle().stroke(surface, lineWidth: 2))
            .frame(width: 10, height: 10)
    }

    // MARK: Carbs and bolus insulin

    private var carbsRow: String { String(localized: "Carbs") }
    private var bolusRow: String { String(localized: "Bolus") }

    /// Carbs and boluses on the glucose chart's clock, in a lane of their own: their amounts are grams and
    /// units, so they never share the glucose axis. Its invisible y-axis labels are as wide as the glucose
    /// chart's, so both plots line up.
    private var eventLane: some View {
        Chart {
            RuleMark(x: .value("WOD start", 0.0))
                .foregroundStyle(StrandPalette.textTertiary.opacity(0.35))
            RuleMark(x: .value("WOD end", wodEnd))
                .foregroundStyle(StrandPalette.textTertiary.opacity(0.35))
            ForEach(timeline.carbs) { e in
                PointMark(x: .value("Minutes", e.minutes), y: .value("Kind", carbsRow))
                    .symbol(.circle)
                    .symbolSize(60)
                    .foregroundStyle(StrandPalette.chartCarbs)
                    .annotation(position: .trailing, alignment: .center, spacing: 3) {
                        Text(verbatim: "\(Int(e.amount.rounded())) g")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
            }
            ForEach(timeline.boluses) { e in
                PointMark(x: .value("Minutes", e.minutes), y: .value("Kind", bolusRow))
                    .symbol(.diamond)
                    .symbolSize(60)
                    .foregroundStyle(StrandPalette.chartBolus)
                    .annotation(position: .trailing, alignment: .center, spacing: 3) {
                        Text(verbatim: units(e.amount))
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
            }
        }
        .chartXScale(domain: timeline.xDomain)
        .chartYScale(domain: [carbsRow, bolusRow])
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .leading, values: [carbsRow, bolusRow]) { _ in
                AxisValueLabel { Color.clear.frame(width: Self.axisWidth, height: 1) }
            }
        }
        .frame(height: 44)
        .accessibilityLabel(Text("Carbs and bolus insulin around this WOD"))
    }

    private func units(_ u: Double) -> String {
        (u == u.rounded() ? String(Int(u)) : String(format: "%.1f", u)) + " U"
    }

    // MARK: Legend

    private var legend: some View {
        let first = HStack(spacing: 12) {
            key(RoundedRectangle(cornerRadius: 2).fill(StrandPalette.statusPositive.opacity(0.3)), "70–180")
            if !timeline.lowArea.isEmpty {
                key(RoundedRectangle(cornerRadius: 2).fill(StrandPalette.statusCritical.opacity(0.45)), "< 70")
            }
            key(RoundedRectangle(cornerRadius: 2).fill(StrandPalette.textTertiary.opacity(0.3)), "WOD")
        }
        let second = HStack(spacing: 12) {
            if !timeline.carbs.isEmpty { key(Circle().fill(StrandPalette.chartCarbs), carbsRow) }
            if !timeline.boluses.isEmpty {
                key(Image(systemName: "diamond.fill").resizable().foregroundStyle(StrandPalette.chartBolus), bolusRow)
            }
        }
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { first; second }
            VStack(alignment: .leading, spacing: 4) { first; second }
        }
        .font(StrandFont.footnote)
        .foregroundStyle(StrandPalette.textSecondary)
    }

    private func key(_ swatch: some View, _ label: String) -> some View {
        HStack(spacing: 4) {
            swatch.frame(width: 9, height: 9)
            Text(verbatim: label)
        }
    }
}
#endif
