#if os(iOS)
import SwiftUI
import Charts
import WhoopStore
import StrandImport
import StrandDesign
import StrandAnalytics

// MARK: - WOD detail (read-only)
//
// Tapping a logged WOD opens this read-only view: the WOD's summary, its movements, notes, a
// progression chart across every attempt at the same title, and — from Apple Health, on-device — the
// glucose + carbs + insulin response around the session (2 h before → 4 h after). "Edit" opens the
// editor sheet; deleting there pops back. The glucose panel lives here (not in the editor) so the
// editor stays a plain input form.
//
// Diabetes context is INFORMATIONAL, never treatment advice — no carb/insulin dosing is suggested.

struct WodDetailView: View {
    @EnvironmentObject private var repo: Repository
    /// Apple Health, read through for the glucose around the WOD; not observed, so a sync doesn't redraw the
    /// screen (HealthBridgeEnvironment.swift).
    @Environment(\.healthBridge) private var health
    @EnvironmentObject private var profile: ProfileStore
    @Environment(\.dismiss) private var dismiss

    let onChanged: () -> Void
    @State private var current: WodLogRow
    @State private var history: [WodLogRow] = []
    @State private var showEdit = false

    // Glucose + carbs + insulin around the WOD (Apple Health, queried live).
    @State private var wodWindow: WodTimeWindow?
    /// Glucose, carbs and boluses read for the chart (up to its longest window, 3 h before to 6 h after).
    @State private var trace = GlucoseTrace(readings: [])
    @State private var chartCarbs: [CarbEntry] = []
    @State private var chartBoluses: [InsulinEntry] = []
    @State private var chartZoom: ClosedRange<Date>?
    @State private var minutesBelowLow = 0.0
    /// Minutes in heart-rate zones 1…5 over the WOD's span, from the strap (nil: no heart rate there).
    @State private var zoneMinutes: [Double]?
    @State private var zonesLoaded = false
    @AppStorage(TimelinePrefs.wodBeforeMinutes) private var chartBefore = TimelinePrefs.defaultWodBefore
    @AppStorage(TimelinePrefs.wodAfterMinutes) private var chartAfter = TimelinePrefs.defaultWodAfter
    @State private var glucoseResp: WodGlucoseResponse?
    @State private var carbsPre = 0.0
    @State private var carbsPost = 0.0
    @State private var bolusPre = 0.0
    @State private var bolusPost = 0.0
    @State private var trendPerHour: Double?
    @State private var glucoseLoading = false
    @State private var glucoseLoaded = false

    // What this WOD's session-RPE load adds to its day's Effort (nil until computed / no heart rate that day).
    @State private var effortAdded: Double?
    @State private var effortLoaded = false

    init(wod: WodLogRow, onChanged: @escaping () -> Void) {
        self.onChanged = onChanged
        _current = State(initialValue: wod)
    }

