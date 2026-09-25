import Foundation

// MARK: - What NOOP writes into Apple Health (plan)
//
// NOOP writes the strap's data into Apple Health so other apps can see it: the daily resting heart rate,
// HRV, SpO₂ and respiratory rate, the heart rate minute by minute, and each night's sleep with its stages.
// This file is the pure part (no HealthKit), so it is tested on its own: which minutes of heart rate a run
// still has to write, how a night's stages become sleep samples, when a night must be written again, and
// dates that are never in the future. The HealthKit side is StrandiOS/Health/HealthKitBridge.swift.

public enum HealthWritePlan {

    // MARK: Heart rate, minute by minute

    /// How far back the first run writes heart rate.
    public static let heartRateBackfillDays = 14
    /// Each later run also looks this far behind the newest minute already written, so readings the strap
    /// offloads late (hours or a couple of days after it recorded them) still get in.
    public static let heartRateLookBack = 72.0 * 3_600
    /// Only minutes that ended at least this long ago: the strap's latest seconds may still be arriving.
    public static let settleSeconds = 120.0
    /// Averages outside this range are artefacts, never written.
    public static let plausibleBpm: ClosedRange<Double> = 25...250

    /// The whole minutes [from, to) this run looks at: back to the newest minute already written minus
    /// `heartRateLookBack` (the first time, `heartRateBackfillDays`), never further than that backfill, up
    /// to the last minute that has settled. Nil when there is nothing to look at.
    public static func heartRateWindow(now: Double, newestWritten: Double?) -> (from: Double, to: Double)? {
        let to = ((now - settleSeconds) / 60).rounded(.down) * 60
        let earliest = to - Double(heartRateBackfillDays) * 86_400
        var from = earliest
        if let newest = newestWritten {
            from = max(earliest, ((newest - heartRateLookBack) / 60).rounded(.down) * 60)
        }
        return to > from ? (from, to) : nil
    }

    /// [from, to) cut into consecutive pieces of at most `seconds` (one read and one save each).
    public static func chunks(from: Double, to: Double, seconds: Double = 86_400) -> [(from: Double, to: Double)] {
        guard to > from, seconds > 0 else { return [] }
        var out: [(from: Double, to: Double)] = []
        var start = from
        while start < to {
            let end = min(to, start + seconds)
            out.append((start, end))
            start = end
        }
        return out
    }

    /// The strap's per-minute averages Apple Health doesn't have from NOOP yet (`alreadyWritten` holds
    /// minute numbers, `Int(ts) / 60`), plausible values only, oldest first.
    public static func missingMinutes(_ strap: [(ts: Double, bpm: Double)],
                                      alreadyWritten: Set<Int>) -> [(ts: Double, bpm: Double)] {
        strap.filter { plausibleBpm.contains($0.bpm) && !alreadyWritten.contains(Int($0.ts) / 60) }
            .sorted { $0.ts < $1.ts }
    }

    // MARK: Sleep

    /// A stretch of one night, as Apple Health's sleep categories.
    public enum SleepKind: Equatable, Sendable {
        case inBed, awake, core, deep, rem
    }

    public struct SleepSegment: Equatable, Sendable {
        public let start: Double
        public let end: Double
        public let kind: SleepKind
        public init(start: Double, end: Double, kind: SleepKind) {
            self.start = start; self.end = end; self.kind = kind
        }
    }

    /// Nights are written once they have ended, within this many days.
    public static let sleepDays = 14

    /// A night as sleep samples: "in bed" from its onset to its end, plus each stage NOOP staged (light is
    /// Apple's "core"), clipped to that span. A night known only by its totals (a WHOOP import) or without
    /// stages is written as in bed only: its stages have no times to place them at.
    public static func sleepSegments(start: Double, end: Double, stagesJSON: String?) -> [SleepSegment] {
        guard end > start else { return [] }
        var out = [SleepSegment(start: start, end: end, kind: .inBed)]
        guard let json = stagesJSON, let data = json.data(using: .utf8),
              let array = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return out }
        var stages: [SleepSegment] = []
        for seg in array {
            guard let s = (seg["start"] as? NSNumber)?.doubleValue,
                  let e = (seg["end"] as? NSNumber)?.doubleValue,
                  let name = seg["stage"] as? String else { continue }
            let kind: SleepKind
            switch name {
            case "wake", "awake": kind = .awake
            case "light": kind = .core
            case "deep": kind = .deep
            case "rem": kind = .rem
            default: continue
            }
            let lo = max(s, start), hi = min(e, end)
            if hi > lo { stages.append(SleepSegment(start: lo, end: hi, kind: kind)) }
        }
        out += stages.sorted { $0.start < $1.start }
        return out
    }

    /// What a night looked like when it was written. When it changes (the night grew, its onset was
    /// corrected, it was staged again), the night is written again.
    public static func sleepFingerprint(start: Double, end: Double, stagesJSON: String?) -> String {
        "\(Int(start))|\(Int(end))|\(fnv1a(stagesJSON ?? ""))"
    }

    /// The span a fingerprint was written over, to remove it before writing the night again.
    public static func span(ofFingerprint fingerprint: String) -> (start: Double, end: Double)? {
        let parts = fingerprint.split(separator: "|")
        guard parts.count == 3, let s = Double(parts[0]), let e = Double(parts[1]) else { return nil }
        return (s, e)
    }

    /// A stable 64-bit FNV-1a hash (Swift's `hashValue` changes from one launch to the next).
    static func fnv1a(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    // MARK: Daily values

    /// A day's value is dated at noon of that day, or now when noon hasn't come yet: Apple Health gets no
    /// samples from the future.
    public static func sampleDate(noon: Double, now: Double) -> Double {
        min(noon, now - 60)
    }
}
