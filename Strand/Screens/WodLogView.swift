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
                    ForEach(benchmarks) { b in
                        NavigationLink {
                            WodProgressionView(title: b.title) { Task { await reload() } }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(b.title).font(.body)
                                    Text("\(b.count) attempts").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                benchBests(b)
                            }
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

    private struct Bench: Identifiable {
        let title: String
        let best: [WodRanking.Best]
        let count: Int
        var id: String { WodRanking.titleKey(title) }
    }

    /// One "best" row per WOD title (trimmed, case-insensitive) that has ≥ 2 attempts. The best is the
    /// min finish time / max rounds + reps / max reps / max weight, ranked apart for RX and scaled
    /// attempts; attempts without a real result never count (see `WodRanking`).
    private var benchmarks: [Bench] {
        var out: [Bench] = []
        for g in WodRanking.groupByTitle(wods) where g.rows.count >= 2 {
            let best = WodRanking.bests(of: g.rows)
            if best.isEmpty { continue }
            out.append(Bench(title: g.title, best: best, count: g.rows.count))
        }
        return out.sorted { $0.count > $1.count }
    }

    /// The best result (RX first), with a scaled best as a smaller second line when there is one.
    private func benchBests(_ b: Bench) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            ForEach(Array(b.best.enumerated()), id: \.offset) { idx, entry in
                benchLine(entry, tagged: b.best.count > 1 || entry.group == .scaled, primary: idx == 0)
            }
        }
    }

    private func benchLine(_ entry: WodRanking.Best, tagged: Bool, primary: Bool) -> some View {
        HStack(spacing: 4) {
            if tagged, entry.group != .unspecified {
                Text(WodFormat.rxLabel(entry.group == .rx)).font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Text(WodFormat.result(entry.row) ?? "")
                .font(primary ? .body.monospacedDigit() : .caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - History row

/// The small "RX" / "Scaled" capsule, shared by the log, the detail, the attempts list and the import preview.
struct WodRxBadge: View {
    let rx: Bool
    var body: some View {
        Text(WodFormat.rxLabel(rx))
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background((rx ? Color.green : Color.orange).opacity(0.22), in: Capsule())
    }
}

private struct WodRowView: View {
    let wod: WodLogRow
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(wod.title.isEmpty ? WodFormat.typeLabel(wod.type) : wod.title).font(.body).foregroundStyle(.primary)
                if let rx = wod.rx { WodRxBadge(rx: rx) }
                Spacer()
                if let r = WodFormat.result(wod) {
                    Text(r).font(.body.monospacedDigit()).foregroundStyle(.primary)
                }
            }
            Text(WodFormat.typeLine(wod))
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

    /// "RX" / "Scaled" in the user's language.
    static func rxLabel(_ rx: Bool) -> String {
        rx ? String(localized: "RX") : String(localized: "Scaled")
    }

    /// A WOD type or format for display. The stored value stays the English token; only the label is
    /// localized. An unknown (typed or imported) value is shown as it is.
    static func typeLabel(_ raw: String) -> String {
        switch raw {
        case "Weightlifting": return String(localized: "Weightlifting")
        case "Running":       return String(localized: "Running")
        case "Rowing":        return String(localized: "Rowing")
        case "Other":         return String(localized: "Other")
        case "Strength":      return String(localized: "Strength")
        case "Intervals":     return String(localized: "Intervals")
        default:              return raw
        }
    }

    /// "Type · Format · day" for a list row or the import preview.
    static func typeLine(_ w: WodLogRow) -> String {
        var parts = [typeLabel(w.type)]
        if let f = w.format, !f.isEmpty { parts.append(typeLabel(f)) }
        parts.append(day(w.ts))
        return parts.joined(separator: " · ")
    }

    /// Every attempt at `title` in `all` (trimmed, case-insensitive), newest first.
    static func history(title: String, in all: [WodLogRow]) -> [WodLogRow] {
        let key = WodRanking.titleKey(title)
        return all.filter { WodRanking.titleKey($0.title) == key }.sorted { $0.ts > $1.ts }
    }

    /// "12 reps" with the number first or last as the language wants.
    static func repsLabel(_ n: Int) -> String { String(localized: "\(n) reps") }

    /// "62.5 kg" with a locale-aware number.
    static func kgLabel(_ v: Double) -> String { String(localized: "\(trimmed(v)) kg") }

    /// A WOD's own result, formatted for its kind. Nil when there's no numeric result (a row saved with a
    /// blank result, or the old 0:00, counts as none).
    static func result(_ w: WodLogRow) -> String? {
        switch w.effectiveResultKind {
        case .time:       return w.resultSeconds.map(clock)
        case .roundsReps: return "\(w.resultRounds ?? 0) + \(w.resultReps ?? 0)"
        case .reps:       return w.resultReps.map(repsLabel)
        case .weight:     return w.resultWeightKg.map(kgLabel)
        case .none:       return nil
        }
    }

    /// A movement summarised for a one-line list: "Thruster · 21-15-9 · 23 done · 30 kg (RX 43)". Only
    /// the parts that are present are shown, so a bare "Pull-up" stays "Pull-up".
    static func movement(_ m: WodMovement) -> String {
        var parts: [String] = [m.name]
        if let s = m.scheme, !s.isEmpty { parts.append(s) }
        else if let r = m.reps { parts.append("\(r)") }
        if let d = m.repsDone { parts.append(String(localized: "\(d) done")) }
        if let me = m.weightKg, let rx = m.rxWeightKg {
            parts.append(String(localized: "\(trimmed(me)) kg (RX \(trimmed(rx)))"))
        } else if let rx = m.rxWeightKg {
            parts.append(String(localized: "RX \(trimmed(rx)) kg"))
        } else if let me = m.weightKg {
            parts.append(kgLabel(me))
        }
        return parts.joined(separator: " · ")
    }

    /// Rounds + reps are packed into one plotted number: rounds × this + reps. Only a plotted value, for
    /// the chart (and the Health export); ranking compares the (rounds, reps) pair itself.
    static let roundsRepsUnit = 100_000.0

    /// A comparable numeric value for a WOD's result, for plotting progression over time. nil when the
    /// WOD has no result.
    static func progressionValue(_ w: WodLogRow) -> Double? {
        switch w.effectiveResultKind {
        case .time:       return w.resultSeconds.map(Double.init)
        case .roundsReps: return Double(w.resultRounds ?? 0) * roundsRepsUnit + Double(w.resultReps ?? 0)
        case .reps:       return w.resultReps.map(Double.init)
        case .weight:     return w.resultWeightKg
        case .none:       return nil
        }
    }

    /// Label a progression value for the given result kind (chart tooltip).
    static func progressionLabel(_ v: Double, kind: WodResultKind) -> String {
        switch kind {
        case .time:       return clock(Int(v))
        case .roundsReps:
            let packed = Int(v.rounded())
            let unit = Int(roundsRepsUnit)
            return "\(packed / unit)+\(packed % unit)"
        case .reps:       return "\(Int(v))"
        case .weight:     return kgLabel(v)
        case .none:       return ""
        }
    }

    /// mm:ss from seconds.
    static func clock(_ s: Int) -> String { String(format: "%d:%02d", s / 60, s % 60) }

    /// Drop a trailing ".0" so 60.0 → "60" but 62.5 stays "62.5".
    static func trimmed(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : DisplayNumber.decimal(v)
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none; return f
    }()
}

#endif
