#if os(iOS)
import SwiftUI
import Charts
import WhoopStore
import StrandDesign
import StrandAnalytics

// MARK: - Strength progress
//
// Per-movement lifting history, weekly lifted volume and records, computed by the pure
// `StrengthProgress` engine from the user's own logged WODs (`repo.allWods()`). WOD loads are stored and
// shown in kg only (the WOD log has no imperial mode), so this screen is kg-only too.

// MARK: Formatting helpers

enum StrengthFormat {
    /// "yyyy-MM-dd" (the app's local day key) parsed with a fixed POSIX formatter, in the local zone.
    private static let dayParser: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static func date(_ day: String) -> Date? { dayParser.date(from: day) }

    /// A day string in the user's locale ("12 Nov 2026"); the raw string if it cannot be parsed.
    static func dayLabel(_ day: String) -> String {
        guard let d = date(day) else { return day }
        return d.formatted(date: .abbreviated, time: .omitted)
    }

    /// Short "12 Nov" label for an axis.
    static func shortDayLabel(_ day: String) -> String {
        guard let d = date(day) else { return day }
        return d.formatted(.dateTime.day().month(.abbreviated))
    }

    /// A load: "62.5 kg" with the locale's separator, no trailing ".0".
    static func kg(_ v: Double) -> String { WodFormat.kgLabel(v) }

    /// A volume in whole kg with the locale's grouping: "12,450 kg".
    static func volume(_ v: Double) -> String {
        let n = v.formatted(.number.precision(.fractionLength(0)))
        return String(localized: "\(n) kg")
    }

    /// "5 × 5", "5 sets", "3 reps" or nil when neither is known.
    static func setsReps(_ e: StrengthProgress.Entry) -> String? {
        if let s = e.sets, let r = e.reps { return String(localized: "\(s) × \(r)") }
        if let s = e.sets { return String(localized: "\(s) sets") }
        if let r = e.reps { return WodFormat.repsLabel(r) }
        return nil
    }

    /// Records set on or after `cutoffDay` ("yyyy-MM-dd", compared as text).
    static func recordCount(_ movements: [StrengthProgress.Movement], since cutoffDay: String) -> Int {
        var n = 0
        for m in movements {
            for e in m.entries where e.isRecord && e.day >= cutoffDay { n += 1 }
        }
        return n
    }
}

private struct StrengthPRBadge: View {
    var body: some View {
        Text("PR")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color.orange.opacity(0.22), in: Capsule())
    }
}

// MARK: - Screen

struct StrengthProgressView: View {
    @EnvironmentObject private var repo: Repository
    @State private var movements: [StrengthProgress.Movement] = []
    @State private var weeks: [StrengthProgress.WeekVolume] = []
    @State private var recentRecords = 0
    @State private var loaded = false
    @State private var query = ""
    @State private var showNew = false

    private var filtered: [StrengthProgress.Movement] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { return movements }
        return movements.filter { $0.displayName.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        List {
            if loaded && movements.isEmpty {
                emptySection
            } else if loaded {
                Section { StrengthSummaryRow(movementCount: movements.count, records: recentRecords,
                                             week: weeks.last) }
                Section {
                    StrengthWeeklyChart(weeks: weeks)
                } header: { Text("Weekly volume") }
                movementsSection
            }
        }
        .navigationTitle("Strength progress")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showNew) {
            WodEditorView(existing: nil) { Task { await load() } }
        }
        .task { await load() }
    }

    private var emptySection: some View {
        Section {
            Text("Loads you enter on a WOD's movements appear here. Log a WOD with a weight on a movement to start your strength history.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button { showNew = true } label: {
                Label("Log a WOD", systemImage: "plus.circle.fill").font(.headline)
            }
        }
    }

    private var movementsSection: some View {
        Section {
            if movements.count > 8 {
                TextField("Search movements", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            ForEach(filtered, id: \.key) { m in
                NavigationLink {
                    StrengthMovementDetailView(movement: m)
                } label: {
                    StrengthMovementRow(movement: m)
                }
            }
        } header: {
            Text("Movements")
        } footer: {
            Text("The estimated 1RM uses the Epley formula for sets of 1 to 10 reps. It is an estimate, not a tested max.")
        }
    }

    private func load() async {
        let wods = await repo.allWods()
        let today = Repository.localDayKey(Date())
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
        let cutoff = Repository.localDayKey(cutoffDate)
        let list = StrengthProgress.movements(from: wods)
        movements = list
        weeks = StrengthProgress.weeklyVolume(from: wods, weeks: 8, today: today)
        recentRecords = StrengthFormat.recordCount(list, since: cutoff)
        loaded = true
    }
}

// MARK: - Header summary

private struct StrengthSummaryRow: View {
    let movementCount: Int
    let records: Int
    let week: StrengthProgress.WeekVolume?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            tile(value: Text(verbatim: String(movementCount)), caption: Text("Movements"))
            tile(value: Text(verbatim: String(records)), caption: Text("Records, last 30 days"))
            tile(value: Text(verbatim: weekValue), caption: weekCaption)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(summary))
    }

    private var weekValue: String {
        guard let w = week, w.entries > 0 else { return "–" }
        return StrengthFormat.volume(w.volumeKg)
    }

    private var partial: Bool { (week?.skipped ?? 0) > 0 }

    private var weekCaption: Text {
        partial ? Text("This week, partial") : Text("This week")
    }

    private var summary: String {
        let base = String(localized: "\(movementCount) movements, \(records) records in the last 30 days.")
        guard let w = week, w.entries > 0 else { return base }
        let vol = StrengthFormat.volume(w.volumeKg)
        let weekText = partial ? String(localized: "This week's volume \(vol), partial.")
                               : String(localized: "This week's volume \(vol).")
        return base + " " + weekText
    }

    private func tile(value: Text, caption: Text) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            value.font(.title3.weight(.semibold).monospacedDigit())
                .minimumScaleFactor(0.7).lineLimit(1)
            caption.font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Weekly volume chart

