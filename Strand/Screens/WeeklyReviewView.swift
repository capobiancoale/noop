import SwiftUI
import WhoopStore
import StrandDesign
import StrandAnalytics

// MARK: - Weekly review
//
// "What changed this week": the 7 days as dots, what went better and what went worse against last week, one
// thing for next week, and what the plan has learned about this athlete from their own history. All numbers
// come from the pure engines `WeeklyReview` and `PlanLearning` (keys and numbers only); this view builds the
// localized words. Associations in one person's data, not causes, and not medical advice. Computed once per
// load and per week change into @State, never in `body`.

struct WeeklyReviewView: View {
    @EnvironmentObject private var repo: Repository

    @State private var context: WeeklyReviewBuilder.Context?
    @State private var weekStart = ""
    @State private var outcome: WeeklyReview.Outcome?
    @State private var improvedRows: [Row] = []
    @State private var worsenedRows: [Row] = []
    @State private var showCoach = false

    var body: some View {
        ScreenScaffold(title: nil, onRefresh: { await load() }) {
            header
            if let outcome {
                stripCard(outcome)
                switch outcome {
                case .insufficient(_, let n): insufficientCard(n)
                case .ready(let r): readyCards(r)
                }
            }
            learningCard
            weekNavigation
            coachButton
        }
        .sheet(isPresented: $showCoach) { DayPlanCoachSheet() }
        .task { await load() }
    }

    // MARK: Loading

    private func load() async {
        let ctx = await WeeklyReviewBuilder.context(repo: repo)
        context = ctx
        if weekStart.isEmpty { weekStart = WeeklyReview.mondayKey(of: ctx.todayKey) ?? "" }
        recompute()
    }

    private func recompute() {
        guard let context, !weekStart.isEmpty else { return }
        let o = WeeklyReviewBuilder.review(context: context, weekStart: weekStart)
        outcome = o
        if case .ready(let r) = o {
            improvedRows = Self.rows(r.improved)
            worsenedRows = Self.rows(r.worsened)
        } else {
            improvedRows = []
            worsenedRows = []
        }
    }

    private func shiftWeek(_ delta: Int) {
        guard let next = FitnessAgeEngine.shiftDay(weekStart, by: 7 * delta) else { return }
        weekStart = next
        recompute()
    }

    private var canGoBack: Bool {
        guard let first = context?.firstWeekStart else { return false }
        return weekStart > first
    }

    private var canGoForward: Bool {
        guard let context, let current = WeeklyReview.mondayKey(of: context.todayKey) else { return false }
        return weekStart < current
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: Self.rangeText(start: weekStart, end: FitnessAgeEngine.shiftDay(weekStart, by: 6) ?? weekStart))
                .strandOverline()
            Text(verbatim: titleText)
                .font(StrandFont.rounded(28))
                .foregroundStyle(StrandPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var titleText: String {
        switch outcome {
        case .ready(let r): return Self.headlineText(r.headline)
        case .insufficient: return String(localized: "Not enough data for this week")
        case nil: return String(localized: "Your week")
        }
    }

    // MARK: Day strip

    private func stripCard(_ o: WeeklyReview.Outcome) -> some View {
        let cells: [WeeklyReview.DayCell]
        var adherence: WeeklyReview.Adherence?
        switch o {
        case .insufficient(let c, _): cells = c
        case .ready(let r): cells = r.days; adherence = r.adherence
        }
        return NoopCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 6) {
                    ForEach(cells, id: \.day) { dayDot($0) }
                }
                if let adherence {
                    Text(verbatim: String(localized: "Effort matched the plan on \(adherence.matched) of \(adherence.judged) days"))
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func dayDot(_ cell: WeeklyReview.DayCell) -> some View {
        let tint = Self.tint(cell.level)
        let date = Self.date(cell.day)
        return VStack(spacing: 6) {
            ZStack {
                Circle().fill(tint.opacity(cell.charge == nil ? 0.10 : 0.22))
                Circle().strokeBorder(tint, lineWidth: 1.5)
                Text(verbatim: cell.charge.map { String($0) } ?? "–")
                    .font(StrandFont.bodyNumber)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
            }
            .frame(maxWidth: 44)
            .aspectRatio(1, contentMode: .fit)
            Text(verbatim: date?.formatted(.dateTime.weekday(.narrow)) ?? "")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: Self.dotLabel(cell, date: date)))
    }

    private func insufficientCard(_ n: Int) -> some View {
        NoopCard {
            Text(verbatim: String(localized: "A review needs at least 4 days with data. This week has \(n)."))
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Ready

    @ViewBuilder private func readyCards(_ r: WeeklyReview.Review) -> some View {
        if improvedRows.isEmpty && worsenedRows.isEmpty {
            NoopCard {
                Text("Nothing moved enough against last week to report.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        if !improvedRows.isEmpty { changeCard(title: "Went better", rows: improvedRows, tint: StrandPalette.statusPositive) }
        if !worsenedRows.isEmpty { changeCard(title: "Went worse", rows: worsenedRows, tint: StrandPalette.statusWarning) }
        oneThingCard(r.oneThing)
    }

    private func changeCard(title: LocalizedStringKey, rows: [Row], tint: Color) -> some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 12) {
                Text(title).font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                ForEach(rows) { row in
                    changeRow(row, tint: tint)
                }
            }
        }
    }

    private func changeRow(_ row: Row, tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: row.label).font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                Text(verbatim: row.value).font(StrandFont.bodyNumber).foregroundStyle(StrandPalette.textPrimary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 4) {
                Image(systemName: row.up ? "arrow.up" : "arrow.down")
                    .font(.system(size: 11, weight: .bold))
                    .accessibilityHidden(true)
                Text(verbatim: row.change).font(StrandFont.subhead.weight(.semibold))
            }
            .foregroundStyle(tint)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: row.spoken))
    }