    var body: some View {
        List {
            headerSection
            if !current.movements.isEmpty { movementsSection }
            if let n = current.notes, !n.isEmpty {
                Section("Notes") { Text(n).font(.subheadline).foregroundStyle(.secondary) }
            }
            loadSection
            zonesSection
            if progressionPoints.count >= 2 { progressionSection }
            glucoseSection
        }
        .navigationTitle(current.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) { Button("Edit") { showEdit = true } }
        }
        .sheet(isPresented: $showEdit) {
            WodEditorView(existing: current) { reloadAfterEdit() }
        }
        .task {
            history = await repo.wodHistory(title: current.title)
            await loadEffortContribution()
            await loadGlucose()
        }
    }

    // MARK: Summary

    private var headerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(current.type).font(.subheadline).foregroundStyle(.secondary)
                    if let f = current.format, !f.isEmpty {
                        Text("· \(f)").font(.subheadline).foregroundStyle(.secondary)
                    }
                    if let rx = current.rx {
                        Text(rx ? "RX" : "Scaled")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background((rx ? Color.green : Color.orange).opacity(0.22), in: Capsule())
                    }
                    Spacer()
                    Text(WodFormat.day(current.ts)).font(.caption).foregroundStyle(.secondary)
                }
                if let r = WodFormat.result(current) {
                    Text(r).font(.largeTitle.monospacedDigit().weight(.semibold))
                }
                if let cap = current.timeCapS {
                    Text("Time cap \(cap / 60) min").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var movementsSection: some View {
        Section("Movements") {
            ForEach(Array(current.movements.enumerated()), id: \.offset) { _, m in
                Text(WodFormat.movement(m)).font(.subheadline)
            }
        }
    }

    // MARK: Training load (session-RPE → Effort)

    private var session: StrainScorer.LoggedSession? {
        StrainScorer.LoggedSession(wod: current, tzOffsetSeconds: TimeZone.current.secondsFromGMT())
    }

    private var loadSection: some View {
        Section {
            if let s = session {
                LabeledContent("Session load (sRPE)",
                               value: "\(Int(s.rpe)) × \(Int(s.durationMin.rounded())) min = \(Int(s.load.rounded()))")
                if !effortLoaded {
                    ProgressView()
                } else if let added = effortAdded {
                    if added >= 0.5 {
                        LabeledContent("Added to the day's Effort", value: "+\(Int(added.rounded()))")
                    } else {
                        Text("Your heart rate already reflects this session, so it adds nothing extra to Effort.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                } else {
                    Text("No heart rate that day, so Effort could not be scored.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Text("Heart rate misses much of the muscular load of lifting and WODs. The session-RPE load (RPE × minutes, Foster 2001) adds to Effort only where the heart rate recorded less than a session this hard carries (Tibana 2018).")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Add an RPE and a time (result or time cap) to count this WOD's muscular load in Effort.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        } header: {
            Text("Training load")
        }
    }

    /// This WOD's contribution to its day's Effort: the day scored with and without it, the same way the
    /// engine scores it (the engine folds in every WOD of the day together).
    private func loadEffortContribution() async {
        effortLoaded = false
        guard let s = session else { effortAdded = nil; effortLoaded = true; return }
        let dayStart = Int(Calendar.current.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(current.ts)))
                            .timeIntervalSince1970)
        let dayEnd = dayStart + 86_400
        let hr = await repo.hrSamples(from: dayStart, to: dayEnd - 1, limit: 200_000)
        let daysBack = max(2, (Int(Date().timeIntervalSince1970) - dayStart) / 86_400 + 2)
        let bouts = await repo.workoutRows(days: daysBack, reconcileHr: false)
            .filter { $0.endTs > dayStart && $0.startTs < dayEnd }
            .map { (start: $0.startTs, end: $0.endTs) }
        let maxHR: Double? = profile.hrMaxOverride > 0 ? Double(profile.hrMaxOverride)
            : (profile.age > 0 ? StrainScorer.tanakaHRmax(age: Double(profile.age)) : nil)
        let rest = repo.days.first { $0.day == current.day }?.restingHr.map(Double.init) ?? StrainScorer.defaultRestingHR
        let without = StrainScorer.strain(hr, maxHR: maxHR, restingHR: rest, sex: profile.sex)
        let withWod = StrainScorer.strain(hr, maxHR: maxHR, restingHR: rest, sex: profile.sex, sessions: [s],
                                          bouts: bouts, dayStart: dayStart, dayEnd: dayEnd)
        if let w = withWod, let wo = without { effortAdded = max(0, w - wo) } else { effortAdded = nil }
        effortLoaded = true
    }

    // MARK: Progression (all attempts at this title)

    private var progressionPoints: [TrendPoint] {
        history.compactMap { w in
            WodFormat.progressionValue(w).map {
                TrendPoint(date: Date(timeIntervalSince1970: TimeInterval(w.ts)), value: $0)
            }
        }
    }

    private var progressionSection: some View {
        Section {
            WodProgressionChart(history: history, currentId: current.id)
        } header: {
            Text("Progression")
        }
    }

    // MARK: Glucose + carbs + insulin (Apple Health)

    @ViewBuilder private var glucoseSection: some View {
        Section {
            if glucoseLoading {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Reading from Apple Health…").foregroundStyle(.secondary).font(.subheadline)
                }
            } else {
                if let r = glucoseResp {
                    HStack {
                        stat("Before", "\(Int(r.startMgdl.rounded()))")
                        Spacer()
                        stat("After", "\(Int(r.endMgdl.rounded()))")
                        Spacer()
                        stat("Lowest", "\(Int(r.minMgdl.rounded()))")
                    }
                }
                if let w = wodWindow {
                    Text(windowCaption(w)).font(.caption).foregroundStyle(.secondary)
                    timelineChart(w)
                        .padding(.vertical, 4)
                }
                glucoseDetails
            }
        } header: {
            Text("Glucose, heart & carbs around the WOD")
        }
    }

    /// Time in each heart-rate zone over the WOD's span (the recorded workout, else the logged time), from
    /// the strap's heart rate, on the same zones as the live workout.
    @ViewBuilder private var zonesSection: some View {
        if let w = wodWindow {
            Section {
                if let z = zoneMinutes, z.reduce(0, +) > 0 {
                    HRZoneSplitView(minutes: z)
                        .padding(.vertical, 4)
                    Text(windowCaption(w)).font(.caption).foregroundStyle(.secondary)
                    let zones = HRZones.zones(maxHR: Double(profile.hrMax)).zones
                    if let first = zones.first, let last = zones.last {
                        Text("Zone 1 starts at \(Int(first.lower.rounded())) bpm and zone 5 at \(Int(last.lower.rounded())) bpm, from your max heart rate of \(profile.hrMax) bpm (Settings).")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                } else if zonesLoaded {
                    Text("No heart rate from the strap during this WOD.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            } header: {
                Text("Time in heart-rate zones")
            }
        }
    }

    /// Glucose, heart rate and carbs / boluses around the WOD, zoomable down to single minutes.
    private func timelineChart(_ w: WodTimeWindow) -> some View {
        let start = Date(timeIntervalSince1970: w.start)
        let end = Date(timeIntervalSince1970: w.end)
        let bounds = start.addingTimeInterval(-Double(chartBefore) * 60)...end.addingTimeInterval(Double(chartAfter) * 60)
        return GlucoseHeartTimeline(glucose: trace, carbs: chartCarbs, boluses: chartBoluses,
                                    bands: [TimelineBand(start: start, end: end, label: "WOD")],
                                    bounds: bounds, axis: .wod(start: start, end: end),
                                    hrMax: profile.hrMax > 0 ? Double(profile.hrMax) : nil,
                                    loadHeart: { await heartTrace($0) }, zoom: $chartZoom)
    }

    /// The strap's heart rate for a window, at the resolution the zoom needs (per second when close in), about
    /// one point per point of the chart's width.
    private func heartTrace(_ window: ClosedRange<Date>) async -> HeartTrace {
        let s = await repo.timelineSeries(metric: .hr, from: Int(window.lowerBound.timeIntervalSince1970),
                                          to: Int(window.upperBound.timeIntervalSince1970), targetPoints: 360)
        return HeartTrace(points: s.points, isRaw: s.isRaw, bucketSeconds: s.bucketSeconds)
    }

    /// The figures under the chart, for the fixed window 2 h before to 4 h after the WOD.
    @ViewBuilder private var glucoseDetails: some View {
        if let r = glucoseResp {
            HStack {
                stat("Carbs −2h", "\(Int(carbsPre.rounded())) g")
                Spacer()
                stat("Carbs +4h", "\(Int(carbsPost.rounded())) g")
            }
            if bolusPre > 0 || bolusPost > 0 {
                HStack {
                    stat("Bolus −2h", trimU(bolusPre))
                    Spacer()
                    stat("Bolus +4h", trimU(bolusPost))
                }
            }
            Text(deltaText(r)).font(.caption).foregroundStyle(.secondary)
            if let t = trendPerHour { Text(trendText(t)).font(.caption).foregroundStyle(.secondary) }
            if r.anyLow {
                if minutesBelowLow > 0 {
                    Label(String(localized: "Below 70 mg/dL for about \(Int(minutesBelowLow.rounded())) min in this window"),
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                } else {
                    Label("Went below 70 mg/dL in this window", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            if let note = tendencyNote() { Text(note).font(.caption).foregroundStyle(.secondary) }
            Text("Informational only, not medical advice. Carb and insulin choices stay with you and your care team / Loop.")
                .font(.caption2).foregroundStyle(.tertiary)
        } else if glucoseLoaded {
            Text("No glucose readings in Apple Health for this window.")
                .foregroundStyle(.secondary).font(.subheadline)
        }
    }

    private func stat(_ label: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.title3.monospacedDigit())
        }
    }

    private func trimU(_ u: Double) -> String {
        (u == u.rounded() ? String(Int(u)) : String(format: "%.1f", u)) + " U"
    }

    private func deltaText(_ r: WodGlucoseResponse) -> String {
        let d = Int(r.deltaMgdl.rounded())
        let arrow = d == 0 ? "→" : (d > 0 ? "↑" : "↓")
        var s = "\(arrow) \(abs(d)) mg/dL"
        if let nadir = r.nadirAfterMgdl { s += " · " + String(localized: "lowest after") + " \(Int(nadir.rounded()))" }
        return s
    }

    private func trendText(_ perHour: Double) -> String {
        let v = Int(perHour.rounded())
        let arrow = v == 0 ? "→" : (v > 0 ? "↑" : "↓")
        return String(localized: "Recent trend") + ": \(arrow) \(abs(v)) mg/dL/h"
    }

    private func tendencyNote() -> String? {
        switch DiabetesMetrics.glycemicTendency(type: current.type, format: current.format) {
        case .lowers: return String(localized: "Aerobic / metcon work tends to lower glucose — often for hours afterwards.")
        case .raises: return String(localized: "Heavy strength / anaerobic work can push glucose up for a while.")
        case .mixed:  return String(localized: "Mixed metcons can both raise (short, intense) and lower (longer) glucose.")
        case .unknown: return nil
        }
    }

    private func loadGlucose(force: Bool = false) async {
        if force { glucoseLoaded = false }
        guard !glucoseLoaded, !glucoseLoading else { return }
        glucoseLoading = true
        let e = current
        // Where the WOD really sat: the workout the strap or Apple Health recorded around the logged time
        // (which may mark its start or its end), else the logged time plus the result time / time cap.
        let logged = TimeInterval(e.ts)
        let window = WodTimeWindow.resolve(loggedTs: logged, durationS: (e.resultSeconds ?? e.timeCapS).map(Double.init),
                                           workouts: await recordedWorkouts(around: logged))
        zoneMinutes = await repo.workoutZoneMinutes(from: Int(window.start), to: Int(window.end), maxHR: profile.hrMax)
        zonesLoaded = true
        let workoutStart = window.start
        let workoutEnd = window.end
        // The figures use a fixed window, 2 h before to 4 h after; the chart can show up to 3 h before and
        // 6 h after (its settings), so read that much once.
        let preStart = workoutStart - Self.statsHoursBefore * 3600
        let postEnd = workoutEnd + Self.statsHoursAfter * 3600
        let start = Date(timeIntervalSince1970: workoutStart - Double(TimelinePrefs.maxWodBefore) * 60)
        let end = Date(timeIntervalSince1970: workoutEnd + Double(TimelinePrefs.maxWodAfter) * 60)
        let allReadings = (await health?.glucoseWindow(start: start, end: end)) ?? []
        let carbs = (await health?.carbsWindow(start: start, end: end)) ?? []
        let insulin = (await health?.insulinWindow(start: start, end: end)) ?? []
        let readings = allReadings.filter { $0.ts >= preStart && $0.ts <= postEnd }
        wodWindow = window
        trace = GlucoseTrace(readings: allReadings)
        chartCarbs = carbs
        chartBoluses = insulin.filter(\.bolus)
        chartZoom = nil
        minutesBelowLow = trace.secondsBelow(from: preStart, to: postEnd) / 60
        glucoseResp = DiabetesMetrics.wodGlucoseResponse(readings: readings,
                                                         workoutStart: workoutStart, workoutEnd: workoutEnd)
        carbsPre = DiabetesMetrics.carbsIn(carbs, from: preStart, to: workoutStart)
        carbsPost = DiabetesMetrics.carbsIn(carbs, from: workoutEnd, to: postEnd)
        bolusPre = DiabetesMetrics.insulinIn(insulin, from: preStart, to: workoutStart, bolusOnly: true)
        bolusPost = DiabetesMetrics.insulinIn(insulin, from: workoutEnd, to: postEnd, bolusOnly: true)
        trendPerHour = DiabetesMetrics.glucoseSlopePerHour(readings)
        glucoseLoading = false
        glucoseLoaded = true
    }

    /// The window of the figures above and below the chart (the chart's own window is in its settings).
    private static let statsHoursBefore = 2.0
    private static let statsHoursAfter = 4.0

    /// Workouts the strap or Apple Health recorded within half a day of `ts`, as candidate spans of the WOD.
    private func recordedWorkouts(around ts: TimeInterval) async -> [(start: Double, end: Double)] {
        let daysBack = max(2, Int((Date().timeIntervalSince1970 - ts) / 86_400) + 2)
        return await repo.workoutRows(days: daysBack, reconcileHr: false)
            .filter { abs(Double($0.startTs) - ts) < 12 * 3600 }
            .map { (start: Double($0.startTs), end: Double($0.endTs)) }
    }

    /// Where the WOD's span on the chart comes from: a recorded workout, or the time the WOD was logged.
    private func windowCaption(_ w: WodTimeWindow) -> String {
        let from = Self.clock.string(from: Date(timeIntervalSince1970: w.start))
        let to = Self.clock.string(from: Date(timeIntervalSince1970: w.end))
        return w.recorded
            ? String(localized: "WOD \(from)–\(to) · from the recorded workout")
            : String(localized: "WOD \(from)–\(to) · from the time you logged (no recorded workout found)")
    }

    /// After the edit sheet closes: refresh the list, re-read this WOD (or pop if it was deleted).
    private func reloadAfterEdit() {
        onChanged()
        Task {
            let all = await repo.allWods()
            if let updated = all.first(where: { $0.id == current.id }) {
                current = updated
                history = await repo.wodHistory(title: current.title)
                await loadEffortContribution()
                await loadGlucose(force: true)
            } else {
                dismiss()   // deleted in the editor
            }
        }
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()
}

// MARK: - Progression chart (shared)

/// Every attempt at one WOD title over time, on the title's own result scale, with better always up: a "for
/// time" WOD is plotted as a negative time so a faster result sits higher. RX attempts are filled dots and
/// scaled ones rings (the two are not the same workout); the best attempt and the one being viewed are
/// labelled. Shows a prompt with fewer than two attempts.
struct WodProgressionChart: View {
    let history: [WodLogRow]
    /// The attempt being viewed, drawn larger and labelled (nil on the Bests screen).
    let currentId: String?

    init(history: [WodLogRow], currentId: String? = nil) {
        self.history = history
        self.currentId = currentId
    }

    private struct Attempt: Identifiable {
        let id: String
        let date: Date
        /// The value plotted: seconds negated for a time (so up is faster), else the result itself.
        let plotted: Double
        let rx: Bool?
        let label: String
    }

    private var kind: WodResultKind { history.first?.resultKind ?? .none }
    private var surface: Color { Color(uiColor: .secondarySystemGroupedBackground) }

    private var attempts: [Attempt] {
        let k = kind
        return history.compactMap { w -> Attempt? in
            guard w.resultKind == k, let v = WodFormat.progressionValue(w) else { return nil }
            return Attempt(id: w.id, date: Date(timeIntervalSince1970: TimeInterval(w.ts)),
                           plotted: k == .time ? -v : v, rx: w.rx, label: WodFormat.progressionLabel(v, kind: k))
        }
        .sorted { $0.date < $1.date }
    }

    var body: some View {
        let points = attempts
        if points.count >= 2 {
            chart(points)
        } else {
            Text("Log at least two sessions to see progression.")
                .font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private func chart(_ points: [Attempt]) -> some View {
        let best = points.max { $0.plotted < $1.plotted }          // up is better for every kind
        let yTicks = ticks(points.map(\.plotted))
        let mixed = points.contains { $0.rx == false } && points.contains { $0.rx != false }
        return VStack(alignment: .leading, spacing: 6) {
            Chart {
                ForEach(points) { a in
                    LineMark(x: .value("Date", a.date), y: .value("Result", a.plotted))
                        .foregroundStyle(StrandPalette.effortColor.opacity(0.45))
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
                ForEach(points) { a in
                    PointMark(x: .value("Date", a.date), y: .value("Result", a.plotted))
                        .symbol { marker(a) }
                        .annotation(position: .top, alignment: .center, spacing: 4,
                                    overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                            if let text = pointLabel(a, bestId: best?.id) {
                                Text(verbatim: text)
                                    .font(StrandFont.captionNumber.weight(.semibold))
                                    .foregroundStyle(StrandPalette.textPrimary)
                            }
                        }
                }
            }
            .chartYScale(domain: (yTicks.first ?? 0)...(yTicks.last ?? 1))
            .chartYAxis {
                AxisMarks(position: .leading, values: yTicks) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(StrandPalette.hairline)
                    AxisValueLabel {
                        if let v = value.as(Double.self) { Text(verbatim: axisLabel(v)) }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(StrandPalette.hairline)
                    AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                }
            }
            .frame(height: 170)
            .accessibilityLabel(Text("Progression"))

            HStack(spacing: 10) {
                Text("\(points.count) attempts")
                Spacer(minLength: 6)
                if mixed {
                    HStack(spacing: 4) {
                        Circle().fill(StrandPalette.effortColor).frame(width: 8, height: 8)
                        Text(verbatim: "RX")
                    }
                    HStack(spacing: 4) {
                        Circle().strokeBorder(StrandPalette.effortColor, lineWidth: 2).frame(width: 8, height: 8)
                        Text("Scaled")
                    }
                }
                if kind == .time { Text("Faster is higher") } else { Text("Higher is better") }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    /// The label over an attempt: "Best" and its result on the best one, the result on the one being
    /// viewed, none on the others.
    private func pointLabel(_ a: Attempt, bestId: String?) -> String? {
        if a.id == bestId { return String(localized: "Best") + " " + a.label }
        return a.id == currentId ? a.label : nil
    }

    /// Filled for RX (or unknown), a ring for scaled; the attempt being viewed is drawn larger.
    @ViewBuilder private func marker(_ a: Attempt) -> some View {
        let size: CGFloat = a.id == currentId ? 13 : 9
        if a.rx == false {
            Circle().strokeBorder(StrandPalette.effortColor, lineWidth: 2)
                .background(Circle().fill(surface))
                .frame(width: size, height: size)
        } else {
            Circle().fill(StrandPalette.effortColor)
                .overlay(Circle().stroke(surface, lineWidth: 2))
                .frame(width: size, height: size)
        }
    }

    /// Axis values on the result's own scale: minutes and seconds for a time, whole rounds for
    /// rounds + reps (their plotted value is rounds × 100 + reps), else kilograms or reps.
    private func axisLabel(_ plotted: Double) -> String {
        switch kind {
        case .time: return WodFormat.progressionLabel(-plotted, kind: .time)
        case .roundsReps: return String(localized: "\(Int(plotted) / 100) rounds")
        default: return WodFormat.progressionLabel(plotted, kind: kind)
        }
    }

    /// Three to five evenly spaced, round ticks covering every attempt, in the result's natural steps.
    private func ticks(_ values: [Double]) -> [Double] {
        guard let lo = values.min(), let hi = values.max() else { return [0, 1] }
        let steps: [Double]
        switch kind {
        case .time: steps = [15, 30, 60, 120, 300, 600, 900, 1_800]
        case .roundsReps: steps = [100, 200, 500, 1_000]
        case .weight: steps = [2.5, 5, 10, 20, 25, 50]
        default: steps = [1, 2, 5, 10, 20, 50, 100]
        }
        let span = max(hi - lo, steps[0])
        let step = steps.first { span / $0 <= 4 } ?? steps[steps.count - 1]
        let first = (lo / step).rounded(.down) * step
        var last = (hi / step).rounded(.up) * step
        if last == first { last = first + step }
        return Array(stride(from: first, through: last + step / 2, by: step))
    }
}

// MARK: - Progression screen (from a "Bests" row)

/// Reached by tapping a "Bests" row: the progression chart for that WOD title plus every attempt,
/// each opening its own detail. `onChanged` refreshes the caller's list after an edit/delete.
struct WodProgressionView: View {
    @EnvironmentObject private var repo: Repository
    let title: String
    let onChanged: () -> Void
    @State private var history: [WodLogRow] = []

    var body: some View {
        List {
            Section { WodProgressionChart(history: history) } header: { Text("Progression") }
            if !history.isEmpty {
                Section("Attempts") {
                    ForEach(history) { w in
                        NavigationLink { WodDetailView(wod: w, onChanged: reload) } label: {
                            HStack {
                                Text(WodFormat.day(w.ts)).font(.subheadline)
                                if let rx = w.rx {
                                    Text(rx ? "RX" : "Scaled")
                                        .font(.caption2.weight(.semibold))
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background((rx ? Color.green : Color.orange).opacity(0.22), in: Capsule())
                                }
                                Spacer()
                                if let r = WodFormat.result(w) {
                                    Text(r).font(.body.monospacedDigit()).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await reloadAsync() }
    }

    private func reload() { onChanged(); Task { await reloadAsync() } }
    private func reloadAsync() async { history = await repo.wodHistory(title: title) }
}

#endif