private struct StrengthWeeklyChart: View {
    let weeks: [StrengthProgress.WeekVolume]

    private var skipped: Int { weeks.reduce(0) { $0 + $1.skipped } }
    private var total: Int { weeks.reduce(0) { $0 + $1.entries } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Chart {
                ForEach(weeks, id: \.weekStart) { w in
                    BarMark(x: .value("Week", StrengthFormat.shortDayLabel(w.weekStart)),
                            y: .value("Volume", w.volumeKg))
                        .foregroundStyle(StrandPalette.effortColor.opacity(0.8))
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(StrandPalette.hairline)
                    AxisValueLabel()
                }
            }
            .frame(height: 170)
            .accessibilityLabel(Text("Weekly volume in kg, last 8 weeks"))
            .accessibilityValue(Text(chartSummary))

            Text("Volume counts only movements where sets and reps are known.")
                .font(.caption).foregroundStyle(.secondary)
            Text("\(skipped) of \(total) loaded entries left out.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var chartSummary: String {
        weeks.map { "\(StrengthFormat.dayLabel($0.weekStart)): \(StrengthFormat.volume($0.volumeKg))" }
            .joined(separator: ", ")
    }
}

// MARK: - Movement row

private struct StrengthMovementRow: View {
    let movement: StrengthProgress.Movement

    private var latestIsRecord: Bool { movement.entries.last?.isRecord ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(movement.displayName).font(.body)
            Text("Latest \(StrengthFormat.kg(movement.latestWeightKg)) · \(StrengthFormat.dayLabel(movement.latestDay))")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Text("Best \(StrengthFormat.kg(movement.bestWeightKg))")
                if latestIsRecord { StrengthPRBadge() }
                if let r = movement.best1RM {
                    Spacer(minLength: 6)
                    Text("est. 1RM")
                    Text(verbatim: StrengthFormat.kg(r))
                }
            }
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
    }

    private var label: String {
        var s = String(localized: "\(movement.displayName), latest \(StrengthFormat.kg(movement.latestWeightKg)) on \(StrengthFormat.dayLabel(movement.latestDay)), best \(StrengthFormat.kg(movement.bestWeightKg)).")
        if latestIsRecord { s += " " + String(localized: "Latest lift is a personal record.") }
        if let r = movement.best1RM { s += " " + String(localized: "Estimated 1RM \(StrengthFormat.kg(r)).") }
        return s
    }
}

// MARK: - Movement detail

struct StrengthMovementDetailView: View {
    let movement: StrengthProgress.Movement
    @State private var showEstimate = false

    private var hasEstimate: Bool { movement.entries.contains { $0.estimated1RM != nil } }

