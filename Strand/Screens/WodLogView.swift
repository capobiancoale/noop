#if os(iOS)
import SwiftUI
import WhoopStore

// MARK: - WOD / strength log (user-authored)
//
// A simple on-device logger for CrossFit / strength workouts (WODs): pick a type, name the WOD, add
// movements (reps + load), record the result (time / rounds+reps / reps / weight), and see past
// attempts and per-WOD bests. Distinct from the read-only `workout` rows imported from Apple Health /
// the strap — these are what the user types in. Storage is `WhoopStore.wodLog` (migration v23), read
// and written through the `Repository.saveWod` / `allWods` / `deleteWod` wrappers.

struct WodLogView: View {
    @EnvironmentObject private var repo: Repository
    @State private var wods: [WodLogRow] = []
    @State private var loaded = false
    @State private var showNew = false
    @State private var showImport = false

    var body: some View {
        List {
            Section {
                Button { showNew = true } label: {
                    Label("Log a WOD", systemImage: "plus.circle.fill")
                        .font(.headline)
                }
                Button { showImport = true } label: {
                    Label("Import from text", systemImage: "doc.text.viewfinder")
                }
            } footer: {
                Text("Get the WOD as a photo? Have any AI turn it into text, then paste it here — movements, RX and your loads fill in automatically.")
            }

            if loaded && wods.isEmpty {
                Section {
                    Text("No WODs logged yet. Tap “Log a WOD” to record your first CrossFit session or lift — add the movements, reps and weight, and your progress builds from here.")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                }
            }

            if !benchmarks.isEmpty {
                Section("Bests") {
                    ForEach(benchmarks, id: \.title) { b in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(b.title).font(.body)
                                Text("\(b.count) attempts").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(b.best).font(.body.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if !wods.isEmpty {
                Section("History") {
                    ForEach(wods) { w in
                        NavigationLink { WodDetailView(wod: w) { Task { await reload() } } } label: { WodRowView(wod: w) }
                    }
                    .onDelete { offsets in
                        let ids = offsets.map { wods[$0].id }
                        Task { for id in ids { await repo.deleteWod(id: id) }; await reload() }
                    }
                }
            }
        }
        .navigationTitle("WOD Log")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showNew) {
            WodEditorView(existing: nil) { Task { await reload() } }
        }
        .sheet(isPresented: $showImport) {
            WodImportView { Task { await reload() } }
        }
        .task { await reload() }
    }

    private func reload() async {
        wods = await repo.allWods()
        loaded = true
    }

    // MARK: Bests (per-title progress)

    private struct Bench { let title: String; let best: String; let count: Int }

    /// One "best" row per WOD title that has ≥ 2 attempts — the progress at a glance. The best is the
    /// min finish time / max rounds / max reps / max weight, matching each WOD's own result kind.
    private var benchmarks: [Bench] {
        let byTitle = Dictionary(grouping: wods, by: { $0.title })
        var out: [Bench] = []
        for (title, rows) in byTitle where rows.count >= 2 {
            guard let best = WodFormat.best(of: rows) else { continue }
            out.append(Bench(title: title, best: best, count: rows.count))
        }
        return out.sorted { $0.count > $1.count }
    }
}

// MARK: - History row

private struct WodRowView: View {
    let wod: WodLogRow
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(wod.title.isEmpty ? wod.type : wod.title).font(.body).foregroundStyle(.primary)
                if let rx = wod.rx {
                    Text(rx ? "RX" : "Scaled")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background((rx ? Color.green : Color.orange).opacity(0.22), in: Capsule())
                }
                Spacer()
                if let r = WodFormat.result(wod) {
                    Text(r).font(.body.monospacedDigit()).foregroundStyle(.primary)
                }
            }
            HStack(spacing: 6) {
                Text(wod.type)
                if let f = wod.format, !f.isEmpty { Text("· \(f)") }
                Text("· \(WodFormat.day(wod.ts))")
            }
            .font(.caption).foregroundStyle(.secondary)
            if !wod.movements.isEmpty {
                Text(wod.movements.map(WodFormat.movement).joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

// MARK: - Formatting helpers (shared by the list + bests)

enum WodFormat {
    static func day(_ ts: Int) -> String {
        dayFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }

    /// A WOD's own result, formatted for its kind. Nil when there's no numeric result.
    static func result(_ w: WodLogRow) -> String? {
        switch w.resultKind {
        case .time:       return w.resultSeconds.map(clock)
        case .roundsReps: return w.resultRounds.map { "\($0) + \(w.resultReps ?? 0)" }
        case .reps:       return w.resultReps.map { "\($0) reps" }
        case .weight:     return w.resultWeightKg.map { "\(trimmed($0)) kg" }
        case .none:       return nil
        }
    }

    /// The best result across attempts of one WOD title (all assumed same kind as the first).
    static func best(of rows: [WodLogRow]) -> String? {
        guard let kind = rows.first?.resultKind else { return nil }
        switch kind {
        case .time:
            return rows.compactMap { $0.resultSeconds }.min().map(clock)
        case .roundsReps:
            // Rank by total reps ≈ rounds*100 + extra, so more rounds always wins.
            let best = rows.max { ($0.resultRounds ?? 0) * 100 + ($0.resultReps ?? 0) < ($1.resultRounds ?? 0) * 100 + ($1.resultReps ?? 0) }
            return best.flatMap { r in r.resultRounds.map { "\($0) + \(r.resultReps ?? 0)" } }
        case .reps:
            return rows.compactMap { $0.resultReps }.max().map { "\($0) reps" }
        case .weight:
            return rows.compactMap { $0.resultWeightKg }.max().map { "\(trimmed($0)) kg" }
        case .none:
            return nil
        }
    }

    /// A movement summarised for a one-line list: "Thruster · 21-15-9 · 30 kg (RX 43)". Only the parts
    /// that are present are shown, so a bare "Pull-up" stays "Pull-up".
    static func movement(_ m: WodMovement) -> String {
        var parts: [String] = [m.name]
        if let s = m.scheme, !s.isEmpty { parts.append(s) }
        else if let r = m.reps { parts.append("\(r)") }
        if let me = m.weightKg, let rx = m.rxWeightKg {
            parts.append("\(trimmed(me)) kg (RX \(trimmed(rx)))")
        } else if let rx = m.rxWeightKg {
            parts.append("RX \(trimmed(rx)) kg")
        } else if let me = m.weightKg {
            parts.append("\(trimmed(me)) kg")
        }
        return parts.joined(separator: " · ")
    }

    /// A comparable numeric value for a WOD's result, for plotting progression over time. nil for `.none`.
    static func progressionValue(_ w: WodLogRow) -> Double? {
        switch w.resultKind {
        case .time:       return w.resultSeconds.map(Double.init)
        case .roundsReps: return w.resultRounds.map { Double($0 * 100 + (w.resultReps ?? 0)) }
        case .reps:       return w.resultReps.map(Double.init)
        case .weight:     return w.resultWeightKg
        case .none:       return nil
        }
    }

    /// Label a progression value for the given result kind (chart tooltip).
    static func progressionLabel(_ v: Double, kind: WodResultKind) -> String {
        switch kind {
        case .time:       return clock(Int(v))
        case .roundsReps: return "\(Int(v) / 100)+\(Int(v) % 100)"
        case .reps:       return "\(Int(v))"
        case .weight:     return "\(trimmed(v)) kg"
        case .none:       return ""
        }
    }

    /// mm:ss from seconds.
    static func clock(_ s: Int) -> String { String(format: "%d:%02d", s / 60, s % 60) }

    /// Drop a trailing ".0" so 60.0 → "60" but 62.5 stays "62.5".
    static func trimmed(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none; return f
    }()
}

#endif
