import SwiftUI
import Charts
import StrandDesign
import StrandAnalytics

// MARK: - VO₂max
//
// Aerobic fitness side by side: estimated from the wearer's walks and runs (the more accurate family on wearables,
// INTERLIVE 2022), estimated at rest (HUNT model), estimated from the WODs' maximal heart rate over a resting heart
// rate measured lying down (heart-rate ratio, Uth 2004), and the values the user measured or read elsewhere,
// entered by hand. The estimates are never blended with each other or with the entries: the point is to see how
// they compare. Maths: StrandAnalytics.VO2maxEngine; data: Repository+VO2max.

struct VO2maxView: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var profile: ProfileStore

    @State private var inputs: Repository.VO2maxInputs?
    @State private var entries: [Repository.VO2maxEntry] = []
    @State private var restingWeekly: [(day: String, value: Double)] = []
    @State private var appleHealth: [(day: String, value: Double)] = []
    @State private var supine: [Repository.SupineRestingHR] = []
    @State private var loaded = false
    @State private var showAddEntry = false
    @State private var showRestingCapture = false
    @State private var showAllSessions = false
    @State private var pendingDelete: Repository.VO2maxEntry?
    @State private var pendingSupineDelete: Repository.SupineRestingHR?
    @State private var editingWaist = false
    @State private var waistText = ""
    @FocusState private var focused: Field?
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue

    private enum Field: Hashable { case waist }

    private var now: Int { Int(Date().timeIntervalSince1970) }
    private var estimates: [VO2maxEngine.SessionEstimate] { inputs?.estimates ?? [] }
    private var exercise: VO2maxEngine.Estimate? { VO2maxEngine.summarize(estimates, asOf: now) }

    var body: some View {
        ScreenScaffold(title: "VO₂max",
                       subtitle: "Your aerobic fitness estimated from your own data, next to the values you measure",
                       onRefresh: { await load() }) {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
                if !loaded {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    summaryTiles
                    if hasChartData { chartCard }
                    exerciseCard
                    wodCard
                    restingCard
                    entriesCard
                }
                methodNote
            }
        }
        .task(id: repo.refreshSeq) { await load() }
        .keyboardDoneToolbar($focused)
        .sheet(isPresented: $showAddEntry) {
            VO2maxEntrySheet { day, value, method in
                Task { await repo.saveVO2maxEntry(day: day, value: value, method: method) }
            }
        }
        .sheet(isPresented: $showRestingCapture) { RestingHRCaptureSheet() }
        .confirmationDialog("Delete this value?", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible, presenting: pendingDelete) { entry in
            Button("Delete", role: .destructive) {
                Task { await repo.deleteVO2maxEntry(day: entry.day) }
            }
        }
    }

    private func load() async {
        let fresh = await repo.vo2maxInputs(age: profile.age, userSetMaxHR: profile.hrMaxOverride)
        let freshEntries = await repo.vo2maxEntries()
        let weekly = await repo.exploreSeries(key: "vo2max_est", source: "my-whoop")
        let apple = await repo.series(key: "vo2max", source: "apple-health")
        let freshSupine = await repo.supineRestingHRs()
        inputs = fresh
        entries = freshEntries
        restingWeekly = weekly
        appleHealth = apple
        supine = freshSupine
        loaded = true
    }

    // MARK: - Resting estimate (live, same inputs as the weekly Fitness Age pass)

    private var restingInputs: (restingHR: Double, paIndex: Double, nights: Int)? {
        let last7 = repo.days.suffix(7)
        let rhrs = last7.compactMap { $0.restingHr }.map(Double.init)
        guard rhrs.count >= FitnessAgeEngine.minCoverageDays, let rhr = VO2maxEngine.restingHeartRate(rhrs) else {
            return nil
        }
        let active = last7.compactMap { $0.strain }.filter { $0 >= 30 }
        let meanActive = active.isEmpty ? 0 : active.reduce(0, +) / Double(active.count)
        let pa = FitnessAgeEngine.physicalActivityIndexFromStrain(activeDaysPerWeek: active.count,
                                                                  meanActiveStrain: meanActive)
        return (rhr, pa, rhrs.count)
    }

    private var resting: VO2maxEngine.RestingEstimate? {
        guard let i = restingInputs else { return nil }
        return VO2maxEngine.restingEstimate(age: Double(profile.age), sex: profile.sex, waistCm: profile.waistCm,
                                            restingHR: i.restingHR, paIndex: i.paIndex)
    }

    // MARK: - From WODs (heart-rate ratio, live)

    private struct WodEstimate {
        let vo2max: Double
        let maxHR: VO2maxEngine.MaxHR
        let restingHR: Double
        /// Day of the supine measurement used, nil when it falls back on the nightly resting heart rate.
        let supineDay: String?
    }

    /// The newest resting heart rate measured lying down, while it still describes the wearer (60 days).
    private var currentSupine: Repository.SupineRestingHR? {
        let today = Repository.dayString(Date())
        return supine.first { daysBetween($0.day, today).map { $0 <= VO2maxEngine.supineValidDays } == true }
    }

    /// HRmax as for the walk/run estimate (your setting, else the hardest workouts, else age) over the supine
    /// resting heart rate; without one, over the nightly resting heart rate, which reads high.
    private var wod: WodEstimate? {
        guard let m = inputs?.maxHR else { return nil }
        if let s = currentSupine,
           let v = VO2maxEngine.hrRatioVO2max(maxHR: m.bpm, restingHR: s.bpm, sex: profile.sex) {
            return WodEstimate(vo2max: v, maxHR: m, restingHR: s.bpm, supineDay: s.day)
        }
        if let i = restingInputs,
           let v = VO2maxEngine.hrRatioVO2max(maxHR: m.bpm, restingHR: i.restingHR, sex: profile.sex) {
            return WodEstimate(vo2max: v, maxHR: m, restingHR: i.restingHR, supineDay: nil)
        }
        return nil
    }

    /// The value from WODs on the day of each supine measurement (today's HRmax: it barely moves in a year).
    private func wodValue(for s: Repository.SupineRestingHR) -> Double? {
        inputs?.maxHR.flatMap { VO2maxEngine.hrRatioVO2max(maxHR: $0.bpm, restingHR: s.bpm, sex: profile.sex) }
    }

    // MARK: - Summary

    private var summaryTiles: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: NoopMetrics.space3, alignment: .top)],
                  alignment: .leading, spacing: NoopMetrics.space3) {
            tile(title: String(localized: "From runs and walks"),
                 value: exercise.map { whole($0.vo2max) },
                 detail: exercise.map { String(localized: "\($0.sessions.count) sessions") },
                 tint: StrandPalette.effortColor)
            tile(title: String(localized: "From WODs"),
                 value: wod.map { whole($0.vo2max) },
                 detail: wod.map { $0.supineDay == nil ? String(localized: "provisional") : String(localized: "lying down") },
                 tint: StrandPalette.metricRose)
            tile(title: String(localized: "At rest"),
                 value: resting.map { whole($0.vo2max) },
                 detail: resting.map { "± \(one($0.standardError))" },
                 tint: StrandPalette.chargeColor)
            tile(title: String(localized: "Your latest"),
                 value: entries.first.map { one($0.value) },
                 detail: entries.first.map { shortDate($0.day) },
                 tint: StrandPalette.metricPurple)
        }
    }

    private func tile(title: String, value: String?, detail: String?, tint: Color) -> some View {
        NoopCard(padding: NoopMetrics.space4, tint: tint) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).strandOverline()
                    .lineLimit(2).minimumScaleFactor(0.8)
                Text(value ?? "—")
                    .font(StrandFont.number(28))
                    .foregroundStyle(value == nil ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                Text(detail ?? "mL/kg/min")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Chart

    private struct ChartPoint: Identifiable {
        let id: String
        let date: Date
        let value: Double
        let series: String
    }

    private var seriesExercise: String { String(localized: "From runs and walks") }
    private var seriesRest: String { String(localized: "At rest") }
    private var seriesWod: String { String(localized: "From WODs") }
    private var seriesEntries: String { String(localized: "Your entries") }
    private var seriesApple: String { "Apple Health" }

    private var chartStart: Date { Date().addingTimeInterval(-365 * 86_400) }

    private var exerciseTrend: [ChartPoint] {
        VO2maxEngine.trend(estimates).map { p in
            ChartPoint(id: "x\(p.start)", date: Date(timeIntervalSince1970: TimeInterval(p.start)),
                       value: p.estimate.vo2max, series: seriesExercise)
        }
        .filter { $0.date >= chartStart }
    }

    private func dayPoints(_ values: [(day: String, value: Double)], series: String, prefix: String) -> [ChartPoint] {
        values.compactMap { p in
            Self.dayFormatter.date(from: p.day).map { ChartPoint(id: prefix + p.day, date: $0, value: p.value, series: series) }
        }
        .filter { $0.date >= chartStart }
    }

    private var restPoints: [ChartPoint] { dayPoints(restingWeekly, series: seriesRest, prefix: "r") }
    private var entryPoints: [ChartPoint] {
        dayPoints(entries.map { ($0.day, $0.value) }, series: seriesEntries, prefix: "m")
    }
    private var applePoints: [ChartPoint] { dayPoints(appleHealth, series: seriesApple, prefix: "a") }
    private var wodPoints: [ChartPoint] {
        dayPoints(supine.reversed().compactMap { s in wodValue(for: s).map { (day: s.day, value: $0) } },
                  series: seriesWod, prefix: "w")
    }

    private var hasChartData: Bool { !chartSeries.isEmpty }

    /// The series that have points in the window, with their colours (the legend lists only these).
    private var chartSeries: [(name: String, color: Color)] {
        [(seriesExercise, StrandPalette.effortColor, !exerciseTrend.isEmpty),
         (seriesWod, StrandPalette.metricRose, !wodPoints.isEmpty),
         (seriesRest, StrandPalette.chargeColor, !restPoints.isEmpty),
         (seriesEntries, StrandPalette.metricPurple, !entryPoints.isEmpty),
         (seriesApple, StrandPalette.metricCyan, !applePoints.isEmpty)]
            .filter { $0.2 }.map { (name: $0.0, color: $0.1) }
    }

    private var chartCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Last 12 months").font(StrandFont.headline)
                Chart {
                    ForEach(exerciseTrend) { p in
                        LineMark(x: .value("Date", p.date), y: .value("VO₂max", p.value),
                                 series: .value("Series", p.series))
                            .foregroundStyle(by: .value("Series", p.series))
                            .interpolationMethod(.monotone)
                        PointMark(x: .value("Date", p.date), y: .value("VO₂max", p.value))
                            .foregroundStyle(by: .value("Series", p.series))
                            .symbolSize(18)
                    }
                    ForEach(wodPoints) { p in
                        LineMark(x: .value("Date", p.date), y: .value("VO₂max", p.value),
                                 series: .value("Series", p.series))
                            .foregroundStyle(by: .value("Series", p.series))
                        PointMark(x: .value("Date", p.date), y: .value("VO₂max", p.value))
                            .foregroundStyle(by: .value("Series", p.series))
                            .symbol(.triangle)
                            .symbolSize(40)
                    }
                    ForEach(restPoints) { p in
                        LineMark(x: .value("Date", p.date), y: .value("VO₂max", p.value),
                                 series: .value("Series", p.series))
                            .foregroundStyle(by: .value("Series", p.series))
                            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    }
                    ForEach(applePoints) { p in
                        PointMark(x: .value("Date", p.date), y: .value("VO₂max", p.value))
                            .foregroundStyle(by: .value("Series", p.series))
                            .symbol(.diamond)
                            .symbolSize(30)
                    }
                    ForEach(entryPoints) { p in
                        PointMark(x: .value("Date", p.date), y: .value("VO₂max", p.value))
                            .foregroundStyle(by: .value("Series", p.series))
                            .symbol(.square)
                            .symbolSize(60)
                    }
                }
                .chartForegroundStyleScale(domain: chartSeries.map { $0.name }, range: chartSeries.map { $0.color })
                .chartYScale(domain: .automatic(includesZero: false))
                .chartYAxisLabel("mL/kg/min")
                .frame(height: 200)
                .accessibilityLabel(Text("VO₂max over the last 12 months"))
            }
        }
    }

    // MARK: - From runs and walks

    private var exerciseCard: some View {
        NoopCard(tint: StrandPalette.effortColor) {
            VStack(alignment: .leading, spacing: 12) {
                Text("From your runs and walks").font(StrandFont.headline)
                if let e = exercise {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(whole(e.vo2max)).font(StrandFont.number(40)).foregroundStyle(StrandPalette.textPrimary)
                        Text("mL/kg/min").font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                    }
                    Text(e.sessions.count == 1
                         ? String(localized: "From 1 session in the last 90 days.")
                         : String(localized: "Median of \(e.sessions.count) sessions in the last 90 days (\(whole(e.low))–\(whole(e.high))).")
                    )
                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                    if e.sessions.count < 3 {
                        Text("With fewer than 3 sessions the number can move a lot from one run to the next.")
                            .font(StrandFont.caption).foregroundStyle(StrandPalette.statusWarning)
                    }
                } else {
                    Text(inputs?.candidates.isEmpty ?? true
                         ? String(localized: "No walks or runs with a distance yet.")
                         : String(localized: "None of your recent walks or runs qualifies yet."))
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                    Text(String(localized: "Record a walk or run with GPS in NOOP, or import it from Apple Health or a GPX, TCX or FIT file, with the strap on: at least 10 minutes at a steady pace, hard enough to breathe faster than normal (50–85% of your heart-rate reserve)."))
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                }
                if let m = inputs?.maxHR {
                    Divider().overlay(StrandPalette.hairline)
                    inputLine(String(localized: "Max heart rate"), "\(Int(m.bpm.rounded())) bpm · \(maxHRSourceLabel(m.source))")
                }
                sessionList
                rejectionSummary
            }
        }
    }

    private func maxHRSourceLabel(_ s: VO2maxEngine.MaxHRSource) -> String {
        switch s {
        case .userSet: return String(localized: "your setting")
        case .observed: return String(localized: "from your hardest workouts")
        case .agePredicted: return String(localized: "estimated from age")
        }
    }

    @ViewBuilder private var sessionList: some View {
        let used = inputs?.candidates.filter { $0.estimate != nil } ?? []
        if !used.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Sessions that count").strandOverline()
                ForEach(showAllSessions ? used : Array(used.prefix(6))) { c in
                    if let e = c.estimate { sessionRow(c, e) }
                }
                if used.count > 6 {
                    Button(showAllSessions ? String(localized: "Show fewer") : String(localized: "Show all \(used.count)")) {
                        withAnimation(StrandMotion.interactive) { showAllSessions.toggle() }
                    }
                    .buttonStyle(.plain)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.accent)
                }
            }
        }
    }

    private func sessionRow(_ c: Repository.VO2maxCandidate, _ e: VO2maxEngine.SessionEstimate) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(shortDate(c.startTs)) · \(c.gait == .running ? String(localized: "Run") : String(localized: "Walk"))")
                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                Text(verbatim: "\(one(c.speedKmh)) km/h · \(Int(e.session.heartRate.rounded())) bpm · "
                     + "\(Int((e.hrrFraction * 100).rounded()))% " + String(localized: "HRR"))
                    .font(StrandFont.captionNumber).foregroundStyle(StrandPalette.textTertiary)
            }
            Spacer(minLength: 8)
            Text(whole(e.vo2max)).font(StrandFont.bodyNumber).foregroundStyle(StrandPalette.textPrimary)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var rejectionSummary: some View {
        let recent = (inputs?.candidates ?? []).filter { $0.startTs > now - VO2maxEngine.windowDays * 86_400 }
        let reasons = Dictionary(grouping: recent.compactMap { c -> VO2maxEngine.Rejection? in
            if case .failure(let r) = c.outcome { return r }
            return nil
        }, by: { $0 }).mapValues(\.count)
        if !reasons.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Not counted (last 90 days)").strandOverline()
                ForEach(VO2maxEngine.Rejection.allCases, id: \.self) { r in
                    if let n = reasons[r] {
                        Text("\(n) × \(rejectionLabel(r))")
                            .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    }
                }
            }
        }
    }

    private func rejectionLabel(_ r: VO2maxEngine.Rejection) -> String {
        switch r {
        case .missingData: return String(localized: "no heart rate from the strap, or no resting heart rate yet")
        case .tooShort: return String(localized: "shorter than 10 minutes or 1 km")
        case .tooLong: return String(localized: "longer than 90 minutes (heart rate drifts up)")
        case .paceOutOfRange: return String(localized: "pace outside the range the equations cover")
        case .tooEasy: return String(localized: "too easy (under 50% of heart-rate reserve)")
        case .tooHard: return String(localized: "too hard to be steady (over 85% of heart-rate reserve)")
        }
    }

    // MARK: - From WODs

    private var wodCard: some View {
        NoopCard(tint: StrandPalette.metricRose) {
            VStack(alignment: .leading, spacing: 12) {
                Text("From your WODs").font(StrandFont.headline)
                if let w = wod {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(whole(w.vo2max)).font(StrandFont.number(40)).foregroundStyle(StrandPalette.textPrimary)
                        Text("mL/kg/min").font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                    }
                    inputLine(String(localized: "Max heart rate"),
                              "\(Int(w.maxHR.bpm.rounded())) bpm · \(maxHRSourceLabel(w.maxHR.source))")
                    if let day = w.supineDay {
                        inputLine(String(localized: "Resting heart rate"),
                                  String(localized: "\(Int(w.restingHR.rounded())) bpm lying down, \(shortDate(day))"))
                    } else {
                        inputLine(String(localized: "Resting heart rate"),
                                  String(localized: "\(Int(w.restingHR.rounded())) bpm at night, asleep"))
                        Text("Provisional: your resting heart rate asleep is lower than the one measured awake and lying down that this method is built on, so this value reads high. Measure it lying down for the real one.")
                            .font(StrandFont.caption).foregroundStyle(StrandPalette.statusWarning)
                    }
                    if w.maxHR.source == .agePredicted {
                        Text("Your max heart rate is estimated from your age, and this value moves in proportion to it. Train hard with the strap on, or set your max heart rate in Settings if you know it from a test.")
                            .font(StrandFont.caption).foregroundStyle(StrandPalette.statusWarning)
                    }
                } else {
                    Text("Needs a max heart rate and a resting heart rate. Measure your resting heart rate lying down to see this value.")
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                }
                NoopButton("Measure resting heart rate", systemImage: "bed.double",
                           kind: currentSupine == nil ? .primary : .secondary) { showRestingCapture = true }
                if !supine.isEmpty { supineList }
                Text("A WOD has no pace or power to measure, but it takes your heart close to its maximum. The heart-rate ratio method (Uth 2004) needs only that and your resting heart rate: about 15 × max heart rate ÷ resting heart rate. Each beat of resting heart rate moves the value by about 1 mL/kg/min, so it needs the resting heart rate the method was built on: awake, lying down, after 15 minutes of rest. In independent tests it was off by about 7–8 mL/kg/min for one person (Esco 2012): no more precise than the estimate at rest, so read it as a second opinion, not a test.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .confirmationDialog("Delete this measurement?", isPresented: Binding(
            get: { pendingSupineDelete != nil }, set: { if !$0 { pendingSupineDelete = nil } }),
                            titleVisibility: .visible, presenting: pendingSupineDelete) { s in
            Button("Delete", role: .destructive) {
                Task { await repo.deleteSupineRestingHR(day: s.day) }
            }
        }
    }

    private var supineList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Resting heart rate lying down").strandOverline()
            ForEach(supine.prefix(5)) { s in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(shortDate(s.day)).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                    Spacer(minLength: 8)
                    Text(verbatim: "\(Int(s.bpm.rounded())) bpm")
                        .font(StrandFont.captionNumber).foregroundStyle(StrandPalette.textPrimary)
                    if let v = wodValue(for: s) {
                        Text(verbatim: "→ \(whole(v))")
                            .font(StrandFont.captionNumber).foregroundStyle(StrandPalette.textTertiary)
                    }
                    Button { pendingSupineDelete = s } label: {
                        Image(systemName: "trash").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Delete this measurement")
                }
            }
        }
    }

    // MARK: - At rest

    private var restingCard: some View {
        NoopCard(tint: StrandPalette.chargeColor) {
            VStack(alignment: .leading, spacing: 12) {
                Text("At rest").font(StrandFont.headline)
                if let r = resting, let i = restingInputs {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(whole(r.vo2max)).font(StrandFont.number(40)).foregroundStyle(StrandPalette.textPrimary)
                        Text("± \(one(r.standardError)) mL/kg/min")
                            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                    }
                    inputLine(String(localized: "Resting heart rate"),
                              String(localized: "\(Int(i.restingHR.rounded())) bpm (median of \(i.nights) nights)"))
                    waistLine
                    inputLine(String(localized: "Activity index (HUNT, 0–15)"), one(i.paIndex))
                    Text("From your age, sex, waist, resting heart rate and how much you train. Estimates made at rest are the less accurate kind: expect it to be off by more than the one from your runs and walks.")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                } else if profile.waistCm <= 0 {
                    Text("Add your waist circumference to see this estimate: it is one of the model's inputs.")
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                    waistEditor
                } else {
                    Text("Needs at least \(FitnessAgeEngine.minCoverageDays) nights of resting heart rate in the last week.")
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                    waistLine
                }
            }
        }
    }

    // MARK: - Waist (edited here, stored in the profile like the Settings field)

    private var imperial: Bool { UnitSystem(rawValue: unitSystemRaw) == .imperial }
    private var waistUnit: String { imperial ? "in" : "cm" }
    /// The Settings field's range: 60–160 cm.
    private static let waistRangeCm: ClosedRange<Double> = 60...160

    private func waistDisplay(_ cm: Double) -> String {
        imperial ? "\(whole(UnitFormatter.cmToInches(cm))) in" : "\(whole(cm)) cm"
    }

    /// The typed waist in centimetres, nil when empty or outside the range (24–63 in, as in Settings).
    private var typedWaistCm: Double? {
        guard let v = Double(waistText.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces))
        else { return nil }
        if imperial {
            return (24...63).contains(v) ? min(Self.waistRangeCm.upperBound, v * UnitFormatter.centimetersPerInch) : nil
        }
        return Self.waistRangeCm.contains(v) ? v : nil
    }

    @ViewBuilder private var waistLine: some View {
        if editingWaist {
            waistEditor
        } else {
            HStack(alignment: .firstTextBaseline) {
                Text("Waist").font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                Spacer(minLength: 8)
                Text(verbatim: waistDisplay(profile.waistCm))
                    .font(StrandFont.captionNumber).foregroundStyle(StrandPalette.textPrimary)
                Button("Edit") { startEditingWaist() }
                    .buttonStyle(.plain)
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.accent)
                    .accessibilityLabel("Edit waist")
            }
        }
    }

    private var waistEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Waist").strandOverline()
            HStack(spacing: 8) {
                TextField(imperial ? String(localized: "e.g. 32") : String(localized: "e.g. 82"), text: $waistText)
                    .textFieldStyle(.plain)
                    .font(StrandFont.bodyNumber)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .numericKeyboard()
                    .focused($focused, equals: .waist)
                    .onSubmit(saveWaist)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                Text(verbatim: waistUnit).font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                NoopButton("Save", kind: .secondary, action: saveWaist)
                    .disabled(typedWaistCm == nil)
                if editingWaist {
                    NoopButton("Cancel", kind: .tertiary) { editingWaist = false; focused = nil }
                }
            }
            if !waistText.isEmpty && typedWaistCm == nil {
                Text(imperial ? String(localized: "Enter a waist between 24 and 63 in.")
                              : String(localized: "Enter a waist between 60 and 160 cm."))
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.statusWarning)
            } else {
                Text("Standing relaxed, tape level at your navel. Saved to your profile (also in Settings).")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }

    private func startEditingWaist() {
        let cm = profile.waistCm
        waistText = cm > 0 ? whole(imperial ? UnitFormatter.cmToInches(cm) : cm) : ""
        editingWaist = true
        focused = .waist
    }

    private func saveWaist() {
        guard let cm = typedWaistCm else { return }
        profile.waistCm = cm.rounded()
        waistText = ""
        editingWaist = false
        focused = nil
    }

    // MARK: - Your values

    private var entriesCard: some View {
        NoopCard(tint: StrandPalette.metricPurple) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Your values").font(StrandFont.headline)
                    Spacer()
                    NoopButton("Add", systemImage: "plus", kind: .tertiary) { showAddEntry = true }
                        .accessibilityLabel("Add a VO₂max value")
                }
                if entries.isEmpty {
                    Text("Enter a VO₂max from a lab test, a field test or another device to see how the estimates compare with it.")
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                } else {
                    ForEach(entries) { entryRow($0) }
                }
            }
        }
    }

    private func entryRow(_ entry: Repository.VO2maxEntry) -> some View {
        let then = endOfDay(entry.day)
        let exerciseThen = then.flatMap { VO2maxEngine.summarize(estimates, asOf: $0) }
        let restThen = restingWeekly.last { $0.day <= entry.day && daysBetween($0.day, entry.day).map { $0 <= 14 } == true }
        let wodThen = supine.first {
            $0.day <= entry.day && daysBetween($0.day, entry.day).map { $0 <= VO2maxEngine.supineValidDays } == true
        }.flatMap(wodValue(for:))
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(one(entry.value)).font(StrandFont.number(22)).foregroundStyle(StrandPalette.textPrimary)
                    Text("\(shortDate(entry.day)) · \(entry.method.label)")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                }
                Spacer()
                Button { pendingDelete = entry } label: {
                    Image(systemName: "trash").foregroundStyle(StrandPalette.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete this value")
            }
            if let x = exerciseThen {
                comparisonLine(String(localized: "From runs and walks then"), estimate: x.vo2max, measured: entry.value)
            }
            if let w = wodThen {
                comparisonLine(String(localized: "From WODs then"), estimate: w, measured: entry.value)
            }
            if let r = restThen {
                comparisonLine(String(localized: "At rest then"), estimate: r.value, measured: entry.value)
            }
            if exerciseThen == nil && wodThen == nil && restThen == nil {
                Text("No estimate from that time to compare with.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .padding(.vertical, 4)
    }

    private func comparisonLine(_ label: String, estimate: Double, measured: Double) -> some View {
        let diff = estimate - measured
        let pct = measured > 0 ? diff / measured * 100 : 0
        let sign = diff > 0 ? "+" : ""
        return HStack(alignment: .firstTextBaseline) {
            Text(label).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
            Spacer()
            Text(verbatim: "\(whole(estimate)) · \(sign)\(one(diff)) (\(sign)\(whole(pct))%)")
                .font(StrandFont.captionNumber)
                .foregroundStyle(abs(pct) <= 10 ? StrandPalette.statusPositive : StrandPalette.statusWarning)
        }
    }

    // MARK: - Method

    private var methodNote: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("How this is worked out").font(StrandFont.headline)
            Text("From runs and walks: the oxygen cost of each steady session's pace (ACSM equations, level ground) is scaled up to your maximum through your heart-rate reserve, which tracks your oxygen-uptake reserve (Swain 1997, 1998). One steady stage estimated VO₂max within about 4 mL/kg/min in a lab validation (Swain 2004). The number is the median of your latest sessions.")
            Text("At rest: the HUNT fitness model (Nes 2011) from age, sex, waist, resting heart rate and activity.")
            // String(localized:) like every other literal with a bare "%" in the app (no format parsing).
            Text(String(localized: "Across 14 studies, wearable estimates made during exercise had no average bias and 95% of people within about ±10 mL/kg/min; those made at rest read about 2 mL/kg/min high with a wider spread (INTERLIVE, Molina-Garcia 2022). A lab test with gas analysis stays the reference."))
            Text("Hills, heat, fatigue, a strap reading your cadence instead of your pulse, or a wrong max heart rate all push the estimate off. Set your max heart rate in Settings if you know it from a test.")
        }
        .font(StrandFont.caption)
        .foregroundStyle(StrandPalette.textTertiary)
    }

    // MARK: - Formatting

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private func whole(_ v: Double) -> String { v.formatted(.number.precision(.fractionLength(0))) }
    private func one(_ v: Double) -> String { v.formatted(.number.precision(.fractionLength(1))) }

    private func shortDate(_ day: String) -> String {
        Self.dayFormatter.date(from: day).map { $0.formatted(date: .abbreviated, time: .omitted) } ?? day
    }

    private func shortDate(_ ts: Int) -> String {
        Date(timeIntervalSince1970: TimeInterval(ts)).formatted(date: .abbreviated, time: .omitted)
    }

    /// Unix seconds at the end of a "yyyy-MM-dd" local day, so a same-day session counts as "then".
    private func endOfDay(_ day: String) -> Int? {
        Self.dayFormatter.date(from: day).map { Int($0.timeIntervalSince1970) + 86_399 }
    }

    private func daysBetween(_ a: String, _ b: String) -> Int? {
        guard let da = Self.dayFormatter.date(from: a), let db = Self.dayFormatter.date(from: b) else { return nil }
        return Calendar.current.dateComponents([.day], from: da, to: db).day
    }

    private func inputLine(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
            Spacer(minLength: 8)
            Text(value).font(StrandFont.captionNumber).foregroundStyle(StrandPalette.textPrimary)
                .multilineTextAlignment(.trailing)
        }
    }
}

