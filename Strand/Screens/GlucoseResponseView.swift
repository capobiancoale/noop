import SwiftUI
import Charts
import WhoopStore
import StrandImport
import StrandDesign
import StrandAnalytics

// MARK: - How you respond (glucose around training)
//
// How the athlete's glucose behaved around their sessions of the last 90 days, per kind of session (Strength,
// Metcon, Long). DESCRIPTIVE ONLY: it shows what happened in the data. It never suggests insulin,
// carbohydrates or any therapy change, and a kind with too few sessions shows no number at all.
//
// The maths is `GlucoseTrainingResponse` (StrandAnalytics, pure and tested). This file loads the sessions
// (logged WODs with a session span, plus recorded workouts that do not overlap one) and the glucose around
// them from Apple Health, then draws the result. Compiled on iOS and macOS: on the Mac there is no Apple
// Health, so the screen shows its empty state.

// MARK: - Loading helpers (pure, tested in StrandTests/GlucoseResponseViewTests.swift)

enum GlucoseResponseLoader {
    typealias G = GlucoseTrainingResponse

    /// Look-back of the screen.
    static let days = 90
    /// Sessions shorter or longer than this are not read as training sessions (a 3-minute blip, an all-day
    /// import).
    static let minSessionMinutes = 10.0
    static let maxSessionMinutes = 480.0
    /// Sport names that are not a training response worth reading (they would all land in "Metcon").
    private static let skippedSports = ["walk", "yoga", "stretch", "mobility", "pilates", "mind", "cooldown"]

    /// The sessions of the last `days` days: every logged WOD with a span (the span the user set, else the
    /// recorded workout it matches), then every recorded workout that overlaps neither a WOD nor an earlier
    /// workout. Sorted by start.
    static func sessions(wods: [WodLogRow], workouts: [WorkoutRow], nowTs: Int, days: Int = days) -> [G.Session] {
        let cutoff = nowTs - days * 86_400
        let recorded = workouts.map { (start: Double($0.startTs), end: Double($0.endTs)) }
        var out: [G.Session] = []
        var taken: [(start: Int, end: Int)] = []

        for w in wods where w.ts >= cutoff && w.ts <= nowTs {
            var span = w.sessionSpan
            if span == nil {
                let win = WodTimeWindow.resolve(loggedTs: Double(w.ts),
                                                durationS: (w.resultSeconds ?? w.timeCapS).map(Double.init),
                                                workouts: recorded)
                if win.recorded { span = (Int(win.start), Int(win.end)) }
            }
            // A WOD with no known span is left out: its end would be a guess.
            guard let sp = span else { continue }
            taken.append((sp.start, sp.end))
            guard plausible(start: sp.start, end: sp.end), sp.end <= nowTs else { continue }
            let minutes = Double(sp.end - sp.start) / 60
            let kind = G.kind(sport: w.type, wodType: w.type, wodFormat: w.format, durationMin: minutes)
            out.append(G.Session(id: "wod-\(w.id)", kind: kind, start: Double(sp.start), end: Double(sp.end)))
        }

        for r in workouts.sorted(by: { $0.startTs < $1.startTs }) where r.startTs >= cutoff && r.endTs <= nowTs {
            guard plausible(start: r.startTs, end: r.endTs), !isSkippedSport(r.sport) else { continue }
            if taken.contains(where: { r.startTs < $0.end && r.endTs > $0.start }) { continue }
            taken.append((r.startTs, r.endTs))
            let minutes = Double(r.endTs - r.startTs) / 60
            let kind = G.kind(sport: r.sport, wodType: nil, wodFormat: nil, durationMin: minutes)
            out.append(G.Session(id: "wk-\(r.startTs)-\(r.sport)", kind: kind,
                                 start: Double(r.startTs), end: Double(r.endTs)))
        }
        return out.sorted { $0.start < $1.start }
    }

    static func plausible(start: Int, end: Int) -> Bool {
        guard end > start else { return false }
        let m = Double(end - start) / 60
        return m >= minSessionMinutes && m <= maxSessionMinutes
    }

