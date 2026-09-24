import SwiftUI
import Charts
import StrandDesign
import StrandAnalytics

// MARK: - NOOP vs WHOOP
//
// Day-by-day agreement between NOOP's own numbers and the WHOOP export the user imported, reported the
// way the INTERLIVE consensus asks consumer wearables to be validated (Mühlen et al., BJSM 2021): the mean
// difference and the Bland–Altman 95% limits of agreement, each with its confidence interval, a check for
// a difference that changes with the level, then Lin's concordance and the typical error. The maths lives
// in StrandAnalytics.AgreementStats. WHOOP is the benchmark here, not the truth: this is agreement, not
// accuracy.

struct BenchmarkView: View {
    @EnvironmentObject private var repo: Repository
    @State private var range: CompareRange = .quarter
    @State private var rows: [Row] = []
    @State private var loaded = false

    /// Fewer paired days than this and the card only says how many more are needed.
    static let minDays = 7

    struct Row: Identifiable, Sendable {
        let metric: BenchmarkMetric
        let pairs: [AgreementStats.Pair]
        let report: AgreementStats.Report?
        var id: String { metric.rawValue }
    }

    var body: some View {
        ScreenScaffold(title: "NOOP vs WHOOP",
                       subtitle: "How closely NOOP's own numbers agree with your imported WHOOP data, day by day",
                       onRefresh: { await load() }) {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
                SegmentedPillControl(CompareRange.allCases, selection: $range) { $0.label }
                    .accessibilityLabel("Time range")
                if !loaded {
                    ProgressView().frame(maxWidth: .infinity)
                } else if rows.isEmpty {
                    emptyState
                } else {
                    ForEach(rows) { MetricAgreementCard(row: $0) }
                }
                methodNote
            }
        }
        .task(id: range) { await load() }
    }

    private func load() async {
        let pairs = await repo.benchmarkPairs(days: range.days)
        let built = await Task.detached(priority: .userInitiated) {
            BenchmarkMetric.allCases.compactMap { m -> Row? in
                guard let p = pairs[m], !p.isEmpty else { return nil }
                return Row(metric: m, pairs: p, report: p.count >= Self.minDays ? AgreementStats.analyze(p) : nil)
            }
        }.value
        rows = built
        loaded = true
    }

    private var emptyState: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("No paired days yet").font(StrandFont.headline)
                Text("Import your WHOOP export in Data Sources. Every day that has both WHOOP's number and NOOP's own is compared here.")
                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var methodNote: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("How to read this").font(StrandFont.headline)
            // String(localized:) like every other literal with a bare "%" in the app (no format parsing).
            Text(String(localized: "Mean difference is NOOP minus WHOOP. 95% of days fall between the two limits of agreement. The ranges in brackets are 95% confidence intervals: they widen when there are few days or when consecutive days move together, which is taken into account. Concordance (Lin) is 1 when the two agree exactly; below 0.90 is poor, 0.90–0.95 moderate, 0.95–0.99 substantial, above 0.99 almost perfect."))
            Text("WHOOP is the benchmark here, not the truth: good agreement means NOOP behaves like WHOOP, not that either is exact.")
            Text("Methods: INTERLIVE (Mühlen 2021), Bland & Altman 1986 and 1999, Zou 2013 (confidence of the limits), Zięba 2010 (correlated days), Lin 1989 and McBride 2005 (concordance).")
        }
        .font(StrandFont.caption)
        .foregroundStyle(StrandPalette.textTertiary)
    }
}

// MARK: - One metric

private struct MetricAgreementCard: View {
    let row: BenchmarkView.Row

    private var metric: BenchmarkMetric { row.metric }

    private func fmt(_ v: Double, sign: Bool = false) -> String {
        let s = v.formatted(.number.precision(.fractionLength(metric.decimals)))
        return sign && v > 0 ? "+" + s : s
    }

    private func withUnit(_ s: String) -> String { metric.unit.isEmpty ? s : "\(s) \(metric.unit)" }