// MARK: - Entry sheet

/// Enter one VO₂max value: the number, the day it was measured and how.
struct VO2maxEntrySheet: View {
    let onSave: (_ day: String, _ value: Double, _ method: Repository.VO2maxMethod) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var valueText = ""
    @State private var date = Date()
    @State private var method: Repository.VO2maxMethod = .lab
    @FocusState private var focused: Field?
    private enum Field: Hashable { case value }

    private var value: Double? {
        Double(valueText.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces))
    }
    private var valid: Bool { value.map { Repository.vo2maxPlausible.contains($0) } ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space5) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Add a VO₂max value").font(StrandFont.title2).foregroundStyle(StrandPalette.textPrimary)
                Text("From a lab test, a field test or another device.")
                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("VO₂max").strandOverline()
                HStack(spacing: 6) {
                    TextField("e.g. 48.5", text: $valueText)
                        .textFieldStyle(.plain)
                        .font(StrandFont.bodyNumber)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .numericKeyboard()
                        .focused($focused, equals: .value)
                    Text("mL/kg/min").font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                if !valueText.isEmpty && !valid {
                    Text("Enter a value between \(Int(Repository.vo2maxPlausible.lowerBound)) and \(Int(Repository.vo2maxPlausible.upperBound)).")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.statusWarning)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Measured on").strandOverline()
                DatePicker("", selection: $date, in: ...Date(), displayedComponents: [.date])
                    .labelsHidden()
                    .accessibilityLabel("Date of the measurement")
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("How").strandOverline()
                Picker("How", selection: $method) {
                    ForEach(Repository.VO2maxMethod.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
            HStack(spacing: NoopMetrics.space3) {
                NoopButton("Cancel", kind: .tertiary) { dismiss() }
                Spacer()
                NoopButton("Save", systemImage: "checkmark", kind: .primary) {
                    guard let value, valid else { return }
                    onSave(Repository.dayString(date), value, method)
                    dismiss()
                }
                .disabled(!valid)
            }
        }
        .padding(NoopMetrics.space6)
        #if os(macOS)
        .frame(width: 420)
        #else
        .frame(maxWidth: .infinity)
        .noopSheetPresentation(largeFirst: false)
        #endif
        .background(StrandPalette.surfaceOverlay)
        .keyboardDoneToolbar($focused)
    }
}