    static func isSkippedSport(_ sport: String) -> Bool {
        let s = sport.lowercased()
        return skippedSports.contains { s.contains($0) }
    }

    /// The night after a session: from 23:00 local (or the end of the session when it ends later, or in the
    /// small hours) to 07:00 local. Nil when the calendar cannot build the times.
    static func nightWindow(after end: Date, calendar: Calendar) -> G.NightWindow? {
        let hour = calendar.component(.hour, from: end)
        let dayStart = calendar.startOfDay(for: end)
        let morningDay: Date?
        let start: Date
        if hour < 7 {
            morningDay = dayStart
            start = end
        } else {
            morningDay = calendar.date(byAdding: .day, value: 1, to: dayStart)
            let eleven = calendar.date(bySettingHour: 23, minute: 0, second: 0, of: end) ?? end
            start = max(end, eleven)
        }
        guard let md = morningDay, let seven = calendar.date(bySettingHour: 7, minute: 0, second: 0, of: md),
              seven > start else { return nil }
        return G.NightWindow(start: start.timeIntervalSince1970, end: seven.timeIntervalSince1970)
    }

    /// The night to look at for a session; nil while that night is not over yet.
    static func night(for s: G.Session, nowTs: Double, calendar: Calendar) -> G.NightWindow? {
        guard let n = nightWindow(after: Date(timeIntervalSince1970: s.end), calendar: calendar),
              n.end <= nowTs else { return nil }
        return n
    }

    /// The glucose window to read for a session: 1 h (+15 min) before the start to 6 h (+15 min) after the
    /// end, or to the end of the night after it when that is later; never past `nowTs`.
    static func fetchWindow(for s: G.Session, nowTs: Double, calendar: Calendar) -> ClosedRange<Double> {
        let lo = s.start - G.windowBefore - G.maxGapSeconds
        var hi = s.end + G.windowAfter + G.maxGapSeconds
        if let n = night(for: s, nowTs: nowTs, calendar: calendar) { hi = max(hi, n.end + G.maxGapSeconds) }
        return lo...max(lo, min(hi, nowTs))
    }

    /// The fewest reads that cover every session's window: overlapping windows merged, then cut into pieces
    /// of at most `maxSpanDays` days (so one read stays small and the progress bar moves).
    static func fetchRanges(for sessions: [G.Session], nowTs: Double, calendar: Calendar,
                            maxSpanDays: Double = 10) -> [ClosedRange<Double>] {
        let windows = sessions.map { fetchWindow(for: $0, nowTs: nowTs, calendar: calendar) }
            .sorted { $0.lowerBound < $1.lowerBound }
        var merged: [ClosedRange<Double>] = []
        for w in windows {
            if let last = merged.last, w.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, w.upperBound)
            } else {
                merged.append(w)
            }
        }
        let cut = maxSpanDays * 86_400
        var out: [ClosedRange<Double>] = []
        for m in merged {
            var lo = m.lowerBound
            while lo < m.upperBound {
                let hi = min(m.upperBound, lo + cut)
                out.append(lo...hi)
                lo = hi
            }
        }
        return out
    }

    /// The points of sorted `pts` with `from <= ts <= to`.
    static func slice(_ pts: [G.Point], from: Double, to: Double) -> ArraySlice<G.Point> {
        var lo = 0, hi = pts.count
        while lo < hi { let m = (lo + hi) / 2; if pts[m].ts < from { lo = m + 1 } else { hi = m } }
        var end = lo
        while end < pts.count, pts[end].ts <= to { end += 1 }
        return pts[lo..<end]
    }

    /// Sorted, de-duplicated points from raw readings.
    static func points(from readings: [(ts: Double, mgdl: Double)]) -> [G.Point] {
        var seen = Set<Double>()
        return readings.sorted { $0.ts < $1.ts }
            .filter { seen.insert($0.ts).inserted }
            .map { G.Point(ts: $0.ts, mgdl: $0.mgdl) }
    }

    /// One engine input per session, with the points around it.
    static func inputs(sessions: [G.Session], points: [G.Point], nowTs: Double, calendar: Calendar) -> [G.Input] {
        sessions.map { s in
            let w = fetchWindow(for: s, nowTs: nowTs, calendar: calendar)
            return G.Input(session: s, points: Array(slice(points, from: w.lowerBound, to: w.upperBound)),
                           night: night(for: s, nowTs: nowTs, calendar: calendar))
        }
    }
}

