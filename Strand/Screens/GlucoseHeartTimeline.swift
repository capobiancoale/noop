import SwiftUI
import Charts
import StrandDesign
import StrandImport
import StrandAnalytics

// MARK: - Glucose + heart-rate timeline (WOD screen, Today)
//
// Glucose, heart rate and carbs / boluses in lanes on one clock, zoomable like the Deep Timeline from the
// whole window down to single minutes: pinch (or − / +) to zoom, drag sideways to move along, hold and slide
// to read every lane at the same moment, double-tap to zoom back out. Heart rate is re-read at the zoom's
// resolution, down to the strap's per-second readings. Each measure keeps its own lane and scale (never a
// second y-axis on one chart). What the lanes show is set in the settings sheet and saved on the device.
// Informational only: nothing here suggests carbs or insulin. The model (trace, ticks, grouping) is
// StrandImport.GlucoseTrace / TimelineTicks / TimelineEvents, tested there.

/// Heart rate for a stretch of time, at the resolution the repository read it at.
struct HeartTrace {
    var points: [TrendPoint]
    /// True for raw per-second readings; otherwise each point averages `bucketSeconds`.
    var isRaw: Bool
    var bucketSeconds: Int
    static let empty = HeartTrace(points: [], isRaw: false, bucketSeconds: 0)
}

/// A span shaded across every lane: the WOD, or a recorded workout.
struct TimelineBand: Identifiable {
    let start: Date
    let end: Date
    /// Written at the top of the span ("WOD"); nil for none.
    let label: String?
    var id: Date { start }
}

/// The timeline's settings, saved on this device and shared by every timeline (WOD, Today, full screen).
enum TimelinePrefs {
    static let showGlucose = "timeline.showGlucose"
    static let showHeart = "timeline.showHeart"
    static let showEvents = "timeline.showEvents"
    static let showBands = "timeline.showBands"
    static let showTarget = "timeline.showTarget"
    static let showZones = "timeline.showZones"
    static let showStats = "timeline.showStats"
    static let targetLow = "timeline.targetLow"
    static let targetHigh = "timeline.targetHigh"
    static let size = "timeline.size"
    static let wodBeforeMinutes = "timeline.wodBeforeMinutes"
    static let wodAfterMinutes = "timeline.wodAfterMinutes"

    static let defaultWodBefore = 120
    static let defaultWodAfter = 240
    /// The longest windows the settings offer, so a screen can read enough data once for any choice.
    static let maxWodBefore = 180
    static let maxWodAfter = 360
}

/// How tall the lanes are.
enum TimelineSize: String, CaseIterable, Identifiable {
    case compact, standard, large
    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .compact: return "Compact"
        case .standard: return "Standard"
        case .large: return "Large"
        }
    }

    var glucoseHeight: CGFloat {
        switch self {
        case .compact: return 120
        case .standard: return 170
        case .large: return 240
        }
    }

    var heartHeight: CGFloat {
        switch self {
        case .compact: return 90
        case .standard: return 120
        case .large: return 170
        }
    }

    var eventsHeight: CGFloat {
        switch self {
        case .compact: return 36
        case .standard: return 42
        case .large: return 48
        }
    }
}

#if os(iOS)

struct GlucoseHeartTimeline: View {

    /// What the time axis counts: clock time, or hours and minutes from a WOD.
    enum AxisStyle: Equatable {
        case clock
        case wod(start: Date, end: Date)
    }

    let glucose: GlucoseTrace
    let carbs: [CarbEntry]
    /// Bolus insulin only (basal is left out).
    let boluses: [InsulinEntry]
    let bands: [TimelineBand]
    /// The whole window: zooming and moving stay inside it.
    let bounds: ClosedRange<Date>
    let axis: AxisStyle
    /// For the heart-rate zones; nil hides them.
    let hrMax: Double?
    let loadHeart: (ClosedRange<Date>) async -> HeartTrace
    @Binding var zoom: ClosedRange<Date>?
    /// The card behind the chart, for the ring around its markers.
    let surface: Color
    /// The full-screen copy: taller lanes and no full-screen button of its own.
    let fullScreen: Bool

    init(glucose: GlucoseTrace, carbs: [CarbEntry], boluses: [InsulinEntry], bands: [TimelineBand],
         bounds: ClosedRange<Date>, axis: AxisStyle, hrMax: Double?,
         loadHeart: @escaping (ClosedRange<Date>) async -> HeartTrace,
         zoom: Binding<ClosedRange<Date>?>, surface: Color = Color(uiColor: .secondarySystemGroupedBackground),
         fullScreen: Bool = false) {
        self.glucose = glucose
        self.carbs = carbs
        self.boluses = boluses
        self.bands = bands
        self.bounds = bounds
        self.axis = axis
        self.hrMax = hrMax
        self.loadHeart = loadHeart
        self._zoom = zoom
        self.surface = surface
        self.fullScreen = fullScreen
    }

    @State private var heart: HeartTrace = .empty
    @State private var heartLoaded = false
    @State private var scrubDate: Date?
    @State private var scrubEngaged = false
    @State private var pinching = false
    @State private var gestureBase: ClosedRange<Date>?
    @State private var panDirection: PanDirection = .undecided
    @State private var plotFrame: CGRect = .zero
    @State private var showSettings = false
    @State private var showFullScreen = false

