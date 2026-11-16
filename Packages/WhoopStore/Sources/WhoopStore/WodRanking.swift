import Foundation

// MARK: - WOD results: "no result" rows, bests per title, RX vs scaled
//
// Pure helpers (no database, no clock) behind the WOD log's Bests, the progression chart and the result
// shown on a row. Older rows were saved with `resultKind == .time` and `resultSeconds == 0` when the
// result fields were left blank; `effectiveResultKind` reads those as "no result" without a migration.

extension WodLogRow {
    /// The result kind that actually carries a number: `.none` for a row logged without a result,
    /// including the old "0:00 time" (or 0 reps / 0 kg / 0 + 0) a blank form used to save.
    public var effectiveResultKind: WodResultKind {
        switch resultKind {
        case .time:
            return (resultSeconds ?? 0) > 0 ? .time : .none
        case .roundsReps:
            guard resultRounds != nil || resultReps != nil else { return .none }
            return ((resultRounds ?? 0) > 0 || (resultReps ?? 0) > 0) ? .roundsReps : .none
        case .reps:
            return (resultReps ?? 0) > 0 ? .reps : .none
        case .weight:
            return (resultWeightKg ?? 0) > 0 ? .weight : .none
        case .none:
            return .none
        }
    }

    /// True when the row carries a real result to display or rank.
    public var hasResult: Bool { effectiveResultKind != .none }
}

public enum WodRanking {
    /// How an attempt is ranked: RX and scaled apart. `unspecified` only exists for a title where no
    /// attempt has the RX flag set (otherwise an unflagged attempt is grouped with the scaled ones).
    public enum Group: Equatable, Sendable { case rx, scaled, unspecified }

    public struct Best: Equatable, Sendable {
        public let group: Group
        public let row: WodLogRow
    }

    /// Grouping key for a title: trimmed and case-insensitive ("Fran", "fran " and "FRAN" are one WOD).
    public static func titleKey(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// The kind the title's results are compared on: that of its most recent row with a result.
    public static func primaryKind(of rows: [WodLogRow]) -> WodResultKind {
        rows.filter(\.hasResult).max { $0.ts < $1.ts }?.effectiveResultKind ?? .none
    }

    /// The group of one attempt among `rows` (the attempts at the same title).
    public static func group(of row: WodLogRow, among rows: [WodLogRow]) -> Group {
        group(of: row, titleHasRx: rows.contains { $0.rx != nil })
    }

    private static func group(of row: WodLogRow, titleHasRx: Bool) -> Group {
        switch row.rx {
        case .some(true): return .rx
        case .some(false): return .scaled
        case .none: return titleHasRx ? .scaled : .unspecified
        }
    }

    /// Is `a` a better result than `b`? Both must carry a result of the same kind. Rounds + reps compare
    /// as the pair (rounds, reps), not as one packed number.
    public static func isBetter(_ a: WodLogRow, than b: WodLogRow) -> Bool {
        switch a.effectiveResultKind {
        case .time:
            return (a.resultSeconds ?? Int.max) < (b.resultSeconds ?? Int.max)
        case .roundsReps:
            let x = (a.resultRounds ?? 0, a.resultReps ?? 0)
            let y = (b.resultRounds ?? 0, b.resultReps ?? 0)
            return x.0 != y.0 ? x.0 > y.0 : x.1 > y.1
        case .reps:
            return (a.resultReps ?? 0) > (b.resultReps ?? 0)
        case .weight:
            return (a.resultWeightKg ?? 0) > (b.resultWeightKg ?? 0)
        case .none:
            return false
        }
    }

    /// The best attempt per group among `rows` (the attempts at ONE title), RX first, then scaled, then
    /// unspecified; groups with no ranked attempt are left out. Only rows with a real result of the
    /// title's primary kind compete. On a tie the earlier attempt keeps the record.
    public static func bests(of rows: [WodLogRow]) -> [Best] {
        let kind = primaryKind(of: rows)
        guard kind != .none else { return [] }
        let titleHasRx = rows.contains { $0.rx != nil }
        let ranked = rows.filter { $0.effectiveResultKind == kind }.sorted { $0.ts < $1.ts }
        var best: [Group: WodLogRow] = [:]
        for r in ranked {
            let g = group(of: r, titleHasRx: titleHasRx)
            if let cur = best[g], !isBetter(r, than: cur) { continue }
            best[g] = r
        }
        return [Group.rx, .scaled, .unspecified].compactMap { g in best[g].map { Best(group: g, row: $0) } }
    }

    /// Rows grouped by title key (see `titleKey`), newest first inside each group. `title` is the
    /// spelling of the most recent attempt. Groups come out in order of their most recent attempt.
    public static func groupByTitle(_ rows: [WodLogRow]) -> [(title: String, rows: [WodLogRow])] {
        var order: [String] = []
        var buckets: [String: [WodLogRow]] = [:]
        for r in rows.sorted(by: { $0.ts > $1.ts }) {
            let k = titleKey(r.title)
            if buckets[k] == nil { order.append(k) }
            buckets[k, default: []].append(r)
        }
        return order.map { k in
            let rs = buckets[k] ?? []
            return (title: rs.first.map { $0.title.trimmingCharacters(in: .whitespacesAndNewlines) } ?? k, rows: rs)
        }
    }
}