// MARK: - Text

private enum GlucoseResponseText {
    /// "+12", "-8", "0": whole mg/dL with the locale's digits and minus sign.
    static func signed(_ v: Double) -> String {
        Int(v.rounded()).formatted(.number.sign(strategy: .always(includingZero: false)))
    }

    static func mgdl(_ v: Double) -> String {
        let n = signed(v)
        return String(localized: "\(n) mg/dL")
    }

    static func level(_ v: Double) -> String {
        let n = Int(v.rounded()).formatted(.number.grouping(.never))
        return String(localized: "\(n) mg/dL")
    }

    static func hours(_ h: Double) -> String {
        let n = Int(h.rounded()).formatted(.number.sign(strategy: .always(includingZero: false)))
        return n + " h"
    }

    static func name(_ k: GlucoseTrainingResponse.Kind) -> String {
        switch k {
        case .strength: return String(localized: "Strength")
        case .metcon:   return String(localized: "Metcon")
        case .long:     return String(localized: "Long")
        }
    }

    static func tint(_ delta: Double?) -> Color {
        guard let d = delta else { return StrandPalette.textPrimary }
        if d > 0.5 { return StrandPalette.statusWarning }
        if d < -0.5 { return StrandPalette.effortColor }
        return StrandPalette.textPrimary
    }
}

// MARK: - Screen

struct GlucoseResponseView: View {
    @EnvironmentObject private var repo: Repository
    #if os(iOS)
    /// Apple Health, read through and never observed (HealthBridgeEnvironment.swift). Absent on macOS.
    @Environment(\.healthBridge) private var health
    #endif

    private enum Phase: Equatable {
        case loading
        case noHealth        // no Apple Health here (the Mac, or no bridge)
        case noSessions
        case noGlucose
        case ready
    }

    @State private var phase: Phase = .loading
    @State private var progress = 0.0
    @State private var summaries: [GlucoseTrainingResponse.Summary] = []
    @State private var kind: GlucoseTrainingResponse.Kind = .strength

    init() {}

    var body: some View {
        ScreenScaffold(title: "How you respond",
                       subtitle: "Your glucose around training, last 90 days",
                       onRefresh: { await load() },
                       topBackground: liquidScaffoldSky()) {
            AnyView(content)
        }
        .task { await load() }
    }

    @ViewBuilder private var content: some View {
        switch phase {
        case .loading:
            loadingCard
        case .noHealth:
            messageCard(symbol: "heart.text.square",
                        text: String(localized: "Glucose from Apple Health is only available on iPhone, so there is nothing to show here."))
            footnote
        case .noSessions:
            messageCard(symbol: "figure.strengthtraining.traditional",
                        text: String(localized: "No training sessions in the last 90 days. Log a WOD or a workout and it will appear here."))
            footnote
        case .noGlucose:
            messageCard(symbol: "drop",
                        text: String(localized: "No glucose readings in Apple Health around your sessions in the last 90 days."))
            footnote
        case .ready:
            readyContent
        }
    }

    // MARK: Ready

    @ViewBuilder private var readyContent: some View {
        KindPicker(selection: $kind)
        if let s = summaries.first(where: { $0.kind == kind }) {
            if s.isReliable {
                curveCard(s)
                tilesRow(s)
            } else {
                insufficientCard(s)
            }
            comparisonCard
            sessionsCaption(s)
        }
        footnote
    }

