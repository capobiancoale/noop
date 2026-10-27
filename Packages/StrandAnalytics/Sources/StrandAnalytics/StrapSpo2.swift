import Foundation

// StrapSpo2.swift - a night's blood oxygen from the WHOOP 5.0/MG strap's OWN readings, as a pure aggregation.
//
// WHAT THE STRAP SENDS. A 5.0/MG history record (type 0x2f, layout 18, one a second) carries the strap's own
// SpO2 at frame byte 82 (the Interpreter's `aux_byte_82`; the firmware console logs "generated a valid SPO2
// during sleep"). The byte is 0 nearly always. While the band scores the wearer asleep the strap takes a
// 30 second reading about every 1200 s (the first one about 1175 s after the band's sleep bout starts), and
// during those 30 seconds the byte holds either a percentage (70...100) or a status code (1, 2, 8, 16, 32,
// 128, 160 and sums; bit-7 values are sentinels). Only 70...100 is a percentage; everything else is
// "the strap tried and says why it could not", which is counted but never averaged.
//
// THE RECIPE (community method, matched to the WHOOP app's own nightly value):
//   1. group the seconds into windows: a new window starts when a second is more than `maxGapSec` after the
//      previous one, or `maxSpanSec` or more after the window's first second;
//   2. a window counts only with at least `minSecondsPerWindow` in-range seconds;
//   3. the window's value is the MEDIAN of its in-range seconds (the LOWER middle for an even count);
//   4. the night's value is the MEAN of the window medians, rounded to one decimal;
//   5. a night needs at least `minWindowsPerNight` usable windows, otherwise there is NO value (never a guess).
//
// SOURCES AND VALIDATION. The recipe and the byte come from the community decoders (ryanbr/noop PR 709 and
// reinmaker/noop PR 73). PR 709 compared it with the WHOOP app's nightly SpO2 over eight nights: correlation
// +0.99, about 0.4 points a night of error. PR 73 compared six nights: mean 94.4 against WHOOP's 94.8. That is
// agreement with WHOOP's own number on a handful of nights, not a reference measurement.
//
// HONESTY LIMITS. This is the strap's own computation, not a medical measurement, and NOOP is not a medical
// device. A real dip in oxygen and a bad reading (a loose strap, a moving wrist) look the same here, so the
// number is a trend for the user to read next to how they feel, never a diagnosis. On the original capture
// device two nights moved the opposite way to the WHOOP app (Tools/spo2-validation/README.md), so a single
// night is not proof of anything. A strap that never reports the byte (a WHOOP 4.0) simply has no value.
//
// Pure: Foundation only, no I/O, no state, no UI strings.
public enum StrapSpo2 {

    // MARK: - Constants

    /// The byte values that are a percentage. Every other nonzero value is a status code.
    public static let validPct = 70...100
    /// A new window starts when a second is MORE than this many seconds after the previous one.
    public static let maxGapSec = 30
    /// ...or this many seconds or more after the window's first second (a window spans LESS than this).
    public static let maxSpanSec = 60
    /// A window needs at least this many in-range seconds to count.
    public static let minSecondsPerWindow = 5
    /// A night needs at least this many usable windows to produce a value.
    public static let minWindowsPerNight = 8

    // MARK: - Types

    /// One usable reading window: the strap's 30 s sleep-time measurement.
    public struct Window: Equatable {
        /// First and last in-range second of the window (unix seconds).
        public let start: Int
        public let end: Int
        /// In-range seconds in the window.
        public let seconds: Int
        /// Median of the in-range seconds (the lower middle for an even count), in percent.
        public let medianPct: Int
        public init(start: Int, end: Int, seconds: Int, medianPct: Int) {
            self.start = start; self.end = end; self.seconds = seconds; self.medianPct = medianPct
        }
    }

    /// One night's aggregate.
    public struct Night: Equatable {
        /// Mean of the usable windows' medians, one decimal; nil when fewer than `minWindowsPerNight`
        /// usable windows (no value, never a guess).
        public let pct: Double?
        /// The usable windows.
        public let windows: [Window]
        /// Windows of ANY nonzero byte-82 seconds, status codes included: how often the strap tried.
        public let attempted: Int
        /// In-range (percentage) seconds in the night span.
        public let readings: Int
        public init(pct: Double?, windows: [Window], attempted: Int, readings: Int) {
            self.pct = pct; self.windows = windows; self.attempted = attempted; self.readings = readings
        }
    }

