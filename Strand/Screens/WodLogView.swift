#if os(iOS)
import SwiftUI
import WhoopStore
import StrandDesign
import StrandAnalytics

// MARK: - WOD / strength log (user-authored)
//
// A simple on-device logger for CrossFit / strength workouts (WODs): pick a type, name the WOD, add
// movements (reps + load), record the result (time / rounds+reps / reps / weight), and see past
// attempts and per-WOD bests. Distinct from the read-only `workout` rows imported from Apple Health /
// the strap — these are what the user types in. Storage is `WhoopStore.wodLog` (migration v23), read
// and written through the `Repository.saveWod` / `allWods` / `deleteWod` wrappers.
//
// Layout: the app's own scaffold (large title on the sky, cards with a hairline border) instead of a
// system List. Top to bottom: actions + import hint, Strength progress row, Bests card, History card.
// A List's swipe-to-delete is not available in a card, so delete lives on a long-press context menu
// (and a VoiceOver action) on each history row.

struct WodLogView: View {
    @EnvironmentObject private var repo: Repository
    @State private var wods: [WodLogRow] = []
    @State private var loaded = false
    @State private var showNew = false
    @State private var showImport = false
    /// Derived from `wods` once per reload, never in `body`.
    @State private var benches: [Bench] = []
    @State private var strengthCount = 0

    var body: some View {
        ScreenScaffold(title: "WOD log", subtitle: "Your CrossFit sessions, loads and records.",
                       onRefresh: { await reload() },
                       topBackground: liquidScaffoldSky()) {
            if loaded && wods.isEmpty {
                AnyView(emptyCard)
                AnyView(importBlock)
            } else {
                AnyView(actionsBlock)
            }
            if !wods.isEmpty {
                AnyView(strengthRow)
            }
            if !benches.isEmpty {
                AnyView(bestsSection)
            }
            if !wods.isEmpty {
                AnyView(historySection)
            }
        }
        .sheet(isPresented: $showNew) {
            WodEditorView(existing: nil) { Task { await reload() } }
        }
        .sheet(isPresented: $showImport) {
            WodImportView { Task { await reload() } }
        }
        .task { await reload() }
    }

    private func reload() async {
        let all = await repo.allWods()
        wods = all
        benches = Self.makeBenches(all)
        strengthCount = StrengthProgress.movements(from: all).count
        loaded = true
    }

    private func delete(_ w: WodLogRow) {
        let id = w.id
        Task { await repo.deleteWod(id: id); await reload() }
    }

    // MARK: Small building blocks

    private var hairline: some View {
        Divider().overlay(StrandPalette.hairline)
    }