    var body: some View {
        List {
            Section {
                StrengthMovementChart(movement: movement, showEstimate: showEstimate && hasEstimate)
                if hasEstimate {
                    Toggle("Show estimated 1RM", isOn: $showEstimate)
                }
            } header: { Text("Load over time") }

            Section {
                ForEach(Array(movement.entries.reversed().enumerated()), id: \.offset) { _, e in
                    StrengthEntryRow(entry: e)
                }
            } header: { Text("Entries") }
        }
        .navigationTitle(movement.displayName)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct StrengthPoint: Identifiable {
    let id: Int
    let date: Date
    let value: Double
    let record: Bool
}

private struct StrengthMovementChart: View {
    let movement: StrengthProgress.Movement
    let showEstimate: Bool

    private var loadPoints: [StrengthPoint] {
        var out: [StrengthPoint] = []
        for (i, e) in movement.entries.enumerated() {
            guard let d = StrengthFormat.date(e.day) else { continue }
            out.append(StrengthPoint(id: i, date: d, value: e.weightKg, record: e.isRecord))
        }
        return out
    }

    private var estimatePoints: [StrengthPoint] {
        var out: [StrengthPoint] = []
        for (i, e) in movement.entries.enumerated() {
            guard let d = StrengthFormat.date(e.day), let v = e.estimated1RM else { continue }
            out.append(StrengthPoint(id: i, date: d, value: v, record: false))
        }
        return out
    }

    var body: some View {
        let load = loadPoints
        let estimate = showEstimate ? estimatePoints : []
        return VStack(alignment: .leading, spacing: 6) {
            if load.count >= 2 {
                chart(load: load, estimate: estimate)
                legend
            } else {
                Text("Log this movement at least twice to see a trend.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private func chart(load: [StrengthPoint], estimate: [StrengthPoint]) -> some View {
        Chart {
            ForEach(load) { p in
                LineMark(x: .value("Date", p.date), y: .value("Load", p.value),
                         series: .value("Series", "Load"))
                    .foregroundStyle(StrandPalette.effortColor.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
            ForEach(load) { p in
                PointMark(x: .value("Date", p.date), y: .value("Load", p.value))
                    .symbolSize(p.record ? 90 : 30)
                    .foregroundStyle(p.record ? Color.orange : StrandPalette.effortColor)
            }
            ForEach(estimate) { p in
                LineMark(x: .value("Date", p.date), y: .value("Estimated 1RM", p.value),
                         series: .value("Series", "Estimated 1RM"))
                    .foregroundStyle(StrandPalette.textSecondary)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(StrandPalette.hairline)
                AxisValueLabel()
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(StrandPalette.hairline)
                AxisValueLabel(format: .dateTime.day().month(.abbreviated))
            }
        }
        .frame(height: 190)
        .accessibilityLabel(Text("Load over time in kg"))
        .accessibilityValue(Text(summary))
    }

    private var legend: some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                Circle().fill(Color.orange).frame(width: 8, height: 8)
                Text("PR")
            }
            if showEstimate { Text("Dashed line: estimated 1RM") }
        }
        .font(.caption).foregroundStyle(.secondary)
    }

    private var summary: String {
        let entries = movement.entries
        guard let first = entries.first, let last = entries.last else { return "" }
        let records = entries.filter { $0.isRecord }.count
        return String(localized: "\(entries.count) entries from \(StrengthFormat.kg(first.weightKg)) to \(StrengthFormat.kg(last.weightKg)), best \(StrengthFormat.kg(movement.bestWeightKg)), \(records) records.")
    }
}

private struct StrengthEntryRow: View {
    let entry: StrengthProgress.Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(StrengthFormat.dayLabel(entry.day)).font(.subheadline)
                if entry.isRecord { StrengthPRBadge() }
                Spacer(minLength: 6)
                Text(verbatim: StrengthFormat.kg(entry.weightKg))
                    .font(.body.monospacedDigit())
            }
            detailLine
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
    }

    private var detailLine: some View {
        HStack(spacing: 8) {
            if let sr = StrengthFormat.setsReps(entry) { Text(verbatim: sr) }
            if let v = entry.volumeKg { Text("Volume \(StrengthFormat.volume(v))") }
            if let r = entry.estimated1RM { Text("est. 1RM \(StrengthFormat.kg(r))") }
        }
        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
    }

    private var label: String {
        var s = "\(StrengthFormat.dayLabel(entry.day)), \(StrengthFormat.kg(entry.weightKg))"
        if let sr = StrengthFormat.setsReps(entry) { s += ", " + sr }
        if let v = entry.volumeKg { s += ", " + String(localized: "Volume \(StrengthFormat.volume(v))") }
        if let r = entry.estimated1RM { s += ", " + String(localized: "est. 1RM \(StrengthFormat.kg(r))") }
        if entry.isRecord { s += ", " + String(localized: "personal record") }
        return s
    }
}

#endif