    private func curveCard(_ s: GlucoseTrainingResponse.Summary) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Around a session", overline: "Glucose")
            NoopCard(tint: StrandPalette.accent) {
                ResponseCurveChart(summary: s)
            }
        }
    }

    private func tilesRow(_ s: GlucoseTrainingResponse.Summary) -> some View {
        HStack(alignment: .top, spacing: 8) {
            ResponseTile(title: String(localized: "During"),
                         value: s.meanDuringDelta.map(GlucoseResponseText.mgdl),
                         caption: String(localized: "Average change, start to end"),
                         tint: GlucoseResponseText.tint(s.meanDuringDelta))
            ResponseTile(title: String(localized: "In the 2 h after"),
                         value: s.meanAfter2hDelta.map(GlucoseResponseText.mgdl),
                         caption: String(localized: "Average change from the end"),
                         tint: GlucoseResponseText.tint(s.meanAfter2hDelta))
            ResponseTile(title: String(localized: "Night after"),
                         value: s.nightsReliable
                            ? String(localized: "\(s.nightsWithLow) of \(s.nightsObserved) with a low") : nil,
                         caption: String(localized: "Below 70 mg/dL, 23:00 to 07:00"),
                         tint: StrandPalette.textPrimary, compactValue: true)
        }
    }

    private func insufficientCard(_ s: GlucoseTrainingResponse.Summary) -> some View {
        let needed = GlucoseTrainingResponse.minSessions
        let have = s.sessions
        return messageCard(symbol: "chart.line.uptrend.xyaxis",
                           text: String(localized: "\(needed) sessions with good glucose data are needed; you have \(have)"))
    }

    private var comparisonCard: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Compared", overline: "In the 2 h after")
            NoopCard {
                ResponseComparison(summaries: summaries)
            }
        }
    }

    private func sessionsCaption(_ s: GlucoseTrainingResponse.Summary) -> some View {
        let used = s.sessions
        let left = s.excluded
        let text = left == 0
            ? String(localized: "Sessions used: \(used).")
            : String(localized: "Sessions used: \(used). Left out for too little glucose data: \(left).")
        return Text(verbatim: text)
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
    }

    // MARK: Other states

    private var loadingCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Reading from Apple Health…")
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                }
                ProgressView(value: progress)
                    .tint(StrandPalette.accent)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func messageCard(symbol: String, text: String) -> some View {
        NoopCard(padding: 20, tint: StrandPalette.accent) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(StrandPalette.accent)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                Text(verbatim: text)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var footnote: some View {
        Text("This describes what happened in your data. It is not advice on insulin or carbohydrates: those choices stay with you, your care team and Loop.")
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
    }

    // MARK: Loading

    /// Reads the glucose of one window; nil where this device has no Apple Health.
    private var readingProvider: ((Date, Date) async -> [GlucoseReading])? {
        #if os(iOS)
        guard let health else { return nil }
        return { start, end in await health.glucoseWindow(start: start, end: end) }
        #else
        return nil
        #endif
    }

    @MainActor private func load() async {
        let nowDate = Date()
        let nowTs = nowDate.timeIntervalSince1970
        progress = 0
        if summaries.isEmpty { phase = .loading }

        let wods = await repo.allWods()
        let workouts = await repo.workoutRows(days: GlucoseResponseLoader.days + 2, reconcileHr: false)
        let sessions = GlucoseResponseLoader.sessions(wods: wods, workouts: workouts, nowTs: Int(nowTs))
        guard !sessions.isEmpty else { phase = .noSessions; return }
        guard let read = readingProvider else { phase = .noHealth; return }

        let calendar = Calendar.current
        let ranges = GlucoseResponseLoader.fetchRanges(for: sessions, nowTs: nowTs, calendar: calendar)
        var raw: [(ts: Double, mgdl: Double)] = []
        for (i, r) in ranges.enumerated() {
            let readings = await read(Date(timeIntervalSince1970: r.lowerBound), Date(timeIntervalSince1970: r.upperBound))
            raw += readings.map { (ts: $0.ts, mgdl: $0.mgdl) }
            progress = Double(i + 1) / Double(max(1, ranges.count))
        }
        guard !raw.isEmpty else { phase = .noGlucose; return }

        // The maths is pure: run it off the main actor, once.
        let rawReadings = raw
        let result = await Task.detached(priority: .userInitiated) { () -> [GlucoseTrainingResponse.Summary] in
            let points = GlucoseResponseLoader.points(from: rawReadings)
            let inputs = GlucoseResponseLoader.inputs(sessions: sessions, points: points, nowTs: nowTs, calendar: calendar)
            return GlucoseTrainingResponse.analyze(inputs)
        }.value

        summaries = result
        // Open on the kind with the most sessions behind it.
        if let best = result.max(by: { $0.sessions < $1.sessions }), best.sessions > 0 { kind = best.kind }
        phase = .ready
    }
}