    @AppStorage(TimelinePrefs.showGlucose) private var showGlucose = true
    @AppStorage(TimelinePrefs.showHeart) private var showHeart = true
    @AppStorage(TimelinePrefs.showEvents) private var showEvents = true
    @AppStorage(TimelinePrefs.showBands) private var showBands = true
    @AppStorage(TimelinePrefs.showTarget) private var showTarget = true
    @AppStorage(TimelinePrefs.showZones) private var showZones = false
    @AppStorage(TimelinePrefs.showStats) private var showStats = true
    @AppStorage(TimelinePrefs.targetLow) private var targetLow = 70.0
    @AppStorage(TimelinePrefs.targetHigh) private var targetHigh = 180.0
    @AppStorage(TimelinePrefs.size) private var sizeRaw = TimelineSize.standard.rawValue

    private enum PanDirection { case undecided, horizontal, vertical }

    private static let space = "glucoseHeartTimeline"
    /// Width of every lane's y-axis labels, so the lanes' plots line up.
    private static let axisWidth: CGFloat = 34
    private static let low = GlucoseTrace.lowThreshold

    // MARK: Window

    /// The window on screen: the zoom, when it lies inside the bounds, else the whole window.
    private var visible: ClosedRange<Date> {
        if let z = zoom, z.upperBound > z.lowerBound,
           z.lowerBound >= bounds.lowerBound, z.upperBound <= bounds.upperBound { return z }
        return bounds
    }
    private var isZoomed: Bool { visible != bounds }
    private var lo: Double { visible.lowerBound.timeIntervalSince1970 }
    private var hi: Double { visible.upperBound.timeIntervalSince1970 }
    private var span: Double { max(1, hi - lo) }

    private var size: TimelineSize { TimelineSize(rawValue: sizeRaw) ?? .standard }
    private var glucoseHeight: CGFloat { fullScreen ? 280 : size.glucoseHeight }
    private var heartHeight: CGFloat { fullScreen ? 210 : size.heartHeight }
    private var eventsHeight: CGFloat { fullScreen ? 52 : size.eventsHeight }

    private var isWod: Bool {
        if case .wod = axis { return true }
        return false
    }

    private func date(_ ts: Double) -> Date { Date(timeIntervalSince1970: ts) }

