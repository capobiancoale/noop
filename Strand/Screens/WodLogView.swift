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
    @State private var editing: WodLogRow?

    var body: some View {
        List {
            Section {
                Button { showNew = true } label: {
                    Label("Log a WOD", systemImage: "plus.circle.fill")
                        .font(.headline)
                }
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
                        Button { editing = w } label: { WodRowView(wod: w) }
                            .buttonStyle(.plain)
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
        .sheet(item: $editing) { w in
            WodEditorView(existing: w) { Task { await reload() } }
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
            HStack {
                Text(wod.title.isEmpty ? wod.type : wod.title).font(.body).foregroundStyle(.primary)
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
                Text(wod.movements.map(\.name).joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
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