    // MARK: - Windows

    /// The usable windows of `samples` (any span): in-range seconds grouped by the gap/span rule, windows
    /// with fewer than `minSecondsPerWindow` in-range seconds dropped. Input order does not matter and a
    /// repeated timestamp keeps its first value.
    public static func windows(_ samples: [(ts: Int, raw: Int)]) -> [Window] {
        let inRange = ordered(samples).filter { validPct.contains($0.raw) }
        return groups(inRange.map { $0.ts }, values: inRange.map { $0.raw }).compactMap { g in
            guard g.values.count >= minSecondsPerWindow else { return nil }
            return Window(start: g.start, end: g.end, seconds: g.values.count,
                          medianPct: lowerMedian(g.values))
        }
    }

    /// The night's aggregate over `[from, to]` (inclusive), or nil when there is no nonzero sample in that
    /// span (the strap said nothing at all, so there is nothing to report, not even an attempt count).
    public static func night(_ samples: [(ts: Int, raw: Int)], from: Int, to: Int) -> Night? {
        let span = ordered(samples).filter { $0.ts >= from && $0.ts <= to }
        guard !span.isEmpty else { return nil }
        let usable = windows(span)
        let attempted = groups(span.map { $0.ts }, values: span.map { $0.raw }).count
        let readings = span.filter { validPct.contains($0.raw) }.count
        let pct: Double? = usable.count >= minWindowsPerNight ? meanOfMedians(usable) : nil
        return Night(pct: pct, windows: usable, attempted: attempted, readings: readings)
    }

    // MARK: - Log

    /// One counts-only line for the strap log: usable/attempted windows, in-range seconds and the nightly
    /// value. "." is the decimal separator on purpose (it is a log, not UI) and there are no timestamps.
    public static func logLine(day: String, night: Night) -> String {
        let head = "spo2 day=\(day) strap windows=\(night.windows.count)/\(night.attempted) readings=\(night.readings)"
        guard let pct = night.pct else {
            return head + " nightly=none (needs \(minWindowsPerNight) windows)"
        }
        // `pct` is already rounded to one decimal, so print it from whole tenths: no locale, no float format.
        let tenths = Int((pct * 10).rounded())
        return head + " nightly=\(tenths / 10).\(tenths % 10)%"
    }

    // MARK: - Internals

    /// Nonzero samples ascending by ts with duplicate timestamps removed (the first one in input order wins).
    private static func ordered(_ samples: [(ts: Int, raw: Int)]) -> [(ts: Int, raw: Int)] {
        let sorted = samples.enumerated().sorted { a, b in
            a.element.ts != b.element.ts ? a.element.ts < b.element.ts : a.offset < b.offset
        }
        var out: [(ts: Int, raw: Int)] = []
        out.reserveCapacity(sorted.count)
        var lastTs: Int?
        for item in sorted {
            if item.element.ts == lastTs { continue }
            lastTs = item.element.ts
            if item.element.raw != 0 { out.append((ts: item.element.ts, raw: item.element.raw)) }
        }
        return out
    }

    private struct Group {
        var start: Int
        var end: Int
        var values: [Int]
    }

    /// Split ascending `ts` (parallel to `values`) into windows by the gap/span rule.
    private static func groups(_ ts: [Int], values: [Int]) -> [Group] {
        var out: [Group] = []
        for (i, t) in ts.enumerated() {
            if var cur = out.last, t - cur.end <= maxGapSec, t - cur.start < maxSpanSec {
                cur.end = t
                cur.values.append(values[i])
                out[out.count - 1] = cur
            } else {
                out.append(Group(start: t, end: t, values: [values[i]]))
            }
        }
        return out
    }

    /// Median with the LOWER middle for an even count.
    private static func lowerMedian(_ values: [Int]) -> Int {
        let sorted = values.sorted()
        return sorted[(sorted.count - 1) / 2]
    }

    /// Mean of the windows' medians, rounded to one decimal.
    private static func meanOfMedians(_ windows: [Window]) -> Double {
        let total = windows.reduce(0) { $0 + $1.medianPct }
        let mean = Double(total) / Double(windows.count)
        return (mean * 10).rounded() / 10
    }
}
