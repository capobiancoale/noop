import SwiftUI
import Charts
import StrandDesign
import StrandAnalytics

// MARK: - Night heart rhythm
//
// Last night's beats, screened for a rhythm that is irregular the way atrial fibrillation is, and the same
// screen for the last 14 nights. The strap's beat-to-beat (R-R) intervals during sleep are cut into 128-beat
// segments and each is called irregular only when RMSSD, Shannon entropy and the turning-point ratio all agree
// (Dash et al., Ann Biomed Eng 2009) and the intervals do not simply repeat the way breathing does (NOOP's own
// check); irregular segments that follow one another for 30 minutes or more are an episode, as in the Fitbit
// Heart Study (Lubitz et al., Circulation 2022). Maths and thresholds:
// StrandAnalytics.IrregularRhythm. Data: Repository+IrregularRhythm.
//
// This is a SCREEN, never a diagnosis: only an ECG can confirm atrial fibrillation, and NOOP is not a medical
// device. The words say "irregular rhythm" and "a pattern like atrial fibrillation", never "you have" it; a
// night without enough clean beats says so and what to change, instead of showing a reassuring zero.

struct HeartRhythmCard: View {
    @EnvironmentObject var repo: Repository

    @State private var report: Repository.HeartRhythmReport?
    @State private var loaded = false

