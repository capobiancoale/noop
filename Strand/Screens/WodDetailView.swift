#if os(iOS)
import SwiftUI
import WhoopStore
import StrandImport
import StrandDesign

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
    @EnvironmentObject private var health: HealthKitBridge
    @Environment(\.dismiss) private var dismiss

    let onChanged: () -> Void
    @State private var current: WodLogRow
    @State private var history: [WodLogRow] = []
    @State private var showEdit = false

    // Glucose + carbs + insulin around the WOD (Apple Health, queried live).
    @State private var glucosePoints: [TrendPoint] = []
    @State private var glucoseResp: WodGlucoseResponse?
    @State private var carbsPre = 0.0
    @State private var carbsPost = 0.0
    @State private var bolusPre = 0.0
    @State private var bolusPost = 0.0
    @State private var trendPerHour: Double?
    @State private var glucoseLoading = false
    @State private var glucoseLoaded = false

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

    // MARK: Progression (all attempts at this title)

    private var progressionPoints: [TrendPoint] {
        history.compactMap { w in
            WodFormat.progressionValue(w).map {
                TrendPoint(date: Date(timeIntervalSince1970: TimeInterval(w.ts)), value: $0)
            }
        }
    }

    private var progressionSection: some View {
        let pts = progressionPoints
        let kind = history.first?.resultKind ?? .none
        let vals = pts.map(\.value)
        let lo = vals.min() ?? 0
        let hi = vals.max() ?? 1
        return Section {
            TrendChart(points: pts,
                       gradient: Gradient(colors: [StrandPalette.effortColor.opacity(0.5), StrandPalette.effortColor]),
                       valueRange: lo...max(hi, lo + 1),
                       height: 150,
                       valueFormat: { WodFormat.progressionLabel($0, kind: kind) },
                       dateFormat: { WodFormat.day(Int($0.timeIntervalSince1970)) },
                       accessibilityLabel: "Progression")
            Text("\(pts.count) attempts").font(.caption).foregroundStyle(.secondary)
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
            } else if let r = glucoseResp {
                HStack {
                    stat("Before", "\(Int(r.startMgdl.rounded()))")
                    Spacer()
                    stat("After", "\(Int(r.endMgdl.rounded()))")
                    Spacer()
                    stat("Lowest", "\(Int(r.minMgdl.rounded()))")
                }
                if !glucosePoints.isEmpty {
                    TrendChart(points: glucosePoints,
                               gradient: Gradient(colors: [StrandPalette.metricCyan, StrandPalette.metricRose]),
                               valueRange: 40...300,
                               height: 130,
                               valueFormat: { "\(Int($0.rounded())) mg/dL" },
                               dateFormat: { Self.clock.string(from: $0) },
                               accessibilityLabel: "Glucose around this WOD")
                }
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
                    Label("Went below 70 mg/dL in this window", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
                if let note = tendencyNote() { Text(note).font(.caption).foregroundStyle(.secondary) }
                Text("Informational only, not medical advice. Carb and insulin choices stay with you and your care team / Loop.")
                    .font(.caption2).foregroundStyle(.tertiary)
            } else if glucoseLoaded {
                Text("No glucose readings in Apple Health for this window.")
                    .foregroundStyle(.secondary).font(.subheadline)
            } else {
                EmptyView()
            }
        } header: {
            Text("Glucose & carbs · 2h before → 4h after")
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
        let workoutStart = TimeInterval(e.ts)
        let workoutEnd = workoutStart + TimeInterval(e.timeCapS ?? 20 * 60)
        let preStart = workoutStart - 2 * 3600
        let postEnd = workoutEnd + 4 * 3600
        let start = Date(timeIntervalSince1970: preStart)
        let end = Date(timeIntervalSince1970: postEnd)
        let readings = await health.glucoseWindow(start: start, end: end)
        let carbs = await health.carbsWindow(start: start, end: end)
        let insulin = await health.insulinWindow(start: start, end: end)
        glucosePoints = readings.map { TrendPoint(date: Date(timeIntervalSince1970: $0.ts), value: $0.mgdl) }
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

    /// After the edit sheet closes: refresh the list, re-read this WOD (or pop if it was deleted).
    private func reloadAfterEdit() {
        onChanged()
        Task {
            let all = await repo.allWods()
            if let updated = all.first(where: { $0.id == current.id }) {
                current = updated
                history = await repo.wodHistory(title: current.title)
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

#endif