// MARK: - Kind picker (three pills)

private struct KindPicker: View {
    @Binding var selection: GlucoseTrainingResponse.Kind

    var body: some View {
        HStack(spacing: 8) {
            ForEach(GlucoseTrainingResponse.Kind.allCases, id: \.self) { k in
                pill(k)
            }
        }
    }

    private func pill(_ k: GlucoseTrainingResponse.Kind) -> some View {
        let on = selection == k
        return Button { selection = k } label: {
            Text(verbatim: GlucoseResponseText.name(k))
                .font(StrandFont.subhead.weight(.semibold))
                .foregroundStyle(on ? StrandPalette.accent : StrandPalette.textSecondary)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(on ? StrandPalette.accent.opacity(0.16) : StrandPalette.surfaceInset.opacity(0.6),
                            in: Capsule(style: .continuous))
                .overlay(Capsule(style: .continuous)
                    .strokeBorder(on ? StrandPalette.accent.opacity(0.5) : Color.clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

// MARK: - Tile

private struct ResponseTile: View {
    let title: String
    /// nil: not enough data, shown as a dash and spoken as "not enough data".
    let value: String?
    let caption: String
    let tint: Color
    var compactValue = false

    var body: some View {
        NoopCard(padding: 12, tint: tint) {
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: title)
                    .font(StrandFont.footnote.weight(.semibold))
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: value ?? "–")
                    .font(compactValue ? StrandFont.number(16) : StrandFont.number(20))
                    .foregroundStyle(tint)
                    .lineLimit(compactValue ? 3 : 1)
                    .minimumScaleFactor(0.6)
                Text(verbatim: caption)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: title + ": " + (value ?? String(localized: "not enough data")) + ". " + caption))
    }
}

// MARK: - Mean curve

private struct ResponseCurveChart: View {
    let summary: GlucoseTrainingResponse.Summary

    private struct Pt: Identifiable {
        let id: Int
        let hour: Double
        let mean: Double
        let lo: Double
        let hi: Double
        let segment: Int
    }

    /// The curve as plottable points; a missing step starts a new segment, so the line is never drawn across it.
    private var points: [Pt] {
        var out: [Pt] = []
        var segment = 0
        var previous: Int?
        for p in summary.curve {
            if let prev = previous, p.minute - prev > 15 { segment += 1 }
            previous = p.minute
            out.append(Pt(id: p.minute, hour: Double(p.minute) / 60, mean: p.mean, lo: p.p25, hi: p.p75, segment: segment))
        }
        return out
    }

    private var yDomain: ClosedRange<Double> {
        let lo = min(70, summary.curve.map(\.p25).min() ?? 70)
        let hi = max(180, summary.curve.map(\.p75).max() ?? 180)
        return (floor((lo - 10) / 10) * 10)...(ceil((hi + 10) / 10) * 10)
    }

    private var durationHours: Double? { summary.medianDurationMin.map { $0 / 60 } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            chart
            Text("The line is the average of your sessions and the light band holds the middle half of them. The green band is 70 to 180 mg/dL; the blue block is the typical length of a session.")
                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Hours are counted from the start of the session.")
                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
        }
    }

    private var chart: some View {
        let pts = points
        return Chart {
            RectangleMark(yStart: .value("Target low", 70.0), yEnd: .value("Target high", 180.0))
                .foregroundStyle(StrandPalette.statusPositive.opacity(0.12))
            if let d = durationHours {
                RectangleMark(xStart: .value("Start", 0.0), xEnd: .value("End", d))
                    .foregroundStyle(StrandPalette.effortColor.opacity(0.14))
            }
            ForEach(pts) { p in
                AreaMark(x: .value("Hour", p.hour), yStart: .value("Lower quartile", p.lo),
                         yEnd: .value("Upper quartile", p.hi), series: .value("Segment", p.segment))
                    .foregroundStyle(StrandPalette.accent.opacity(0.18))
                    .interpolationMethod(.monotone)
            }
            ForEach(pts) { p in
                LineMark(x: .value("Hour", p.hour), y: .value("Glucose", p.mean), series: .value("Segment", p.segment))
                    .foregroundStyle(StrandPalette.accent)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .interpolationMethod(.monotone)
            }
        }
        .chartXScale(domain: -1.0...6.0)
        .chartYScale(domain: yDomain)
        .chartXAxis {
            AxisMarks(values: Array(stride(from: -1.0, through: 6.0, by: 1.0))) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(StrandPalette.hairline)
                AxisValueLabel {
                    if let h = value.as(Double.self) { Text(verbatim: GlucoseResponseText.hours(h)) }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 5)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(StrandPalette.hairline)
                // The unit on every tick.
                AxisValueLabel {
                    if let v = value.as(Double.self) { Text(verbatim: GlucoseResponseText.level(v)) }
                }
            }
        }
        .frame(height: 230)
        .accessibilityLabel(Text("Average glucose around a session"))
        .accessibilityValue(Text(verbatim: summaryText))
    }