    var body: some View {
        NoopCard(tint: StrandPalette.metricRose) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Night heart rhythm")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                content
                notes
            }
        }
        .task(id: repo.refreshSeq) { await load() }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if let night = report?.lastNight {
            verdictBlock(night)
            figures(night.result)
            // The 14-night strip only when at least one of those nights had enough clean beats. With none,
            // it would be an empty 0–10 % chart under 14 open circles; the "not enough data" read above
            // already says it (and what to change), so nothing is drawn.
            if let nights = report?.nights, nights.count >= 2,
               nights.contains(where: { $0.result.verdict != .notEnoughData }) {
                strip(nights)
            }
        } else if loaded {
            Text("No night to look at yet. Wear the strap to bed with NOOP connected, then sync it in the morning.")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            ProgressView().frame(maxWidth: .infinity)
        }
    }

    private func load() async {
        report = await repo.heartRhythmReport()
        loaded = true
    }

    // MARK: Verdict

    private func verdictBlock(_ night: Repository.IrregularRhythmNight) -> some View {
        let r = night.result
        return VStack(alignment: .leading, spacing: 8) {
            nightLabel(night)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: Self.symbol(r.verdict))
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Self.tint(r.verdict))
                    .accessibilityHidden(true)
                verdictTitle(r.verdict)
                    .font(StrandFont.number(22))
                    .foregroundStyle(StrandPalette.textPrimary)
            }
            verdictDetail(r)
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if r.verdict == .irregularEpisode {
                Text("If it happens again, or you notice palpitations, breathlessness or dizziness, talk to your doctor. With severe symptoms such as chest pain or fainting, call emergency services.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// "Last night", or the date when the newest night with a sleep is older than yesterday.
    @ViewBuilder private func nightLabel(_ night: Repository.IrregularRhythmNight) -> some View {
        let wake = Date(timeIntervalSince1970: TimeInterval(night.end))
        if Calendar.current.isDateInToday(wake) || Calendar.current.isDateInYesterday(wake) {
            Text("Last night")
        } else {
            let date = wake.formatted(.dateTime.day().month(.abbreviated))
            Text("Latest night: \(date)")
        }
    }

    @ViewBuilder private func verdictTitle(_ verdict: IrregularRhythm.Verdict) -> some View {
        switch verdict {
        case .notEnoughData: Text("Not enough data")
        case .regular: Text("Regular rhythm")
        case .someIrregularSegments: Text("A few irregular stretches")
        case .irregularEpisode: Text("Irregular rhythm")
        }
    }

    @ViewBuilder private func verdictDetail(_ r: IrregularRhythm.NightResult) -> some View {
        switch r.verdict {
        case .notEnoughData:
            Text("The strap recorded under an hour of clean beats, too little to say anything. Either it was not worn for most of the night, or too many beats were noisy. Wear it snug, a finger's width above the wrist bone, all night, and sync it in the morning.")
        case .regular:
            Text("The beats were regular, with no irregular stretch, over the part of the night the strap recorded cleanly.")
        case .someIrregularSegments:
            Text("Some stretches of the night had irregular beats, but never for 30 minutes in a row. Extra heartbeats and movement can cause this.")
        case .irregularEpisode:
            let minutes = Int(r.longestEpisodeMinutes.rounded())
            Text("A pattern like atrial fibrillation: the beats were irregular and unpredictable for \(minutes) minutes in a row.")
        }
    }

    private static func symbol(_ verdict: IrregularRhythm.Verdict) -> String {
        switch verdict {
        case .notEnoughData: return "moon.zzz"
        case .regular: return "checkmark.circle"
        case .someIrregularSegments: return "waveform.path.ecg"
        case .irregularEpisode: return "waveform.path.ecg"
        }
    }

    private static func tint(_ verdict: IrregularRhythm.Verdict) -> Color {
        switch verdict {
        case .notEnoughData: return StrandPalette.textTertiary
        case .regular: return StrandPalette.statusPositive
        case .someIrregularSegments: return StrandPalette.textSecondary
        case .irregularEpisode: return StrandPalette.statusWarning
        }
    }

    // MARK: Figures

    @ViewBuilder private func figures(_ r: IrregularRhythm.NightResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            fact("Clean beats analysed", Self.durationText(minutes: r.analysedMinutes))
            if r.verdict != .notEnoughData {
                fact("Irregular share of the analysed night", Self.percentText(r.burdenPercent))
                fact("Longest irregular stretch", r.episodeCount > 0
                     ? Self.durationText(minutes: r.longestEpisodeMinutes)
                     : String(localized: "None"))
            }
        }
    }

    private func fact(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
            Spacer(minLength: 8)
            Text(verbatim: value).font(StrandFont.bodyNumber).foregroundStyle(StrandPalette.textPrimary)
        }
        .accessibilityElement(children: .combine)
    }

    /// "42 min", "6 h" or "6 h 20 min": whole minutes, the way the other sleep figures read.
    static func durationText(minutes: Double) -> String {
        let total = max(0, Int(minutes.rounded()))
        if total < 60 { return String(localized: "\(total) min") }
        let h = total / 60
        let m = total % 60
        return m == 0 ? String(localized: "\(h) h") : String(localized: "\(h) h \(m) min")
    }

    /// 0 to 100 as a percent, with a decimal below 10 so a small share does not read as zero.
    static func percentText(_ pct: Double) -> String {
        let digits = pct < 10 ? 1 : 0
        return (pct / 100).formatted(.percent.precision(.fractionLength(digits)))
    }

    // MARK: 14-night strip

    private enum Kind {
        case regular, some, episode, noData
    }

    private struct Slot: Identifiable {
        let id: String
        let date: Date
        let burden: Double
        let kind: Kind
    }

    private func slots(_ nights: [Repository.IrregularRhythmNight]) -> [Slot] {
        nights.map { n in
            let wake = Date(timeIntervalSince1970: TimeInterval(n.end))
            let day = Calendar.current.date(byAdding: .hour, value: 12, to: Calendar.current.startOfDay(for: wake)) ?? wake
            let kind: Kind
            switch n.result.verdict {
            case .notEnoughData: kind = .noData
            case .regular: kind = .regular
            case .someIrregularSegments: kind = .some
            case .irregularEpisode: kind = .episode
            }
            return Slot(id: n.day, date: day, burden: n.result.burdenPercent, kind: kind)
        }
    }

    /// The 14 calendar days ending today, so a night the strap missed is a gap, not a squeezed neighbour.
    private var chartDomain: ClosedRange<Date> {
        let cal = Calendar.current
        let end = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date())) ?? Date()
        let start = cal.date(byAdding: .day, value: -Repository.heartRhythmNights, to: end) ?? end
        return start...end
    }

    /// Noon of each of those days: where a night's mark sits and where its weekday letter goes.
    private var dayTicks: [Date] {
        let cal = Calendar.current
        let start = chartDomain.lowerBound
        return (0..<Repository.heartRhythmNights).compactMap { offset in
            cal.date(byAdding: .hour, value: 12 + 24 * offset, to: start)
        }
    }

    private func strip(_ nights: [Repository.IrregularRhythmNight]) -> some View {
        let all = slots(nights)
        let bars = all.filter { $0.kind == .some || $0.kind == .episode }
        let dots = all.filter { $0.kind == .regular }
        let open = all.filter { $0.kind == .noData }
        let episodes = all.filter { $0.kind == .episode }
        let top = max(10.0, ((all.map(\.burden).max() ?? 0) * 1.3).rounded(.up))
        let summary = String(localized: "Nights analysed: \(all.count - open.count). Nights with an irregular rhythm: \(episodes.count).")
        return VStack(alignment: .leading, spacing: 8) {
            Text("Last 14 nights")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
            Chart {
                ForEach(bars) { s in
                    BarMark(x: .value("Night", s.date),
                            y: .value("Irregular share", s.burden),
                            width: .fixed(14))
                        .foregroundStyle(s.kind == .episode ? StrandPalette.statusWarning : StrandPalette.textTertiary)
                        .annotation(position: .top, spacing: 2) {
                            if s.kind == .episode {
                                Image(systemName: "waveform.path.ecg")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(StrandPalette.statusWarning)
                            }
                        }
                }
                ForEach(dots) { s in
                    PointMark(x: .value("Night", s.date), y: .value("Irregular share", 0.0))
                        .foregroundStyle(StrandPalette.textTertiary)
                        .symbolSize(30)
                }
                ForEach(open) { s in
                    PointMark(x: .value("Night", s.date), y: .value("Irregular share", 0.0))
                        .symbol {
                            Circle()
                                .strokeBorder(StrandPalette.textTertiary, lineWidth: 1.5)
                                .frame(width: 8, height: 8)
                        }
                }
            }
            .chartXScale(domain: chartDomain)
            .chartYScale(domain: 0...top)
            .chartXAxis {
                AxisMarks(values: dayTicks) { _ in
                    AxisValueLabel(format: .dateTime.weekday(.narrow))
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(StrandPalette.hairline)
                    AxisValueLabel {
                        if let v = value.as(Double.self) { Text(verbatim: "\(Int(v.rounded()))%") }
                    }
                }
            }
            .frame(height: 130)
            .accessibilityLabel(Text("Irregular rhythm, last 14 nights"))
            .accessibilityValue(Text(verbatim: summary))
            legend
        }
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(StrandPalette.statusWarning)
                    .accessibilityHidden(true)
                Text("Irregular rhythm for 30 minutes or more")
            }
            Text("A bar is the share of the analysed night with an irregular rhythm. A dot is a regular night; an open circle is a night without enough clean beats.")
        }
        .font(StrandFont.footnote)
        .foregroundStyle(StrandPalette.textTertiary)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Notes

    private var notes: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Not a diagnosis: only an ECG can confirm atrial fibrillation. NOOP is not a medical device.")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textSecondary)
            Text("This looks at the timing of your heartbeats while you sleep. Frequent extra beats and movement can cause false alarms, and brief episodes can be missed. The method was checked on ECG recordings, not on this strap.")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
            Text("Informational only, not medical advice.")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