    // MARK: Body

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            toolbar
            if showGlucose || showHeart || (showEvents && hasEvents) {
                lanes
            } else {
                Text("Every lane is off. Turn one on in the chart settings.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            }
            Group {
                if isZoomed {
                    Text("Drag sideways to move · hold to read · double-tap to zoom out")
                } else {
                    Text("Pinch or tap + to zoom · hold and slide to read")
                }
            }
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textTertiary)
        }
        .task(id: heartKey) { await readHeart() }
        .sheet(isPresented: $showSettings) { TimelineSettingsSheet(showsWodWindow: isWod) }
        .fullScreenCover(isPresented: $showFullScreen) { fullScreenView }
    }

    private var toolbar: some View {
        HStack(spacing: 16) {
            Text(verbatim: windowText)
                .font(StrandFont.footnote.monospacedDigit())
                .foregroundStyle(scrubDate == nil ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Spacer(minLength: 4)
            if isWod {
                toolButton("scope", "Zoom to the WOD") { focusWod() }
            }
            toolButton("minus.magnifyingglass", "Zoom out") { zoomBy(0.5) }
                .disabled(!isZoomed)
            toolButton("plus.magnifyingglass", "Zoom in") { zoomBy(2) }
                .disabled(span <= OverviewHRChart.minZoomSpan + 1)
            toolButton("slider.horizontal.3", "Customize chart") { showSettings = true }
            if !fullScreen {
                toolButton("arrow.up.left.and.arrow.down.right", "Full screen") { showFullScreen = true }
            }
        }
    }

    private func toolButton(_ symbol: String, _ label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .frame(minWidth: 24, minHeight: 28)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(StrandPalette.accent)
        .accessibilityLabel(Text(label))
    }

    private var lanes: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showGlucose { glucoseLane }
            if showHeart { heartLane }
            if showEvents && hasEvents { eventLane }
            axisLabels
        }
        .coordinateSpace(.named(Self.space))
        .onPreferenceChange(PlotFrameKey.self) { plotFrame = $0 }
        .contentShape(Rectangle())
        .gesture(scrubGesture)
        .simultaneousGesture(panGesture)
        .simultaneousGesture(magnifyGesture)
        .simultaneousGesture(TapGesture(count: 2).onEnded { resetZoom() })
    }

    private var fullScreenView: some View {
        NavigationStack {
            ScrollView {
                GlucoseHeartTimeline(glucose: glucose, carbs: carbs, boluses: boluses, bands: bands, bounds: bounds,
                                     axis: axis, hrMax: hrMax, loadHeart: loadHeart, zoom: $zoom,
                                     surface: StrandPalette.surfaceBase, fullScreen: true)
                    .padding(16)
            }
            .background(StrandPalette.surfaceBase)
            .navigationTitle(Text("Glucose & heart"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showFullScreen = false }
                }
            }
        }
    }

    // MARK: Glucose lane

    private var glucoseLane: some View {
        let range = glucose.displayRange(targetLow: targetLow, targetHigh: targetHigh)
        let shown = glucose.visible(from: lo, to: hi)
        let area = lowArea(shown)
        let showDots = glucose.inside(from: lo, to: hi).count <= 40
        let marks = scrubDate == nil ? glucose.extremes(from: lo, to: hi) : nil
        return VStack(alignment: .leading, spacing: 4) {
            laneHeader("Glucose", unit: "mg/dL", detail: glucoseDetail)
            Chart {
                if showTarget {
                    RectangleMark(yStart: .value("Target low", targetLow), yEnd: .value("Target high", targetHigh))
                        .foregroundStyle(StrandPalette.statusPositive.opacity(0.09))
                }
                RuleMark(y: .value("Low", Self.low))
                    .foregroundStyle(StrandPalette.statusCritical.opacity(0.45))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                bandMarks(labelled: true)
                tickRules
                ForEach(area) { p in
                    AreaMark(x: .value("Time", date(p.ts)),
                             yStart: .value("Glucose", p.mgdl),
                             yEnd: .value("Low", Self.low),
                             series: .value("Segment", p.segment))
                        .foregroundStyle(StrandPalette.statusCritical.opacity(0.28))
                        .interpolationMethod(.linear)
                }
                ForEach(shown) { p in
                    LineMark(x: .value("Time", date(p.ts)), y: .value("Glucose", p.mgdl),
                             series: .value("Segment", p.segment))
                        .foregroundStyle(StrandPalette.chartGlucose)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.linear)
                }
                if showDots {
                    ForEach(shown) { p in
                        PointMark(x: .value("Time", date(p.ts)), y: .value("Glucose", p.mgdl))
                            .symbolSize(16)
                            .foregroundStyle(StrandPalette.chartGlucose)
                    }
                }
                if let m = marks {
                    PointMark(x: .value("Time", date(m.low.ts)), y: .value("Glucose", m.low.mgdl))
                        .symbol { dot(m.low.mgdl < Self.low ? StrandPalette.statusCritical : StrandPalette.chartGlucose) }
                        .annotation(position: labelSide(m.low.ts), alignment: .center, spacing: 4) {
                            valueLabel(Int(m.low.mgdl.rounded()))
                        }
                    if m.high.mgdl > targetHigh {
                        PointMark(x: .value("Time", date(m.high.ts)), y: .value("Glucose", m.high.mgdl))
                            .symbol { dot(StrandPalette.chartGlucose) }
                            .annotation(position: labelSide(m.high.ts), alignment: .center, spacing: 4) {
                                valueLabel(Int(m.high.mgdl.rounded()))
                            }
                    }
                }
                if let s = scrubDate {
                    RuleMark(x: .value("Selected", s))
                        .foregroundStyle(StrandPalette.textSecondary.opacity(0.7))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                    if let g = scrubGlucose {
                        PointMark(x: .value("Time", date(g.ts)), y: .value("Glucose", g.mgdl))
                            .symbol { dot(StrandPalette.chartGlucose) }
                    }
                }
            }
            .chartXScale(domain: visible)
            .chartYScale(domain: range)
            .chartXAxis(.hidden)
            .chartYAxis { yAxis(glucoseTicks(range)) }
            .chartPlotStyle { plot in plot.clipped() }
            .chartOverlay { proxy in plotFrameReporter(proxy) }
            .frame(height: glucoseHeight)
            .overlay {
                if shown.isEmpty {
                    Text("No glucose readings in this stretch")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
            .accessibilityLabel(Text("Glucose"))
            .accessibilityValue(Text(verbatim: glucoseDetail ?? ""))
        }
    }

    /// The area below 70 mg/dL for the stretch on screen (the trace's own points bound it).
    private func lowArea(_ shown: [GlucoseTrace.Point]) -> [GlucoseTrace.AreaPoint] {
        guard let first = shown.first?.ts, let last = shown.last?.ts,
              shown.contains(where: { $0.mgdl < Self.low }) else { return [] }
        return glucose.lowArea().filter { $0.ts >= first && $0.ts <= last }
    }

    /// The lines worth a label: 70 (the low), the target range's edges, round values up to the top.
    private func glucoseTicks(_ range: ClosedRange<Double>) -> [Double] {
        var ticks: [Double] = [Self.low, targetHigh]
        if abs(targetLow - Self.low) >= 15 { ticks.append(targetLow) }
        for v in [40.0, 250, 300, 350, 400] where abs(v - targetHigh) >= 40 && abs(v - Self.low) >= 25 {
            ticks.append(v)
        }
        return ticks.filter { range.contains($0) }.sorted()
    }

    private var scrubGlucose: GlucoseTrace.Point? {
        guard let s = scrubDate else { return nil }
        return glucose.nearest(to: s.timeIntervalSince1970, within: 600)
    }

    /// The lane header's figures: the reading under the finger, else the stretch on screen.
    private var glucoseDetail: String? {
        if let s = scrubDate {
            guard let g = glucose.nearest(to: s.timeIntervalSince1970, within: 600) else { return "—" }
            return "\(Int(g.mgdl.rounded())) mg/dL · " + clock(g.ts, seconds: false)
        }
        guard showStats, let e = glucose.extremes(from: lo, to: hi) else { return nil }
        let mean = Int((glucose.mean(from: lo, to: hi) ?? e.low.mgdl).rounded())
        var text = String(localized: "\(Int(e.low.mgdl.rounded()))–\(Int(e.high.mgdl.rounded())), avg \(mean)")
        let below = glucose.secondsBelow(Self.low, from: lo, to: hi) / 60
        if below >= 1 { text += " · " + String(localized: "\(Int(below.rounded())) min below 70") }
        return text
    }

    // MARK: Heart-rate lane

    private struct HeartPoint: Identifiable {
        let date: Date
        let bpm: Double
        let segment: Int
        var id: Date { date }
    }

    /// The heart rate on screen (plus a point past each edge), split where the strap sent nothing.
    private var visibleHeart: [HeartPoint] {
        let pad = Double(max(heart.bucketSeconds, 1))
        let gap = max(Double(heart.bucketSeconds) * 3, 60)
        var out: [HeartPoint] = []
        var segment = 0
        var previous: Double?
        for p in heart.points {
            let t = p.date.timeIntervalSince1970
            guard t >= lo - pad, t <= hi + pad else { continue }
            if let prev = previous, t - prev > gap { segment += 1 }
            out.append(HeartPoint(date: p.date, bpm: p.value, segment: segment))
            previous = t
        }
        return out
    }

    private var zoneSet: HRZoneSet? {
        guard showZones, let m = hrMax, m > 0 else { return nil }
        return HRZones.zones(maxHR: m)
    }

    private var heartLane: some View {
        let points = visibleHeart
        let range = heartRange(points)
        let zones = (zoneSet?.zones ?? []).filter { $0.upper > range.lowerBound && $0.lower < range.upperBound }
        let peak = scrubDate == nil ? heartPeak(points) : nil
        return VStack(alignment: .leading, spacing: 4) {
            laneHeader("Heart rate", unit: heartUnit, detail: heartDetail)
            ZStack {
                Chart {
                    ForEach(zones, id: \.number) { z in
                        RectangleMark(yStart: .value("Zone low", max(z.lower, range.lowerBound)),
                                      yEnd: .value("Zone high", min(z.upper, range.upperBound)))
                            .foregroundStyle(StrandPalette.hrZoneColor(z.number).opacity(0.10))
                            .annotation(position: .overlay, alignment: .trailing) {
                                Text(verbatim: "Z\(z.number)")
                                    .font(StrandFont.footnote)
                                    .foregroundStyle(StrandPalette.textTertiary)
                                    .padding(.trailing, 4)
                            }
                    }
                    bandMarks(labelled: !showGlucose)
                    tickRules
                    ForEach(points) { p in
                        AreaMark(x: .value("Time", p.date),
                                 yStart: .value("Floor", range.lowerBound),
                                 yEnd: .value("Heart rate", p.bpm),
                                 series: .value("Segment", p.segment))
                            .foregroundStyle(StrandPalette.metricRose.opacity(0.12))
                            .interpolationMethod(.linear)
                    }
                    ForEach(points) { p in
                        LineMark(x: .value("Time", p.date), y: .value("Heart rate", p.bpm),
                                 series: .value("Segment", p.segment))
                            .foregroundStyle(StrandPalette.metricRose)
                            .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                            .interpolationMethod(.linear)
                    }
                    if let p = peak {
                        PointMark(x: .value("Time", p.date), y: .value("Heart rate", p.bpm))
                            .symbol { dot(StrandPalette.metricRose) }
                            .annotation(position: labelSide(p.date.timeIntervalSince1970), alignment: .center, spacing: 4) {
                                valueLabel(Int(p.bpm.rounded()))
                            }
                    }
                    if let s = scrubDate {
                        RuleMark(x: .value("Selected", s))
                            .foregroundStyle(StrandPalette.textSecondary.opacity(0.7))
                            .lineStyle(StrokeStyle(lineWidth: 1))
                        if let h = scrubHeart {
                            PointMark(x: .value("Time", h.date), y: .value("Heart rate", h.value))
                                .symbol { dot(StrandPalette.metricRose) }
                        }
                    }
                }
                .chartXScale(domain: visible)
                .chartYScale(domain: range)
                .chartXAxis(.hidden)
                .chartYAxis { yAxis(heartTicks(range)) }
                .chartPlotStyle { plot in plot.clipped() }
                .chartOverlay { proxy in plotFrameReporter(proxy) }
                .accessibilityLabel(Text("Heart rate"))
                .accessibilityValue(Text(verbatim: heartDetail ?? ""))
                if points.isEmpty {
                    Group {
                        if heartLoaded {
                            Text("No heart rate from the strap in this stretch")
                        } else {
                            Text("Reading heart rate…")
                        }
                    }
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                }
            }
            .frame(height: heartHeight)
        }
    }

    /// The highest heart rate inside the window on screen.
    private func heartPeak(_ points: [HeartPoint]) -> HeartPoint? {
        points.filter { $0.date >= visible.lowerBound && $0.date <= visible.upperBound }.max { $0.bpm < $1.bpm }
    }

    private func heartRange(_ points: [HeartPoint]) -> ClosedRange<Double> {
        guard let lowest = points.map(\.bpm).min(), let highest = points.map(\.bpm).max() else { return 50...150 }
        let lower = max(0, ((lowest - 5) / 10).rounded(.down) * 10)
        var upper = ((highest + 8) / 10).rounded(.up) * 10
        if upper - lower < 40 { upper = lower + 40 }
        return lower...upper
    }

    /// Three or four round values across the range.
    private func heartTicks(_ range: ClosedRange<Double>) -> [Double] {
        let width = range.upperBound - range.lowerBound
        let step = [10.0, 20, 25, 50].first { width / $0 <= 4 } ?? 50
        let first = (range.lowerBound / step).rounded(.up) * step
        return Array(stride(from: first, through: range.upperBound, by: step))
    }

    private var heartUnit: String {
        guard !heart.points.isEmpty else { return "bpm" }
        if heart.isRaw { return "bpm · " + String(localized: "Raw · per second") }
        let m = heart.bucketSeconds / 60
        return "bpm · " + (m >= 1 ? String(localized: "\(m)-minute average")
                                   : String(localized: "\(heart.bucketSeconds)-second average"))
    }

    /// The heart-rate point closest to the finger, if one lies within a reading's width of it.
    private var scrubHeart: TrendPoint? {
        guard let s = scrubDate, !heart.points.isEmpty else { return nil }
        let pts = heart.points
        var a = 0, b = pts.count
        while a < b {
            let mid = (a + b) / 2
            if pts[mid].date < s { a = mid + 1 } else { b = mid }
        }
        let tolerance = max(Double(heart.bucketSeconds) * 1.5, 5)
        var best: TrendPoint?
        for i in [a - 1, a] where pts.indices.contains(i) {
            let d = abs(pts[i].date.timeIntervalSince(s))
            if d <= tolerance, best.map({ d < abs($0.date.timeIntervalSince(s)) }) ?? true { best = pts[i] }
        }
        return best
    }

    private var heartDetail: String? {
        if scrubDate != nil {
            guard let h = scrubHeart else { return "—" }
            var text = "\(Int(h.value.rounded())) bpm"
            if let z = zoneSet?.zoneNumber(forBPM: h.value), z > 0 { text += " · Z\(z)" }
            return text
        }
        let values = visibleHeart.filter { $0.date >= visible.lowerBound && $0.date <= visible.upperBound }.map(\.bpm)
        guard showStats, let top = values.max(), !values.isEmpty else { return nil }
        let mean = values.reduce(0, +) / Double(values.count)
        return String(localized: "avg \(Int(mean.rounded())) · max \(Int(top.rounded()))")
    }

    private var heartKey: String {
        showHeart ? "\(Int(lo))|\(Int(hi))" : "off"
    }

    /// Re-read the heart rate for the window on screen, once a pinch or drag has settled.
    private func readHeart() async {
        guard showHeart else { return }
        if heartLoaded { try? await Task.sleep(nanoseconds: 180_000_000) }
        guard !Task.isCancelled else { return }
        let pad = span * 0.1
        let window = visible.lowerBound.addingTimeInterval(-pad)...visible.upperBound.addingTimeInterval(pad)
        var trace = await loadHeart(window)
        guard !Task.isCancelled else { return }
        trace.points.sort { $0.date < $1.date }
        heart = trace
        heartLoaded = true
    }

    // MARK: Carbs and bolus lane

    private var hasEvents: Bool { !carbs.isEmpty || !boluses.isEmpty }

    private var eventLane: some View {
        let within = TimelineEvents.mergeDistance(span: span)
        let carbEvents = TimelineEvents.merged(carbs.filter { $0.ts >= lo - within && $0.ts <= hi }
            .map { (ts: $0.ts, amount: $0.grams) }, within: within)
        let bolusEvents = TimelineEvents.merged(boluses.filter { $0.ts >= lo - within && $0.ts <= hi }
            .map { (ts: $0.ts, amount: $0.units) }, within: within)
        return VStack(alignment: .leading, spacing: 4) {
            laneHeader("Carbs & bolus", unit: "g · U", detail: eventsDetail)
            Chart {
                bandMarks(labelled: !showGlucose && !showHeart)
                tickRules
                ForEach(carbEvents) { e in
                    PointMark(x: .value("Time", date(e.ts)), y: .value("Kind", "carbs"))
                        .symbol(.circle)
                        .symbolSize(60)
                        .foregroundStyle(StrandPalette.chartCarbs)
                        .annotation(position: .trailing, alignment: .center, spacing: 3) {
                            eventLabel("\(Int(e.amount.rounded())) g")
                        }
                }
                ForEach(bolusEvents) { e in
                    PointMark(x: .value("Time", date(e.ts)), y: .value("Kind", "bolus"))
                        .symbol(.diamond)
                        .symbolSize(60)
                        .foregroundStyle(StrandPalette.chartBolus)
                        .annotation(position: .trailing, alignment: .center, spacing: 3) {
                            eventLabel(units(e.amount))
                        }
                }
                if let s = scrubDate {
                    RuleMark(x: .value("Selected", s))
                        .foregroundStyle(StrandPalette.textSecondary.opacity(0.7))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                }
            }
            .chartXScale(domain: visible)
            .chartYScale(domain: ["carbs", "bolus"])
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading, values: ["carbs", "bolus"]) { value in
                    AxisValueLabel {
                        Image(systemName: value.as(String.self) == "carbs" ? "fork.knife" : "syringe.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(StrandPalette.textTertiary)
                            .frame(width: Self.axisWidth, alignment: .trailing)
                    }
                }
            }
            .chartPlotStyle { plot in plot.clipped() }
            .chartOverlay { proxy in plotFrameReporter(proxy) }
            .frame(height: eventsHeight)
            .accessibilityLabel(Text("Carbs and bolus insulin"))
            .accessibilityValue(Text(verbatim: eventsDetail ?? ""))
        }
    }

    /// Carbs and bolus in the stretch on screen (or within ten minutes of the finger).
    private var eventsDetail: String? {
        let from: Double, to: Double
        if let s = scrubDate {
            from = s.timeIntervalSince1970 - 600; to = s.timeIntervalSince1970 + 600
        } else {
            guard showStats else { return nil }
            from = lo; to = hi
        }
        let grams = carbs.filter { $0.ts >= from && $0.ts <= to }.reduce(0) { $0 + $1.grams }
        let units = boluses.filter { $0.ts >= from && $0.ts <= to }.reduce(0) { $0 + $1.units }
        guard grams > 0 || units > 0 else { return scrubDate == nil ? nil : "—" }
        var parts: [String] = []
        if grams > 0 { parts.append("\(Int(grams.rounded())) g") }
        if units > 0 { parts.append(self.units(units)) }
        return parts.joined(separator: " · ")
    }

    private func units(_ u: Double) -> String {
        (u == u.rounded() ? String(Int(u)) : String(format: "%.1f", u)) + " U"
    }

    private func eventLabel(_ text: String) -> some View {
        Text(verbatim: text)
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textSecondary)
    }

    // MARK: Shared marks

    /// The WOD or workouts, shaded, clamped to the window so a label stays in view.
    @ChartContentBuilder private func bandMarks(labelled: Bool) -> some ChartContent {
        ForEach(shownBands) { b in
            RectangleMark(xStart: .value("Start", max(b.start, visible.lowerBound)),
                          xEnd: .value("End", min(b.end, visible.upperBound)))
                .foregroundStyle(StrandPalette.textTertiary.opacity(0.16))
                .annotation(position: .overlay, alignment: .top) {
                    if labelled, let label = b.label {
                        Text(verbatim: label)
                            .font(StrandFont.footnote.weight(.semibold))
                            .foregroundStyle(StrandPalette.textSecondary)
                            .padding(.top, 2)
                    }
                }
        }
    }

    private var shownBands: [TimelineBand] {
        guard showBands else { return [] }
        return bands.filter { $0.end > visible.lowerBound && $0.start < visible.upperBound }
    }

    /// The axis ticks as faint vertical lines in every lane.
    private var tickRules: some ChartContent {
        ForEach(ticks) { t in
            RuleMark(x: .value("Tick", date(t.ts)))
                .foregroundStyle(StrandPalette.hairline)
                .lineStyle(StrokeStyle(lineWidth: 0.5))
        }
    }

    private func yAxis(_ values: [Double]) -> some AxisContent {
        AxisMarks(position: .leading, values: values) { value in
            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                .foregroundStyle(StrandPalette.hairline)
            AxisValueLabel {
                if let v = value.as(Double.self) {
                    Text(verbatim: "\(Int(v))")
                        .font(StrandFont.footnote)
                        .frame(width: Self.axisWidth, alignment: .trailing)
                }
            }
        }
    }

    /// A data marker: filled, with a ring in the card's colour so it stays legible on the line.
    private func dot(_ color: Color) -> some View {
        Circle().fill(color)
            .overlay(Circle().stroke(surface, lineWidth: 2))
            .frame(width: 10, height: 10)
    }

    private func valueLabel(_ value: Int) -> some View {
        Text(verbatim: "\(value)")
            .font(StrandFont.captionNumber.weight(.semibold))
            .foregroundStyle(StrandPalette.textPrimary)
    }

    /// A label goes on the side of its point with more room: right in the window's first half, else left.
    private func labelSide(_ ts: Double) -> AnnotationPosition {
        ts < lo + span / 2 ? .trailing : .leading
    }

    private func laneHeader(_ title: LocalizedStringKey, unit: String, detail: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title)
                .font(StrandFont.footnote.weight(.semibold))
                .foregroundStyle(StrandPalette.textSecondary)
            Text(verbatim: unit)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .lineLimit(1)
            Spacer(minLength: 6)
            if let detail {
                Text(verbatim: detail)
                    .font(StrandFont.captionNumber)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
    }

    // MARK: Time axis

    private var tickStep: Double { TimelineTicks.step(span: span, maxTicks: fullScreen ? 6 : 5) }

    private var ticks: [TimelineTick] {
        switch axis {
        case .clock:
            let offset = Double(TimeZone.current.secondsFromGMT(for: visible.lowerBound))
            return TimelineTicks.clock(from: lo, to: hi, step: tickStep, utcOffset: offset)
        case let .wod(start, end):
            return TimelineTicks.wod(from: lo, to: hi, wodStart: start.timeIntervalSince1970,
                                     wodEnd: end.timeIntervalSince1970, step: tickStep)
        }
    }

    private func tickLabel(_ t: TimelineTick) -> String {
        t.kind == .clock ? clock(t.ts, seconds: tickStep < 60) : TimelineTicks.label(t, step: tickStep)
    }

    /// The tick labels, under the last lane, at the same x as the lanes' tick lines.
    private var axisLabels: some View {
        let shown = ticks
        let frame = plotFrame
        return GeometryReader { geo in
            let originX = geo.frame(in: .named(Self.space)).minX
            ZStack(alignment: .topLeading) {
                ForEach(shown) { t in
                    Text(verbatim: tickLabel(t))
                        .font(StrandFont.footnote.monospacedDigit())
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize()
                        .position(x: min(xPosition(t.ts, in: frame), frame.maxX - 14) - originX, y: 7)
                }
            }
        }
        .frame(height: 14)
        .accessibilityHidden(true)
    }

    private func xPosition(_ ts: Double, in frame: CGRect) -> CGFloat {
        frame.minX + CGFloat((ts - lo) / span) * frame.width
    }

    private func plotFrameReporter(_ proxy: ChartProxy) -> some View {
        GeometryReader { geo in
            let local = proxy.plotRectCompat(in: geo)
            let origin = geo.frame(in: .named(Self.space)).origin
            Color.clear.preference(key: PlotFrameKey.self, value: local.offsetBy(dx: origin.x, dy: origin.y))
        }
    }

    // MARK: Readout text

    /// The window on screen ("18:05–19:40 · 1 h 35 min"), or the moment under the finger and where it sits
    /// against the WOD.
    private var windowText: String {
        if let s = scrubDate {
            let t = s.timeIntervalSince1970
            let time = clock(t, seconds: span < 1_800)
            guard case let .wod(start, end) = axis else { return time }
            return time + " · " + relativeToWod(t, start: start.timeIntervalSince1970, end: end.timeIntervalSince1970)
        }
        let range = clock(lo, seconds: span < 600) + "–" + clock(hi, seconds: span < 600)
        return range + " · " + duration(span)
    }

    private func relativeToWod(_ t: Double, start: Double, end: Double) -> String {
        if t < start {
            let m = Int(((start - t) / 60).rounded())
            return String(localized: "\(m) min before the WOD")
        }
        if t <= end {
            return String(localized: "\(TimelineTicks.workoutClock(t - start)) into the WOD")
        }
        return String(localized: "\(Int(((t - end) / 60).rounded())) min after the WOD")
    }

    private func duration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s) s" }
        if s < 3_600 { return "\(s / 60) min" }
        let m = (s % 3_600) / 60
        return m == 0 ? "\(s / 3_600) h" : "\(s / 3_600) h \(m) min"
    }

    private static let hm: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()
    private static let hms: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()

    private func clock(_ ts: Double, seconds: Bool) -> String {
        (seconds ? Self.hms : Self.hm).string(from: date(ts))
    }

    // MARK: Gestures

    /// Hold still for a moment, then slide: every lane reads the moment under the finger.
    private var scrubGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.25, maximumDistance: 8)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space)))
            .onChanged { value in
                guard case .second(true, let drag) = value else { return }
                if !scrubEngaged {
                    scrubEngaged = true
                    StrandHaptic.selection.play()
                }
                if let drag { scrub(atX: drag.location.x) }
            }
            .onEnded { _ in
                scrubEngaged = false
                var tx = Transaction()
                tx.disablesAnimations = true
                withTransaction(tx) { scrubDate = nil }
            }
    }

    private func scrub(atX x: CGFloat) {
        guard plotFrame.width > 0 else { return }
        let f = min(max(Double((x - plotFrame.minX) / plotFrame.width), 0), 1)
        var tx = Transaction()
        tx.disablesAnimations = true
        withTransaction(tx) { scrubDate = date(lo + f * span) }
    }

    /// A sideways drag moves the zoomed window along; a mostly vertical one is left to the page's scroll.
    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .named(Self.space))
            .onChanged { value in
                guard !scrubEngaged, !pinching, isZoomed, plotFrame.width > 0 else { return }
                if panDirection == .undecided {
                    panDirection = abs(value.translation.width) > abs(value.translation.height) ? .horizontal : .vertical
                }
                guard panDirection == .horizontal else { return }
                let base = gestureBase ?? visible
                if gestureBase == nil { gestureBase = base }
                let baseSpan = base.upperBound.timeIntervalSince(base.lowerBound)
                let seconds = -Double(value.translation.width) * baseSpan / Double(plotFrame.width)
                setZoom(OverviewHRChart.panned(base, deltaSeconds: seconds, bounds: bounds))
            }
            .onEnded { _ in
                gestureBase = nil
                panDirection = .undecided
            }
    }

    /// Pinch zooms about the point between the fingers.
    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                pinching = true
                let base = gestureBase ?? visible
                if gestureBase == nil { gestureBase = base }
                let anchor = plotFrame.width > 0
                    ? Double((value.startLocation.x - plotFrame.minX) / plotFrame.width) : 0.5
                setZoom(OverviewHRChart.zoomed(base, scale: Double(value.magnification),
                                               anchorFraction: anchor, bounds: bounds))
            }
            .onEnded { _ in
                pinching = false
                gestureBase = nil
            }
    }

    /// A window covering the whole bounds is no zoom at all.
    private func setZoom(_ window: ClosedRange<Date>) {
        zoom = (window.lowerBound <= bounds.lowerBound && window.upperBound >= bounds.upperBound) ? nil : window
    }

    private func zoomBy(_ scale: Double) {
        withAnimation(StrandMotion.interactive) {
            setZoom(OverviewHRChart.zoomed(visible, scale: scale, anchorFraction: 0.5, bounds: bounds))
        }
    }

    private func resetZoom() {
        guard isZoomed else { return }
        withAnimation(StrandMotion.interactive) { zoom = nil }
    }

    /// Zoom onto the WOD with a few minutes either side.
    private func focusWod() {
        guard case let .wod(start, end) = axis else { return }
        let pad = max(300, end.timeIntervalSince(start) * 0.25)
        let lower = max(start.addingTimeInterval(-pad), bounds.lowerBound)
        let upper = min(end.addingTimeInterval(pad), bounds.upperBound)
        guard upper > lower else { return }
        withAnimation(StrandMotion.interactive) { setZoom(lower...upper) }
    }
}

