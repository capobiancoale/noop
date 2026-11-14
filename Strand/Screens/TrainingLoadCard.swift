import SwiftUI
import Charts
import StrandDesign
import StrandAnalytics

// MARK: - Training load: this week vs your usual
//
// How much you trained over the last 7 days compared with the four weeks before them, as a ratio and a
// plain word, plus a bar per rolling week so a climb is easy to see. Shown at the top of the Workouts screen.
// Maths: StrandAnalytics.TrainingLoad (daily Effort turned back into TRIMP, acute ÷ uncoupled chronic).
//
// Informational only. The ratio says how this week compares with your own earlier weeks; it is not an
// injury predictor (Impellizzeri et al. 2020) and the card never says anything about risk.

struct TrainingLoadCard: View {
    let summary: TrainingLoad.Summary

    /// One bar of the chart: a rolling 7-day block, labelled with its last day.
    private struct Bar: Identifiable {
        let id: String
        let label: String
        let load: Double
        let isCurrent: Bool
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Training load", overline: "Last 7 days")
            NoopCard(tint: StrandPalette.effortColor) {
                VStack(alignment: .leading, spacing: 12) {
                    headline
                    loadLine
                    chart
                    Text("Load is your heart-rate training load (TRIMP) including logged WODs. The comparison shows how this week compares with the four weeks before it; it does not predict injury.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Headline

    /// "1,24× your usual" with the band beside it, or "Not enough history yet" when there is no ratio.
    @ViewBuilder private var headline: some View {
        if let ratio = summary.ratio, let band = summary.band {
            let ratioText = DisplayNumber.decimal(ratio, digits: 2)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    ratioHeadline(ratioText)
                    bandBadge(band)
                    Spacer(minLength: 0)
                }
                VStack(alignment: .leading, spacing: 6) {
                    ratioHeadline(ratioText)
                    bandBadge(band)
                }
            }
            .accessibilityElement(children: .combine)
        } else {
            Text("Not enough history yet")
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.textSecondary)
        }
    }

    private func ratioHeadline(_ ratioText: String) -> some View {
        Text("\(ratioText)× your usual")
            .font(StrandFont.number(24))
            .foregroundStyle(StrandPalette.textPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }

    /// The band as a word AND a symbol, so it never rests on colour alone.
    @ViewBuilder private func bandBadge(_ band: TrainingLoad.Band) -> some View {
        switch band {
        case .below:
            bandPill(Label("Below your usual", systemImage: "arrow.down.right"),
                  tint: StrandPalette.textSecondary)
        case .steady:
            bandPill(Label("In line with your usual", systemImage: "equal.circle"),
                  tint: StrandPalette.statusPositive)
        case .higher:
            bandPill(Label("Higher than usual", systemImage: "arrow.up.right"),
                  tint: StrandPalette.statusWarning)
        case .sharpRise:
            bandPill(Label("Sharp rise", systemImage: "exclamationmark.triangle"),
                  tint: StrandPalette.statusCritical)
        }
    }

    private func bandPill(_ label: Label<Text, Image>, tint: Color) -> some View {
        label
            .font(StrandFont.footnote.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(tint.opacity(0.16), in: Capsule(style: .continuous))
    }

    // MARK: - Figures

    /// "7-day load 1.234 · usual week 1.050"; the usual week is left out while it is unknown.
    @ViewBuilder private var loadLine: some View {
        let acute = Self.whole(summary.acute)
        Group {
            if let usual = summary.chronicWeekly {
                Text("7-day load \(acute) · usual week \(Self.whole(usual))")
            } else {
                Text("7-day load \(acute)")
            }
        }
        .font(StrandFont.subhead)
        .foregroundStyle(StrandPalette.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private static func whole(_ v: Double) -> String {
        v.formatted(.number.precision(.fractionLength(0)))
    }

    // MARK: - Chart

    /// The 8 rolling weeks, oldest → newest, each labelled with its last day ("20 Oct", in the user's locale).
    private var bars: [Bar] {
        let count = summary.weeks.count
        return summary.weeks.enumerated().map { index, week in
            Bar(id: week.end, label: Self.dayLabel(week.end), load: week.load, isCurrent: index == count - 1)
        }
    }

    /// Every other label, counting back from the newest, so eight "d MMM" labels never crowd a phone.
    private func tickLabels(_ bars: [Bar]) -> [String] {
        let last = bars.count - 1
        return bars.enumerated().filter { (last - $0.offset) % 2 == 0 }.map { $0.element.label }
    }

    private var chart: some View {
        let bars = self.bars
        let ticks = tickLabels(bars)
        let peak = bars.map(\.load).max() ?? 0
        let top = max(1.0, peak * 1.1)
        let latest = Self.whole(summary.weeks.last?.load ?? 0)
        let highest = Self.whole(peak)
        let spoken = String(localized: "Weekly training load over the last \(bars.count) weeks. This week \(latest), highest \(highest).")
        return Chart {
            ForEach(bars) { bar in
                BarMark(x: .value("Week ending", bar.label),
                        y: .value("Load", bar.load),
                        width: .fixed(14))
                    .foregroundStyle(bar.isCurrent ? StrandPalette.accent : StrandPalette.textTertiary)
                    // All four corners: per-corner radii need a newer OS, and the flat side sits on the baseline.
                    .cornerRadius(4)
            }
        }
        .chartYScale(domain: 0...top)
        .chartXAxis {
            AxisMarks(values: ticks) { _ in
                AxisValueLabel().foregroundStyle(StrandPalette.textTertiary).font(StrandFont.footnote)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(StrandPalette.hairline.opacity(0.6))
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(verbatim: Self.whole(v))
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                }
            }
        }
        .frame(height: 120)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: spoken))
    }

    /// "20 Oct" / "20 ott" for a "yyyy-MM-dd" day key; the key itself if it cannot be read.
    private static func dayLabel(_ key: String) -> String {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return key }
        // Noon, so a day that skips midnight at a daylight-saving change still resolves.
        let comps = DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12)
        guard let date = Calendar.current.date(from: comps) else { return key }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}
