import Foundation

/// A running count of the historical record layouts a strap has handed over, kept across sessions and app
/// launches (the app stores it in UserDefaults). The strap log only holds its newest lines, so a night of
/// offloads scrolls out of it by morning; this tally keeps the answer to "did the strap ever send layout
/// vN?" in the log header instead. It matters for the WHOOP 5.0: only its v20/v21 records carry the
/// multi-channel optical waveforms an SpO2 estimate would need (`Tools/spo2-validation`).
public struct HistoryLayoutTally: Codable, Equatable, Sendable {
    /// Records seen per layout version.
    public private(set) var counts: [Int: Int] = [:]
    /// Unix seconds of the last record seen per layout version.
    public private(set) var lastSeen: [Int: Double] = [:]
    /// Unix seconds of the first record ever counted, nil while empty.
    public private(set) var since: Double?

    /// The WHOOP 5.0 layouts that carry several optical channels per record.
    public static let opticalVersions: [Int] = [20, 21]

    public init() {}

    /// Count one record per entry of `versions` (one entry per decoded record, so repeats are expected).
    public mutating func record(versions: [Int], at now: Double) {
        guard !versions.isEmpty else { return }
        if since == nil { since = now }
        for v in versions {
            counts[v, default: 0] += 1
            lastSeen[v] = now
        }
    }

    /// One header line for the strap log, e.g.
    /// "History layouts since 24 Oct 21:03: v18 41200 (last 25 Oct 09:08), v26 1310 (last 25 Oct 08:57). No v20/v21 optical records yet."
    /// `formatTime` renders a unix time; injected so the line is testable without a time zone.
    public func summaryLine(formatTime: (Double) -> String) -> String {
        guard let since, !counts.isEmpty else { return "History layouts: none counted yet." }
        let parts = counts.keys.sorted().map { v in
            "v\(v) \(counts[v] ?? 0) (last \(lastSeen[v].map(formatTime) ?? "?"))"
        }
        var line = "History layouts since \(formatTime(since)): " + parts.joined(separator: ", ") + "."
        if !Self.opticalVersions.contains(where: { counts[$0] != nil }) {
            line += " No v20/v21 optical records yet."
        }
        return line
    }
}
