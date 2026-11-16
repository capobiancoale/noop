import Foundation

// MARK: - WOD import: spot rows that are already in the log
//
// Re-importing the same text or CSV would otherwise add every WOD a second time. A row counts as
// already present when an existing WOD has the same `day` and the same title, compared trimmed and
// case-insensitively. Pure: the caller passes the existing rows.

public enum WodImportMatch {
    public struct Split: Equatable, Sendable {
        /// Rows with no match in the log, in their original order.
        public let fresh: [WodLogRow]
        /// Rows that match an existing WOD, in their original order.
        public let duplicates: [WodLogRow]
    }

    /// `day|title` with the title trimmed and lower-cased.
    public static func key(day: String, title: String) -> String {
        day.trimmingCharacters(in: .whitespacesAndNewlines) + "|" + WodRanking.titleKey(title)
    }

    public static func split(imported: [WodLogRow], existing: [WodLogRow]) -> Split {
        let known = Set(existing.map { key(day: $0.day, title: $0.title) })
        var fresh: [WodLogRow] = []
        var dup: [WodLogRow] = []
        for r in imported {
            if known.contains(key(day: r.day, title: r.title)) { dup.append(r) } else { fresh.append(r) }
        }
        return Split(fresh: fresh, duplicates: dup)
    }
}