    var body: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text(metric.title).font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                    Spacer()
                    Text("\(row.pairs.count) days").font(StrandFont.captionNumber).foregroundStyle(StrandPalette.textTertiary)
                }
                if let r = row.report {
                    stats(r)
                    BlandAltmanChart(pairs: row.pairs, report: r)
                        .frame(height: 180)
                } else {
                    Text("Needs at least \(BenchmarkView.minDays) paired days to compare (has \(row.pairs.count)).")
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                }
                if let caveat = metric.caveat {
                    Text(caveat).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private func stats(_ r: AgreementStats.Report) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            line(String(localized: "Mean difference"),
                 withUnit(fmt(r.bias.value, sign: true)),
                 "[\(fmt(r.bias.lower, sign: true)), \(fmt(r.bias.upper, sign: true))]")
            if r.proportionalBias.isSignificant || r.heteroscedasticity.isSignificant {
                let lo = r.limits(atMean: quantile(0.1)), hi = r.limits(atMean: quantile(0.9))
                line(String(localized: "95% of days, low values"),
                     withUnit("\(fmt(lo.lower, sign: true)) … \(fmt(lo.upper, sign: true))"), nil)
                line(String(localized: "95% of days, high values"),
                     withUnit("\(fmt(hi.lower, sign: true)) … \(fmt(hi.upper, sign: true))"), nil)
            } else {
                line(String(localized: "95% of days within"),
                     withUnit("\(fmt(r.lowerLimit.value, sign: true)) … \(fmt(r.upperLimit.value, sign: true))"),
                     "[\(fmt(r.lowerLimit.lower, sign: true)), \(fmt(r.lowerLimit.upper, sign: true))] … [\(fmt(r.upperLimit.lower, sign: true)), \(fmt(r.upperLimit.upper, sign: true))]")
            }
            line(String(localized: "Concordance (Lin)"),
                 "\(r.concordance.value.formatted(.number.precision(.fractionLength(3)))) · \(strengthLabel(r.concordanceStrength))",
                 "[\(r.concordance.lower.formatted(.number.precision(.fractionLength(3)))), \(r.concordance.upper.formatted(.number.precision(.fractionLength(3))))]")
            line(String(localized: "Typical error"),
                 withUnit(fmt(r.meanAbsoluteError)) + (r.meanAbsolutePercentError.map { " · \($0.formatted(.number.precision(.fractionLength(1))))%" } ?? ""),
                 r.within10Percent.map { String(localized: "\(Int(($0 * 100).rounded()))% of days within ±10%") })
            if r.proportionalBias.isSignificant {
                Text(r.proportionalBias.slope.value < 0
                     ? String(localized: "NOOP reads progressively lower than WHOOP as the value rises, so the limits are shown for low and high values.")
                     : String(localized: "NOOP reads progressively higher than WHOOP as the value rises, so the limits are shown for low and high values."))
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.statusWarning)
            } else if r.heteroscedasticity.isSignificant {
                Text("The gap widens as the value rises, so the limits are shown for low and high values.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.statusWarning)
            }
            if r.nEffective < Double(r.n) - 0.5 {
                Text("Consecutive days move together, so these \(r.n) days count as about \(Int(r.nEffective.rounded())) independent ones.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }

    private func line(_ label: String, _ value: String, _ detail: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                Text(value).font(StrandFont.bodyNumber).foregroundStyle(StrandPalette.textPrimary)
                if let detail {
                    Text(detail).font(StrandFont.captionNumber).foregroundStyle(StrandPalette.textTertiary)
                }
            }
        }
    }

    /// Mean of the two methods at a quantile of the observed range (for the non-uniform limits).
    private func quantile(_ q: Double) -> Double {
        let means = row.pairs.map { ($0.reference + $0.test) / 2 }.sorted()
        return means[min(means.count - 1, max(0, Int((Double(means.count - 1) * q).rounded())))]
    }

    private func strengthLabel(_ s: AgreementStats.ConcordanceStrength) -> String {
        switch s {
        case .poor: return String(localized: "poor")
        case .moderate: return String(localized: "moderate")
        case .substantial: return String(localized: "substantial")
        case .almostPerfect: return String(localized: "almost perfect")
        }
    }
}

// MARK: - Bland–Altman plot

/// Difference (NOOP − WHOOP) against the mean of the two, with the bias and the limits of agreement —
/// straight lines when uniform, sloped when the difference changes with the level.
private struct BlandAltmanChart: View {
    let pairs: [AgreementStats.Pair]
    let report: AgreementStats.Report

    private struct Point: Identifiable {
        let id: String
        let mean: Double
        let diff: Double
    }

    private var points: [Point] {
        pairs.map { Point(id: $0.day, mean: ($0.reference + $0.test) / 2, diff: $0.test - $0.reference) }
    }

    private var xRange: (Double, Double) {
        let xs = points.map(\.mean)
        return (xs.min() ?? 0, xs.max() ?? 1)
    }

    var body: some View {
        let (x0, x1) = xRange
        let a = report.limits(atMean: x0), b = report.limits(atMean: x1)
        Chart {
            ForEach(points) { p in
                PointMark(x: .value("Mean", p.mean), y: .value("Difference", p.diff))
                    .foregroundStyle(StrandPalette.accent.opacity(0.7))
                    .symbolSize(22)
            }
            RuleMark(y: .value("Zero", 0))
                .foregroundStyle(StrandPalette.hairlineStrong)
            ForEach([("bias", a.bias, b.bias), ("lower", a.lower, b.lower), ("upper", a.upper, b.upper)], id: \.0) { item in
                LineMark(x: .value("Mean", x0), y: .value("Limit", item.1), series: .value("Line", item.0))
                    .foregroundStyle(item.0 == "bias" ? StrandPalette.textSecondary : StrandPalette.statusWarning)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: item.0 == "bias" ? [] : [5, 4]))
                LineMark(x: .value("Mean", x1), y: .value("Limit", item.2), series: .value("Line", item.0))
                    .foregroundStyle(item.0 == "bias" ? StrandPalette.textSecondary : StrandPalette.statusWarning)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: item.0 == "bias" ? [] : [5, 4]))
            }
        }
        .chartXAxisLabel(String(localized: "Mean of NOOP and WHOOP"))
        .chartYAxisLabel(String(localized: "NOOP − WHOOP"))
        .accessibilityLabel(Text("Bland–Altman plot"))
    }
}