/// Where the lanes' plot sits in the timeline, so gestures and the tick labels map x to time.
private struct PlotFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if value == .zero { value = next }
    }
}

// MARK: - Settings

/// What the timelines show. Saved on this device and shared by the WOD screen, Today and full screen.
struct TimelineSettingsSheet: View {
    /// Offer the window around a WOD (only from the WOD screen).
    let showsWodWindow: Bool
    @Environment(\.dismiss) private var dismiss

    @AppStorage(TimelinePrefs.showGlucose) private var showGlucose = true
    @AppStorage(TimelinePrefs.showHeart) private var showHeart = true
    @AppStorage(TimelinePrefs.showEvents) private var showEvents = true
    @AppStorage(TimelinePrefs.showBands) private var showBands = true
    @AppStorage(TimelinePrefs.showTarget) private var showTarget = true
    @AppStorage(TimelinePrefs.showZones) private var showZones = false
    @AppStorage(TimelinePrefs.showStats) private var showStats = true
    @AppStorage(TimelinePrefs.targetLow) private var targetLow = 70.0
    @AppStorage(TimelinePrefs.targetHigh) private var targetHigh = 180.0
    @AppStorage(TimelinePrefs.size) private var sizeRaw = TimelineSize.standard.rawValue
    @AppStorage(TimelinePrefs.wodBeforeMinutes) private var wodBefore = TimelinePrefs.defaultWodBefore
    @AppStorage(TimelinePrefs.wodAfterMinutes) private var wodAfter = TimelinePrefs.defaultWodAfter

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Glucose", isOn: $showGlucose)
                    Toggle("Heart rate", isOn: $showHeart)
                    Toggle("Carbs & bolus", isOn: $showEvents)
                    Toggle("Workouts and WODs", isOn: $showBands)
                } header: {
                    Text("Lanes")
                }
                Section {
                    Toggle("Target range", isOn: $showTarget)
                    Stepper(value: $targetLow, in: 60...110, step: 5) {
                        LabeledContent("Lower limit", value: "\(Int(targetLow)) mg/dL")
                    }
                    Stepper(value: $targetHigh, in: 120...250, step: 5) {
                        LabeledContent("Upper limit", value: "\(Int(targetHigh)) mg/dL")
                    }
                } header: {
                    Text("Glucose")
                } footer: {
                    Text("Below 70 mg/dL is always shaded red: the consensus threshold for a low.")
                }
                Section {
                    Toggle("Heart-rate zones", isOn: $showZones)
                } header: {
                    Text("Heart rate")
                } footer: {
                    Text("Zones run from half your max heart rate up to it, in five equal steps (set your max heart rate in your profile).")
                }
                Section {
                    Toggle("Figures for the stretch on screen", isOn: $showStats)
                    Picker("Chart size", selection: $sizeRaw) {
                        ForEach(TimelineSize.allCases) { s in
                            Text(s.title).tag(s.rawValue)
                        }
                    }
                } header: {
                    Text("Display")
                }
                if showsWodWindow {
                    Section {
                        Picker("Before the WOD", selection: $wodBefore) {
                            ForEach([30, 60, 120, 180], id: \.self) { m in
                                Text(verbatim: minutesText(m)).tag(m)
                            }
                        }
                        Picker("After the WOD", selection: $wodAfter) {
                            ForEach([60, 120, 240, 360], id: \.self) { m in
                                Text(verbatim: minutesText(m)).tag(m)
                            }
                        }
                    } header: {
                        Text("Around a WOD")
                    } footer: {
                        Text("The figures above and below the chart keep their own window: 2 h before to 4 h after.")
                    }
                }
                Section {
                    Button("Restore defaults") { restoreDefaults() }
                }
            }
            .navigationTitle(Text("Customize chart"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func minutesText(_ m: Int) -> String {
        m < 60 ? "\(m) min" : "\(m / 60) h"
    }

    private func restoreDefaults() {
        showGlucose = true
        showHeart = true
        showEvents = true
        showBands = true
        showTarget = true
        showZones = false
        showStats = true
        targetLow = 70
        targetHigh = 180
        sizeRaw = TimelineSize.standard.rawValue
        wodBefore = TimelinePrefs.defaultWodBefore
        wodAfter = TimelinePrefs.defaultWodAfter
    }
}
#endif
