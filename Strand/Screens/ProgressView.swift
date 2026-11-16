import SwiftUI
import StrandDesign
import StrandAnalytics

// MARK: - Progress ("Am I improving?")
//
// One card, five rows: strength, engine (VO2max), sleep, recovery (Charge), glucose (time in range). Each row
// compares the average of the chosen period with the period before it (pure maths in
// `StrandAnalytics.ProgressSummary`; this view only builds the words). A row without enough data says so
// instead of showing a number. Below: recent strength records and a one-sentence summary.
// Compiles on iOS and macOS; only the link to the iOS-only Strength screen is guarded.

struct ProgressOverviewView: View {
    @EnvironmentObject private var repo: Repository

    /// A recent personal record, ready to show.
    private struct RecordItem: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let day: String
    }

    /// Everything loaded once; rows are recomputed from it when the period changes.
    private struct Inputs {
        var sleep: [ProgressSummary.Point] = []
        var charge: [ProgressSummary.Point] = []
        var vo2: [ProgressSummary.Point] = []
        var tir: [ProgressSummary.Point] = []
        var strength: [ProgressSummary.Point] = []
        var strengthName = ""
    }

    @State private var windowDays = 84
    @State private var inputs = Inputs()
    @State private var rows: [ProgressSummary.Metric: ProgressSummary.Row] = [:]
    /// Metrics with enough values in the window but none in the period before: a value, no comparison.
    @State private var currents: [ProgressSummary.Metric: (value: Double, series: [Double])] = [:]
    @State private var records: [RecordItem] = []
    @State private var loaded = false

    var body: some View {
        ScreenScaffold(title: "Progress",
                       subtitle: "Are you improving? All in one place",
                       onRefresh: { await load() },
                       topBackground: liquidScaffoldSky()) {
            AnyView(periodPicker)
            AnyView(metricsCard)
            AnyView(recordsCard)
            AnyView(summaryCard)
        }
        .task(id: repo.refreshSeq) { await load() }
    }

    // MARK: Period control

    private static let periods: [(days: Int, label: LocalizedStringKey)] = [
        (28, "4 weeks"), (84, "12 weeks"), (365, "1 year")
    ]

    private var periodPicker: some View {
        HStack(spacing: 6) {
            ForEach(Self.periods, id: \.days) { p in
                periodButton(days: p.days, label: p.label)
            }
        }
        .padding(4)
        .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func periodButton(days: Int, label: LocalizedStringKey) -> some View {
        let on = windowDays == days
        return Button {
            windowDays = days
            recompute()
        } label: {
            Text(label)
                .font(StrandFont.subhead.weight(on ? .semibold : .regular))
                .foregroundStyle(on ? StrandPalette.textPrimary : StrandPalette.textSecondary)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(on ? StrandPalette.hairline : Color.clear,
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: Metrics card

    private var metricsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            NoopCard(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(ProgressSummary.Metric.allCases.enumerated()), id: \.element) { idx, metric in
                        VStack(spacing: 0) {
                            if idx > 0 { Divider().overlay(StrandPalette.hairline) }
                            link(for: metric)
                        }
                    }
                }
                .padding(.horizontal, 18)
            }
            Text("Each number is the average of the period, compared with the period of the same length before it.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
    }

    private func link(for metric: ProgressSummary.Metric) -> some View {
        NavigationLink {
            destination(for: metric)
        } label: {
            ProgressMetricRow(title: title(for: metric), row: rows[metric], metric: metric,
                              current: currents[metric])
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func destination(for metric: ProgressSummary.Metric) -> some View {
        switch metric {
        case .strength:
            #if os(iOS)
            ProgressDetailHost { StrengthProgressView() }
            #else
            ProgressDetailHost { MetricExplorerView() }
            #endif
        case .engine: ProgressDetailHost { VO2maxView() }
        case .sleep: ProgressDetailHost { SleepView() }
        case .recovery: ProgressDetailHost { MetricExplorerView() }
        case .glucose: ProgressDetailHost { GlucoseResponseView() }
        }
    }

    private func title(for metric: ProgressSummary.Metric) -> String {
        switch metric {
        case .strength:
            return inputs.strengthName.isEmpty
                ? String(localized: "Strength · estimated 1RM")
                : String(localized: "Strength · \(inputs.strengthName), estimated 1RM")
        case .engine: return String(localized: "Engine · estimated VO₂max")
        case .sleep: return String(localized: "Sleep · average per night")
        case .recovery: return String(localized: "Recovery · average Charge")
        case .glucose: return String(localized: "Glucose · time in range")
        }
    }

    // MARK: Records card

    private var recordsCard: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Recent records")
            NoopCard {
                if records.isEmpty {
                    Text("No records in this period.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                } else {
                    VStack(spacing: 12) {
                        ForEach(Array(records.enumerated()), id: \.element.id) { idx, r in
                            VStack(spacing: 12) {
                                if idx > 0 { Divider().overlay(StrandPalette.hairline) }
                                recordRow(r)
                            }
                        }
                    }
                }
            }
        }
    }

    private func recordRow(_ r: RecordItem) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: r.title)
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(verbatim: r.subtitle)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            Spacer(minLength: 8)
            Text("PR")
                .font(StrandFont.footnote.weight(.bold))
                .foregroundStyle(StrandPalette.statusPositive)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(StrandPalette.statusPositive.opacity(0.16), in: Capsule(style: .continuous))
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Summary card

    private var summaryCard: some View {
        NoopCard(tint: StrandPalette.accent) {
            VStack(alignment: .leading, spacing: 4) {
                Text("In short")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(verbatim: summaryText)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var summaryText: String {
        let present = ProgressSummary.Metric.allCases.compactMap { rows[$0] }
        switch ProgressSummary.summaryKey(present) {
        case .notEnoughData: return String(localized: "Keep logging: there is not enough data yet to compare.")
        case .allBetter: return String(localized: "Everything you track is going the right way.")
        case .allWorse: return String(localized: "Everything you track is a bit lower than before.")
        case .allStable: return String(localized: "Steady: nothing has moved much.")
        case .betterOnly(let better):
            let names = Self.joined(better)
            return String(localized: "Improving: \(names). The rest is steady.")
        case .worseOnly(let worse):
            let names = Self.joined(worse)
            return String(localized: "Lower than before: \(names). The rest is steady.")
        case .mixed(let better, let worse):
            let up = Self.joined(better), down = Self.joined(worse)
            return String(localized: "Improving: \(up). Lower than before: \(down).")
        }
    }

    private static func joined(_ metrics: [ProgressSummary.Metric]) -> String {
        ListFormatter.localizedString(byJoining: metrics.map(shortName))
    }

    private static func shortName(_ m: ProgressSummary.Metric) -> String {
        switch m {
        case .strength: return String(localized: "strength")
        case .engine: return String(localized: "fitness (VO₂max)")
        case .sleep: return String(localized: "sleep")
        case .recovery: return String(localized: "recovery")
        case .glucose: return String(localized: "glucose")
        }
    }

    // MARK: Data

    private func load() async {
        var next = Inputs()
        next.sleep = repo.days.compactMap { d in
            guard let v = d.totalSleepMin, v > 0 else { return nil }
            return ProgressSummary.Point(day: d.day, value: v)
        }
        next.charge = repo.days.compactMap { d in
            d.recovery.map { ProgressSummary.Point(day: d.day, value: $0) }
        }
        // VO2max: the daily estimate at rest (what VO2maxView charts), else Apple Health's own series.
        let est = await repo.exploreSeries(key: IntelligenceEngine.vo2maxEstimateKey, source: "my-whoop")
        let vo2 = est.isEmpty ? await repo.series(key: "vo2max", source: Repository.appleHealthSource) : est
        next.vo2 = vo2.map { ProgressSummary.Point(day: $0.day, value: $0.value) }
        let tir = await repo.series(key: "glucose_tir", source: Repository.appleHealthSource)
        next.tir = tir.map { ProgressSummary.Point(day: $0.day, value: $0.value) }

        // Strength: the most-logged movement; its estimated 1RM, else the load.
        let movements = StrengthProgress.movements(from: await repo.allWods())
        if let m = movements.max(by: { $0.entries.count < $1.entries.count }) {
            next.strengthName = m.displayName
            next.strength = m.entries.compactMap { e in
                let v = e.estimated1RM ?? e.weightKg
                return v > 0 ? ProgressSummary.Point(day: e.day, value: v) : nil
            }
        }
        allRecords = Self.recordItems(from: movements)
        inputs = next
        loaded = true
        recompute()
    }

    /// Every strength record, newest first (filtered by the period in `recompute`).
    @State private var allRecords: [(item: RecordItem, ts: Int)] = []

    private static func recordItems(from movements: [StrengthProgress.Movement]) -> [(item: RecordItem, ts: Int)] {
        var out: [(item: RecordItem, ts: Int)] = []
        for m in movements {
            for e in m.entries where e.isRecord {
                let kg = e.weightKg.formatted(.number.precision(.fractionLength(0...1)))
                var parts = [dayLabel(e.day)]
                if let s = e.sets, let r = e.reps { parts.append(String(localized: "\(s) × \(r)")) }
                let kgText = String(localized: "\(kg) kg")
                let item = RecordItem(id: "\(m.key)-\(e.wodId)-\(e.ts)",
                                      title: m.displayName + " " + kgText,
                                      subtitle: parts.joined(separator: " · "), day: e.day)
                out.append((item, e.ts))
            }
        }
        return out.sorted { $0.ts > $1.ts }
    }

    private static func dayLabel(_ day: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        guard let d = f.date(from: day) else { return day }
        return d.formatted(.dateTime.day().month(.abbreviated))
    }

    private func recompute() {
        let today = Repository.localDayKey(Date())
        var next: [ProgressSummary.Metric: ProgressSummary.Row] = [:]
        var nextCurrent: [ProgressSummary.Metric: (value: Double, series: [Double])] = [:]
        func put(_ m: ProgressSummary.Metric, _ pts: [ProgressSummary.Point]) {
            if let r = ProgressSummary.row(metric: m, points: pts, today: today, windowDays: windowDays) {
                next[m] = r
            } else if let c = ProgressSummary.currentOnly(metric: m, points: pts, today: today,
                                                          windowDays: windowDays) {
                nextCurrent[m] = c
            }
        }
        put(.strength, inputs.strength)
        put(.engine, inputs.vo2)
        put(.sleep, inputs.sleep)
        put(.recovery, inputs.charge)
        put(.glucose, inputs.tir)
        rows = next
        currents = nextCurrent
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -windowDays, to: Date()) ?? Date()
        let cutoff = Repository.localDayKey(cutoffDate)
        records = allRecords.filter { $0.item.day >= cutoff }.prefix(5).map { $0.item }
    }
}

// MARK: - Row

private struct ProgressMetricRow: View {
    let title: String
    let row: ProgressSummary.Row?
    let metric: ProgressSummary.Metric
    var current: (value: Double, series: [Double])? = nil

    private var tint: Color {
        guard let r = row else { return StrandPalette.textTertiary }
        switch r.direction {
        case .better: return StrandPalette.statusPositive
        case .worse: return StrandPalette.statusWarning
        case .stable: return StrandPalette.textSecondary
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                if let r = row {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(verbatim: valueText(r.value))
                            .font(StrandFont.number(22))
                            .foregroundStyle(StrandPalette.textPrimary)
                            .lineLimit(1).minimumScaleFactor(0.7)
                        Text(verbatim: changeText(r))
                            .font(StrandFont.subhead.weight(.semibold))
                            .foregroundStyle(tint)
                            .lineLimit(1).minimumScaleFactor(0.7)
                    }
                } else if let c = current {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(verbatim: valueText(c.value))
                            .font(StrandFont.number(22))
                            .foregroundStyle(StrandPalette.textPrimary)
                            .lineLimit(1).minimumScaleFactor(0.7)
                        Text("nothing earlier to compare")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .lineLimit(1).minimumScaleFactor(0.7)
                    }
                } else {
                    Text("Not enough data yet")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            }
            Spacer(minLength: 4)
            if let series = row?.series ?? current?.series, series.count > 1 {
                ProgressSparkline(values: series, tint: tint)
                    .frame(width: 96, height: 40)
                    .accessibilityHidden(true)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(StrandPalette.textTertiary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 14)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func num(_ v: Double, _ digits: ClosedRange<Int>) -> String {
        v.formatted(.number.precision(.fractionLength(digits)))
    }

    private func valueText(_ value: Double) -> String {
        switch metric {
        case .strength:
            let n = num(value, 0...1)
            return String(localized: "\(n) kg")
        case .engine: return num(value, 1...1)
        case .sleep:
            let total = Int(value.rounded())
            let h = total / 60, m = total % 60
            return String(localized: "\(h) h \(m) min")
        case .recovery: return num(value, 0...0)
        case .glucose: return num(value, 0...0) + "%"
        }
    }

    private func changeText(_ r: ProgressSummary.Row) -> String {
        if r.direction == .stable { return "= " + String(localized: "steady") }
        let arrow = r.change > 0 ? "▲ " : "▼ "
        let a = abs(r.change)
        switch metric {
        case .strength:
            let n = num(a, 0...1)
            return arrow + String(localized: "\(n) kg")
        case .engine: return arrow + num(a, 1...1)
        case .sleep:
            let n = Int(a.rounded())
            return arrow + String(localized: "\(n) min")
        case .recovery: return arrow + num(a, 0...0)
        case .glucose:
            let n = num(a, 0...1)
            return arrow + String(localized: "\(n) points")
        }
    }
}

// MARK: - Sparkline

private struct ProgressSparkline: View {
    let values: [Double]
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            let pts = Self.points(values, in: geo.size)
            ZStack {
                Path { p in
                    guard let first = pts.first else { return }
                    p.move(to: first)
                    for pt in pts.dropFirst() { p.addLine(to: pt) }
                }
                .stroke(tint, style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
                if let last = pts.last {
                    Circle().fill(tint).frame(width: 6, height: 6)
                        .position(x: last.x, y: last.y)
                }
            }
        }
    }

    /// Scales the values into the box with a 4 pt margin; a flat series sits on the middle line.
    private static func points(_ v: [Double], in size: CGSize) -> [CGPoint] {
        guard v.count > 1, let lo = v.min(), let hi = v.max() else { return [] }
        let span = hi - lo
        let w = max(1, size.width - 8), h = max(1, size.height - 8)
        return v.enumerated().map { i, x in
            let fx = 4 + w * CGFloat(i) / CGFloat(v.count - 1)
            let fy = span > 0 ? 4 + h * CGFloat(1 - (x - lo) / span) : size.height / 2
            return CGPoint(x: fx, y: fy)
        }
    }
}

// MARK: - Pushed detail wrapper

/// Same look the More list gives a pushed screen: surface background, inline bar, transparent bar background.
private struct ProgressDetailHost<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        #if os(iOS)
        content()
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
        #else
        content()
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
        #endif
    }
}