    private var summaryText: String {
        let means = summary.curve.map(\.mean)
        guard let lo = means.min(), let hi = means.max() else { return "" }
        let n = summary.sessions
        let a = Int(lo.rounded()), b = Int(hi.rounded())
        return String(localized: "Over \(n) sessions the average glucose stayed between \(a) and \(b) mg/dL, from one hour before the start to six hours after.")
    }
}

// MARK: - Comparison across kinds

private struct ResponseComparison: View {
    let summaries: [GlucoseTrainingResponse.Summary]

    private var withNumbers: [(kind: GlucoseTrainingResponse.Kind, delta: Double)] {
        summaries.compactMap { s in s.meanAfter2hDelta.map { (kind: s.kind, delta: $0) } }
    }

    private var without: [GlucoseTrainingResponse.Summary] {
        summaries.filter { $0.meanAfter2hDelta == nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if withNumbers.isEmpty {
                Text("Not enough sessions yet to compare the kinds.")
                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                chart
                ForEach(withNumbers, id: \.kind) { item in
                    HStack {
                        Text(verbatim: GlucoseResponseText.name(item.kind))
                            .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                        Spacer()
                        Text(verbatim: GlucoseResponseText.mgdl(item.delta))
                            .font(StrandFont.bodyNumber)
                            .foregroundStyle(GlucoseResponseText.tint(item.delta))
                    }
                }
            }
            ForEach(without, id: \.kind) { s in
                let name = GlucoseResponseText.name(s.kind)
                Text(verbatim: String(localized: "\(name): not enough sessions yet"))
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
            }
            Text("Average change in glucose from the end of a session to two hours later.")
                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var chart: some View {
        Chart {
            RuleMark(y: .value("Zero", 0.0))
                .foregroundStyle(StrandPalette.hairlineStrong)
            ForEach(withNumbers, id: \.kind) { item in
                BarMark(x: .value("Kind", GlucoseResponseText.name(item.kind)),
                        y: .value("Change", item.delta))
                    .foregroundStyle(GlucoseResponseText.tint(item.delta).opacity(0.85))
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(StrandPalette.hairline)
                AxisValueLabel {
                    if let v = value.as(Double.self) { Text(verbatim: GlucoseResponseText.mgdl(v)) }
                }
            }
        }
        .frame(height: 160)
        .accessibilityLabel(Text("Average change in the 2 hours after a session, by kind"))
        .accessibilityValue(Text(verbatim: withNumbers
            .map { GlucoseResponseText.name($0.kind) + " " + GlucoseResponseText.mgdl($0.delta) }
            .joined(separator: ", ")))
    }
}