    private func oneThingCard(_ one: WeeklyReview.OneThing) -> some View {
        NoopCard(tint: StrandPalette.accent) {
            VStack(alignment: .leading, spacing: 6) {
                Text("One thing for next week")
                    .font(StrandFont.overline)
                    .tracking(1.2)
                    .textCase(.uppercase)
                    .foregroundStyle(StrandPalette.accent)
                Text(verbatim: Self.oneThingText(one))
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: Learned

    private var learningCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("What the plan has learned about you")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                if let findings = context?.findings, !findings.isEmpty {
                    ForEach(findings, id: \.kind) { f in
                        Text(verbatim: Self.findingText(f))
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("Patterns in your own data, not causes.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                } else if context != nil {
                    Text("Not enough history yet: this fills in after a few weeks.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: Navigation and Coach

    private var weekNavigation: some View {
        HStack {
            Button { shiftWeek(-1) } label: {
                Image(systemName: "chevron.left").font(.system(size: 16, weight: .semibold)).frame(width: 44, height: 44)
            }
            .disabled(!canGoBack)
            .accessibilityLabel(Text("Previous week"))
            Spacer()
            Button { shiftWeek(1) } label: {
                Image(systemName: "chevron.right").font(.system(size: 16, weight: .semibold)).frame(width: 44, height: 44)
            }
            .disabled(!canGoForward)
            .accessibilityLabel(Text("Next week"))
        }
        .buttonStyle(.plain)
        .foregroundStyle(StrandPalette.accent)
    }

    private var coachButton: some View {
        NoopButton("Talk it through with the Coach", systemImage: "bubble.left.and.text.bubble.right",
                   kind: .secondary, fullWidth: true) { showCoach = true }
    }

    // MARK: - Words and numbers

    struct Row: Identifiable, Equatable {
        let id: String
        let label: String
        let value: String
        let change: String
        let up: Bool
        let spoken: String
    }

    static func headlineText(_ h: WeeklyReview.Headline) -> String {
        switch h {
        case .bothBetter: return String(localized: "You slept more and lifted stronger")
        case .strongerLessSleep: return String(localized: "Stronger, but on less sleep")
        case .betterRecovery: return String(localized: "You recovered better this week")
        case .heavyWeek: return String(localized: "A heavy week")
        case .quietWeek: return String(localized: "A quiet week")
        case .steady: return String(localized: "A steady week")
        }
    }

    static func oneThingText(_ one: WeeklyReview.OneThing) -> String {
        switch one {
        case .earlierBedtime(let n, let bed):
            if let bed { return String(localized: "In bed by \(clock(bed)) on \(n) evenings") }
            return String(localized: "Get to bed earlier on \(n) evenings")
        case .steadyWake(let sd):
            return String(localized: "Keep your wake-up time steady: it moved by about \(sd) min this week")
        case .oneEasierDay:
            return String(localized: "Make one day easier: this week's load was well above your usual")
        case .oneMoreSession:
            return String(localized: "Add one more session: this week's load was below your usual")
        case .keepGoing:
            return String(localized: "Keep going: nothing needs changing")
        }
    }

    static func findingText(_ f: PlanLearning.Finding) -> String {
        let points = DisplayNumber.decimal(abs(f.difference), digits: 0)
        let lower = f.difference < 0
        let n = f.groupA.n + f.groupB.n
        switch f.kind {
        case .shortSleep:
            return lower
                ? String(localized: "After a night under 7 h your Charge is \(points) points lower on average. From \(n) nights.")
                : String(localized: "After a night under 7 h your Charge is \(points) points higher on average. From \(n) nights.")
        case .hardDayAfterLowCharge:
            return lower
                ? String(localized: "After a hard day on a low Charge, your next-day Charge is \(points) points lower than after an easier one. From \(n) days.")
                : String(localized: "After a hard day on a low Charge, your next-day Charge is \(points) points higher than after an easier one. From \(n) days.")
        case .consecutiveHardDays:
            return lower
                ? String(localized: "The day after 2 or more hard days in a row, your Charge is \(points) points lower than after a single hard day. From \(n) days.")
                : String(localized: "The day after 2 or more hard days in a row, your Charge is \(points) points higher than after a single hard day. From \(n) days.")
        }
    }

    static func rows(_ items: [WeeklyReview.Item]) -> [Row] {
        items.enumerated().map { idx, item in
            switch item {
            case .metric(let c): return metricRow(c, id: "m\(c.metric.rawValue)")
            case .strengthRecord(let name, let kg):
                let value = kgText(kg)
                let change = String(localized: "Record")
                return Row(id: "s\(idx)", label: name, value: value, change: change, up: true,
                           spoken: String(localized: "\(name): \(value), new record"))
            case .wodBest(let b):
                let value = resultText(b.row) ?? ""
                let change = String(localized: "Best yet")
                return Row(id: "w\(idx)", label: b.title, value: value, change: change, up: true,
                           spoken: String(localized: "\(b.title): \(value), best yet"))
            }
        }
    }

    static func metricRow(_ c: WeeklyReview.Change, id: String) -> Row {
        let label: String, value: String, change: String
        switch c.metric {
        case .sleep:
            label = String(localized: "Average sleep")
            value = duration(c.thisWeek)
            change = duration(abs(c.change))
        case .charge:
            label = String(localized: "Average Charge")
            value = DisplayNumber.decimal(c.thisWeek, digits: 0)
            change = String(localized: "\(DisplayNumber.decimal(abs(c.change), digits: 0)) points")
        case .hrv:
            label = String(localized: "Average HRV")
            value = String(localized: "\(DisplayNumber.decimal(c.thisWeek, digits: 0)) ms")
            change = HeartRhythmCard.percentText(abs(c.changePct ?? 0))
        case .restingHr:
            label = String(localized: "Resting heart rate")
            value = String(localized: "\(DisplayNumber.decimal(c.thisWeek, digits: 0)) bpm")
            change = String(localized: "\(DisplayNumber.decimal(abs(c.change), digits: 0)) bpm")
        case .wakeSpread:
            label = String(localized: "Wake-time spread")
            value = String(localized: "±\(duration(c.thisWeek))")
            change = duration(abs(c.change))
        case .timeInRange:
            label = String(localized: "Time in range")
            value = HeartRhythmCard.percentText(c.thisWeek)
            change = String(localized: "\(DisplayNumber.decimal(abs(c.change), digits: 0)) points")
        }
        let up = c.change > 0
        let spoken = up ? String(localized: "\(label): \(value), up \(change)")
                        : String(localized: "\(label): \(value), down \(change)")
        return Row(id: id, label: label, value: value, change: change, up: up, spoken: spoken)
    }

    static func tint(_ level: DayPlan.Training?) -> Color {
        switch level {
        case .push?: return StrandPalette.statusPositive
        case .maintain?: return StrandPalette.statusWarning
        case .easy?: return StrandPalette.textSecondary
        case nil: return StrandPalette.hairline
        }
    }

    static func dotLabel(_ cell: WeeklyReview.DayCell, date: Date?) -> String {
        let name = date?.formatted(.dateTime.weekday(.wide)) ?? cell.day
        guard let charge = cell.charge else { return String(localized: "\(name): no Charge") }
        return String(localized: "\(name): Charge \(charge)")
    }

    static func rangeText(start: String, end: String) -> String {
        guard let a = date(start), let b = date(end), a <= b else { return start }
        return (a...b).formatted(.interval.month(.abbreviated).day())
    }

    /// A "yyyy-MM-dd" key as a local date (noon, so a time-zone change cannot move the day).
    static func date(_ key: String) -> Date? {
        let p = key.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: p[0], month: p[1], day: p[2], hour: 12))
    }

    /// "in bed by" clock for minutes after midnight, in the user's 12/24 h style.
    static func clock(_ minutes: Int) -> String {
        let date = Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date()
        return date.formatted(date: .omitted, time: .shortened)
    }

    static func duration(_ minutes: Double) -> String { HeartRhythmCard.durationText(minutes: minutes) }

    static func kgText(_ v: Double) -> String {
        String(localized: "\(DisplayNumber.decimal(v, digits: v == v.rounded() ? 0 : 1)) kg")
    }

    static func resultText(_ w: WodLogRow) -> String? {
        switch w.effectiveResultKind {
        case .time: return w.resultSeconds.map { Duration.seconds($0).formatted(.time(pattern: .minuteSecond)) }
        case .roundsReps: return "\(w.resultRounds ?? 0) + \(w.resultReps ?? 0)"
        case .reps: return w.resultReps.map { String(localized: "\($0) reps") }
        case .weight: return w.resultWeightKg.map(kgText)
        case .none: return nil
        }
    }
}