    /// The tinted symbol tile used across the newer cards (36 x 36, 12 pt corners).
    private func symbolTile(_ symbol: String, tint: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 36, height: 36)
            .background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityHidden(true)
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(StrandPalette.textTertiary)
            .accessibilityHidden(true)
    }

    // MARK: Actions

    private var logButton: some View {
        NoopButton("Log a WOD", systemImage: "plus.circle.fill", kind: .primary, fullWidth: true) {
            showNew = true
        }
    }

    private var importButton: some View {
        NoopButton("Import from text", systemImage: "doc.text.viewfinder", kind: .secondary, fullWidth: true) {
            showImport = true
        }
    }

    private var importHint: some View {
        Text("Get the WOD as a photo? Have any AI turn it into text, then paste it here — movements, RX and your loads fill in automatically.")
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
    }

    private var actionsBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            logButton
            importButton
            importHint
        }
    }

    private var importBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            importButton
            importHint
        }
    }

    private var emptyCard: some View {
        NoopCard(padding: 20, tint: StrandPalette.effortColor) {
            VStack(alignment: .leading, spacing: 14) {
                symbolTile("figure.strengthtraining.traditional", tint: StrandPalette.effortColor)
                Text("No WODs logged yet. Tap “Log a WOD” to record your first CrossFit session or lift — add the movements, reps and weight, and your progress builds from here.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                logButton
            }
        }
    }

    // MARK: Strength progress row

    private var strengthRow: some View {
        NavigationLink {
            StrengthProgressView()
        } label: {
            NoopCard(padding: 14) {
                HStack(spacing: 12) {
                    symbolTile("chart.line.uptrend.xyaxis", tint: StrandPalette.statusPositive)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Strength progress")
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Movements tracked: \(strengthCount)")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    chevron
                }
                .frame(minHeight: 44)
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: String(localized: "Strength progress") + ", " + String(localized: "Movements tracked: \(strengthCount)")))
        .accessibilityAddTraits(.isButton)
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
    private static func makeBenches(_ wods: [WodLogRow]) -> [Bench] {
        var out: [Bench] = []
        for g in WodRanking.groupByTitle(wods) where g.rows.count >= 2 {
            let best = WodRanking.bests(of: g.rows)
            if best.isEmpty { continue }
            out.append(Bench(title: g.title, best: best, count: g.rows.count))
        }
        return out.sorted { $0.count > $1.count }
    }

    private var bestsSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Bests", overline: "Records")
            NoopCard(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(benches.enumerated()), id: \.element.id) { idx, b in
                        VStack(spacing: 0) {
                            if idx > 0 { hairline }
                            benchRow(b)
                        }
                    }
                }
            }
        }
    }

    private func benchRow(_ b: Bench) -> some View {
        NavigationLink {
            WodProgressionView(title: b.title) { Task { await reload() } }
        } label: {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: b.title)
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("\(b.count) attempts")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                benchBests(b)
                    .layoutPriority(1)
                chevron
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: benchLabel(b)))
        .accessibilityAddTraits(.isButton)
    }

    private func benchLabel(_ b: Bench) -> String {
        var parts = [b.title, String(localized: "\(b.count) attempts")]
        for entry in b.best {
            let tag = entry.group == .unspecified ? "" : WodFormat.rxLabel(entry.group == .rx) + " "
            parts.append(tag + (WodFormat.result(entry.row) ?? ""))
        }
        return parts.joined(separator: ", ")
    }

    /// The best result (RX first) prominent, with a scaled best as a smaller second line when there is one.
    private func benchBests(_ b: Bench) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            ForEach(Array(b.best.enumerated()), id: \.offset) { idx, entry in
                benchLine(entry, tagged: b.best.count > 1 || entry.group == .scaled, primary: idx == 0)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func benchLine(_ entry: WodRanking.Best, tagged: Bool, primary: Bool) -> some View {
        HStack(spacing: 4) {
            if tagged, entry.group != .unspecified {
                Text(verbatim: WodFormat.rxLabel(entry.group == .rx))
                    .font(StrandFont.footnote.weight(.semibold))
                    .foregroundStyle(entry.group == .rx ? StrandPalette.statusPositive : StrandPalette.statusWarning)
            }
            Text(verbatim: WodFormat.result(entry.row) ?? "")
                .font(primary ? StrandFont.number(18) : StrandFont.captionNumber)
                .foregroundStyle(primary ? StrandPalette.textPrimary : StrandPalette.textSecondary)
        }
    }

    // MARK: History

    private var historySection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("History", overline: "Log", trailing: "\(wods.count)")
            NoopCard(padding: 0) {
                LazyVStack(spacing: 0) {
                    ForEach(Array(wods.enumerated()), id: \.element.id) { idx, w in
                        VStack(spacing: 0) {
                            if idx > 0 { hairline }
                            historyRow(w)
                        }
                    }
                }
            }
        }
    }

    private func historyRow(_ w: WodLogRow) -> some View {
        NavigationLink {
            WodDetailView(wod: w) { Task { await reload() } }
        } label: {
            WodRowView(wod: w)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) { delete(w) } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .accessibilityAction(named: Text("Delete")) { delete(w) }
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

    private var displayTitle: String { wod.title.isEmpty ? WodFormat.typeLabel(wod.type) : wod.title }

    private var dateText: String {
        Date(timeIntervalSince1970: TimeInterval(wod.ts)).formatted(date: .abbreviated, time: .omitted)
    }

    /// "Type · Format" as one chip so a long Italian pair wraps inside it instead of overflowing.
    private var chipText: String {
        var parts = [WodFormat.typeLabel(wod.type)]
        if let f = wod.format, !f.isEmpty { parts.append(WodFormat.typeLabel(f)) }
        return parts.joined(separator: " · ")
    }

    private var movementsText: String {
        wod.movements.map(WodFormat.movement).joined(separator: ", ")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: displayTitle)
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: dateText)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                chips
                if !wod.movements.isEmpty {
                    Text(verbatim: movementsText)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let r = WodFormat.result(wod) {
                Text(verbatim: r)
                    .font(StrandFont.number(18))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: accessibilityText))
        .accessibilityAddTraits(.isButton)
    }

    private var chips: some View {
        HStack(spacing: 6) {
            Text(verbatim: chipText)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(StrandPalette.surfaceInset, in: Capsule(style: .continuous))
            if let rx = wod.rx { WodRxBadge(rx: rx) }
        }
    }

    private var accessibilityText: String {
        var parts = [displayTitle, dateText, chipText]
        if let rx = wod.rx { parts.append(WodFormat.rxLabel(rx)) }
        if let r = WodFormat.result(wod) { parts.append(r) }
        if !wod.movements.isEmpty { parts.append(movementsText) }
        return parts.joined(separator: ", ")
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
