import SwiftUI
import Charts
import StrandDesign
import StrandAnalytics

// MARK: - Heart-rate recovery
//
// How fast the heart rate falls after a workout stops and how long it takes to get back near resting:
// the drop after 1 and 2 minutes (Cole et al., N Engl J Med 1999; Shetler et al., J Am Coll Cardiol 2001),
// the heart rate 5, 10 and 30 minutes after, and a chart of the first hour. Shared by a workout's detail and
// a WOD's screen; Today shows a one-line summary of the same result. Maths: StrandAnalytics.HeartRateRecovery.
//
// Informational only. A free-living drop is not a clinical test and depends on how you cool down.

struct HeartRateRecoveryCard: View {
    /// nil: no recovery to show (see `loading`).
    let result: HeartRateRecovery?
    /// True while the result is being read, so the empty state does not flash first.
    let loading: Bool
    /// The 1-minute drop of recent workouts, oldest → newest; the small trend chart shows from 3 points.
    var history: [RecoveryHistoryPoint] = []

    var body: some View {
        NoopCard(tint: StrandPalette.metricRose) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Heart-rate recovery")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                if let r = result {
                    figures(r)
                    curveChart(r)
                    if history.count >= 3 { historyChart }
                } else if loading {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    Text("Not enough heart rate after this workout ended. Keep the strap connected for a while after training.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("How fast your heart rate falls after you stop. A bigger drop in the first minute usually goes with better fitness. Measured in everyday conditions, so cooling down walking or sitting changes it.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Informational only, not medical advice.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }

    // MARK: - Figures

    @ViewBuilder private func figures(_ r: HeartRateRecovery) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let drop = r.hrr1 { dropRow("In 1 minute", drop: drop, speed: r.speed) }
            if let drop = r.hrr2 { dropRow("In 2 minutes", drop: drop, speed: nil) }
            if let bpm = r.bpm(atMinutes: 5) { bpmRow("5 min after", bpm: bpm) }
            if let bpm = r.bpm(atMinutes: 10) { bpmRow("10 min after", bpm: bpm) }
            if let bpm = r.bpm(atMinutes: 30) { bpmRow("30 min after", bpm: bpm) }
            recoveryLine(r)
        }
    }

    private func dropRow(_ title: LocalizedStringKey, drop: Double, speed: HeartRateRecoveryEngine.Speed?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
            if let speed { speedBadge(speed) }
            Spacer(minLength: 8)
            Text(verbatim: Self.dropText(drop))
                .font(StrandFont.number(17))
                .foregroundStyle(StrandPalette.textPrimary)
                .fixedSize()
        }
        .accessibilityElement(children: .combine)
    }

    private func bpmRow(_ title: LocalizedStringKey, bpm: Double) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
            Spacer(minLength: 8)
            Text(verbatim: "\(Int(bpm.rounded())) bpm")
                .font(StrandFont.number(17))
                .foregroundStyle(StrandPalette.textPrimary)
                .fixedSize()
        }
        .accessibilityElement(children: .combine)
    }

    /// A neutral word for the 1-minute drop. Informational, never a verdict, so it is not coloured as good or bad.
    @ViewBuilder private func speedBadge(_ speed: HeartRateRecoveryEngine.Speed) -> some View {
        Group {
            switch speed {
            case .slow: Text("Slow")
            case .typical: Text("Typical")
            case .fast: Text("Fast")
            }
        }
        .font(StrandFont.footnote.weight(.semibold))
        .foregroundStyle(StrandPalette.metricRose)
        .padding(.horizontal, 8).padding(.vertical, 2)
        .background(StrandPalette.metricRose.opacity(0.16), in: Capsule(style: .continuous))
    }

    /// When the heart rate got back near resting, or why that is not known (yet).
    @ViewBuilder private func recoveryLine(_ r: HeartRateRecovery) -> some View {
        if r.recoveryThreshold != nil {
            Group {
                if let m = r.recoveryMinutes {
                    Text("Back to 80% of the way to resting in \(Int(m.rounded())) min")
                } else if r.windowOpen {
                    Text("Still recovering, check back in a few minutes")
                } else if r.observedMinutes >= 30 {
                    Text("Not yet back near resting after \(r.observedMinutes) min")
                } else {
                    Text("Heart rate stopped being recorded after \(r.observedMinutes) min, too short to tell")
                }
            }
            .font(StrandFont.subhead)
            .foregroundStyle(StrandPalette.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// "−28 bpm" for a fall, "+4 bpm" when the heart rate rose, "0 bpm" for no change. Shared with Today's line.
    static func dropText(_ drop: Double) -> String {
        let n = Int(drop.rounded())
        if n > 0 { return "\u{2212}\(n) bpm" }
        if n < 0 { return "+\(-n) bpm" }
        return "0 bpm"
    }

    // MARK: - Charts

    /// The first hour as 15-second medians: the last 2 minutes of the workout, then the fall, with the end of
    /// the workout and the "80% of the way back to resting" level marked. The x axis is the clock time of day
    /// (hours and minutes), so the chart reads against the rest of the day.
    @ViewBuilder private func curveChart(_ r: HeartRateRecovery) -> some View {
        let levels: [Double] = r.recoveryThreshold.map { [$0] } ?? []
        let end = Date(timeIntervalSince1970: TimeInterval(r.endTs))
        VStack(alignment: .leading, spacing: 6) {
            Chart {
                ForEach(r.curve, id: \.seconds) { p in
                    LineMark(x: .value("Time", end.addingTimeInterval(TimeInterval(p.seconds))),
                             y: .value("Heart rate", p.bpm))
                        .foregroundStyle(StrandPalette.metricRose)
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
                RuleMark(x: .value("End", end))
                    .foregroundStyle(StrandPalette.hairlineStrong)
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    // No overflowResolution: it needs macOS 14 and this card is shared with the macOS 13 app.
                    .annotation(position: .top, alignment: .leading, spacing: 2) {
                        Text("End").font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                    }
                ForEach(levels, id: \.self) { level in
                    RuleMark(y: .value("Recovery level", level))
                        .foregroundStyle(StrandPalette.metricRose.opacity(0.7))
                        .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
                }
            }
            .chartYScale(domain: .automatic(includesZero: false))
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.hour().minute())
                }
            }
            .chartYAxisLabel("bpm")
            .frame(height: 170)
            .accessibilityLabel(Text("Heart rate after the workout"))
            if !levels.isEmpty {
                Text("Dashed line: 80% of the way back to resting")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }

    private static func date(_ p: RecoveryHistoryPoint) -> Date {
        Date(timeIntervalSince1970: TimeInterval(p.start))
    }

    /// How the 1-minute drop moved over the last workouts.
    private var historyChart: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("1-minute recovery, one point per recent workout")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
            Chart {
                ForEach(history) { p in
                    LineMark(x: .value("Date", Self.date(p)), y: .value("Drop in 1 minute", p.hrr1))
                        .foregroundStyle(StrandPalette.metricRose.opacity(0.45))
                        .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    PointMark(x: .value("Date", Self.date(p)), y: .value("Drop in 1 minute", p.hrr1))
                        .foregroundStyle(StrandPalette.metricRose)
                        .symbolSize(28)
                }
            }
            .chartYScale(domain: .automatic(includesZero: false))
            .chartYAxisLabel("bpm")
            .frame(height: 110)
            .accessibilityLabel(Text("1-minute recovery, recent workouts"))
        }
    }
}
