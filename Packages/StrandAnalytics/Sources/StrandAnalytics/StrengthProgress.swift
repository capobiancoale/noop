import Foundation
import WhoopStore

// StrengthProgress.swift — per-movement strength history and weekly lifted volume, from the user's own
// logged WODs (`WodLogRow.movements`).
//
// What it computes, and nothing more:
//   • One `Entry` per (WOD, movement) that has a lifted load (`weightKg` > 0). The load is what the athlete
//     lifted, not the prescribed RX load. A WOD scored "none" still counts: the loads are the data, the
//     score is irrelevant here.
//   • Movements are grouped by a normalised name: trimmed, inner whitespace collapsed, lower-cased with a
//     fixed locale (en_US_POSIX), and a plural folded to its singular ONLY through the small explicit alias
//     table `aliases` ("back squats" → "back squat"). No fuzzy matching: "front squat" and "back squat" stay
//     apart, a spelling the table does not know stays its own movement. The display name is the most recent
//     raw spelling.
//   • Reps and sets per entry, in this order of preference:
//       1. `repsDone` (reps actually completed) → reps. Sets come from the scheme only when it is "NxM"
//          (N sets). With an "a-b-c" scheme `repsDone` is read as the total (one set), never multiplied.
//       2. scheme "NxM" ("5x5", "5 x 5", "5×5", any case of x) → N sets of M reps.
//       3. scheme "a-b-c" of integers → sets = count of numbers; reps stay nil (they vary) but the total reps
//          (the sum) feed the volume.
//       4. otherwise the plain `reps` count (one set, sets nil).
//       5. anything else: reps unknown.
//   • Estimated 1RM, Epley (1985): 1RM ≈ kg · (1 + reps / 30), only when the per-set reps are known and in
//     1...10 (one rep is the weight itself). It is an ESTIMATE, more reliable for few reps, and is never to
//     be shown as a measured max; a set of 11 or more reps, or varying reps, gives nil.
//   • Volume (kg) = sets · reps · kg when both are known; total reps · kg for an "a-b-c" scheme or a plain
//     reps count (one set); nil when the reps are unknown. Never guessed. A weekly total that leaves such
//     entries out says how many (`skipped`) so the UI can call it partial.
//   • A record: the load is strictly greater than every earlier entry of the same movement (order by ts,
//     ties by day, then input order). The first entry of a movement is not a record, a tie is not a record.
//     This is the heaviest load only; it says nothing about reps.
//   • Weeks are ISO weeks (Monday start) computed on the day strings with a fixed Gregorian UTC calendar,
//     so no time zone and no clock are involved: the caller says what "today" is.
//
// Limits: the log is free text typed by the athlete, so a unit slip (lb typed as kg) or a mistyped scheme
// shows up as is; entries are never filtered for plausibility. Loads of 0 or less (bodyweight) are not
// strength entries and are ignored. This is a history of what was logged, not coaching advice.
public enum StrengthProgress {

    // MARK: - Types

    public struct Entry: Equatable, Sendable {
        public var day: String
        public var ts: Int
        public var wodId: String
        public var weightKg: Double
        /// Reps per set when known (nil for varying reps such as 21-15-9, or unknown).
        public var reps: Int?
        public var sets: Int?
        /// Epley estimate; nil unless per-set reps are known and 1...10. An estimate, not a measured max.
        public var estimated1RM: Double?
        /// sets · reps · kg, or total reps · kg; nil when the reps are unknown.
        public var volumeKg: Double?
        public var isRecord: Bool

        public init(day: String, ts: Int, wodId: String, weightKg: Double, reps: Int? = nil,
                    sets: Int? = nil, estimated1RM: Double? = nil, volumeKg: Double? = nil,
                    isRecord: Bool = false) {
            self.day = day; self.ts = ts; self.wodId = wodId; self.weightKg = weightKg
            self.reps = reps; self.sets = sets; self.estimated1RM = estimated1RM
            self.volumeKg = volumeKg; self.isRecord = isRecord
        }
    }

    public struct Movement: Equatable, Sendable {
        public var key: String
        public var displayName: String
        /// Oldest first.
        public var entries: [Entry]
        public var bestWeightKg: Double
        /// The first day the best load was lifted.
        public var bestDay: String
        public var latestWeightKg: Double
        public var latestDay: String
        public var best1RM: Double?

        public init(key: String, displayName: String, entries: [Entry], bestWeightKg: Double,
                    bestDay: String, latestWeightKg: Double, latestDay: String, best1RM: Double?) {
            self.key = key; self.displayName = displayName; self.entries = entries
            self.bestWeightKg = bestWeightKg; self.bestDay = bestDay
            self.latestWeightKg = latestWeightKg; self.latestDay = latestDay; self.best1RM = best1RM
        }
    }

    public struct WeekVolume: Equatable, Sendable {
        /// Monday of the ISO week, yyyy-MM-dd.
        public var weekStart: String
        public var volumeKg: Double
        /// Loaded movement entries in the week (volume known or not).
        public var entries: Int
        /// Of those, how many had no computable volume (so `volumeKg` is partial).
        public var skipped: Int

        public init(weekStart: String, volumeKg: Double, entries: Int, skipped: Int) {
            self.weekStart = weekStart; self.volumeKg = volumeKg
            self.entries = entries; self.skipped = skipped
        }
    }

    // MARK: - Name normalisation

    /// The only plural folding there is. Keys and values are already normalised (lower case, single spaces).
    static let aliases: [String: String] = [
        "back squats": "back squat",
        "front squats": "front squat",
        "overhead squats": "overhead squat",
        "squats": "squat",
        "deadlifts": "deadlift",
        "sumo deadlifts": "sumo deadlift",
        "thrusters": "thruster",
        "cleans": "clean",
        "power cleans": "power clean",
        "squat cleans": "squat clean",
        "hang cleans": "hang clean",
        "snatches": "snatch",
        "power snatches": "power snatch",
        "squat snatches": "squat snatch",
        "hang snatches": "hang snatch",
        "presses": "press",
        "shoulder presses": "shoulder press",
        "push presses": "push press",
        "bench presses": "bench press",
        "jerks": "jerk",
        "push jerks": "push jerk",
        "split jerks": "split jerk",
        "clean and jerks": "clean and jerk",
        "clean & jerks": "clean & jerk",
        "kettlebell swings": "kettlebell swing",
        "wall balls": "wall ball",
        "lunges": "lunge",
        "walking lunges": "walking lunge",
        "rows": "row",
        "barbell rows": "barbell row",
    ]

    /// Trim, collapse inner whitespace, lower-case (en_US_POSIX), then fold a plural through `aliases`.
    public static func normalizedName(_ raw: String) -> String {
        let words = raw.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let joined = words.joined(separator: " ").lowercased(with: Locale(identifier: "en_US_POSIX"))
        return aliases[joined] ?? joined
    }

    // MARK: - Reps, sets, volume

    struct Parsed: Equatable {
        var reps: Int?       // per set, for the 1RM
        var sets: Int?
        var totalReps: Int?  // for the volume
    }

    static func parseScheme(_ scheme: String?) -> (sets: Int, reps: Int)? {
        guard let s = scheme else { return nil }
        let t = s.lowercased().replacingOccurrences(of: "×", with: "x").filter { !$0.isWhitespace }
        let parts = t.split(separator: "x", omittingEmptySubsequences: false)
        guard parts.count == 2, let n = Int(parts[0]), let m = Int(parts[1]), n > 0, m > 0 else { return nil }
        return (n, m)
    }

    static func parseVarying(_ scheme: String?) -> [Int]? {
        guard let s = scheme else { return nil }
        let t = s.filter { !$0.isWhitespace }
        let parts = t.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        var out: [Int] = []
        for p in parts {
            guard let v = Int(p), v > 0 else { return nil }
            out.append(v)
        }
        return out
    }

    static func parse(_ m: WodMovement) -> Parsed {
        let nxm = parseScheme(m.scheme)
        let varying = nxm == nil ? parseVarying(m.scheme) : nil
        if let done = m.repsDone, done > 0 {
            if let nxm { return Parsed(reps: done, sets: nxm.sets, totalReps: done * nxm.sets) }
            return Parsed(reps: done, sets: nil, totalReps: done)
        }
        if let nxm { return Parsed(reps: nxm.reps, sets: nxm.sets, totalReps: nxm.reps * nxm.sets) }
        if let varying { return Parsed(reps: nil, sets: varying.count, totalReps: varying.reduce(0, +)) }
        if let r = m.reps, r > 0 { return Parsed(reps: r, sets: nil, totalReps: r) }
        return Parsed(reps: nil, sets: nil, totalReps: nil)
    }

    /// Epley (1985), reps 1...10 only; nil otherwise.
    public static func epley1RM(weightKg: Double, reps: Int?) -> Double? {
        guard let reps, (1...10).contains(reps), weightKg > 0 else { return nil }
        return reps == 1 ? weightKg : weightKg * (1 + Double(reps) / 30)
    }

    static func entry(for m: WodMovement, in wod: WodLogRow) -> Entry? {
        guard let kg = m.weightKg, kg > 0, kg.isFinite else { return nil }
        let p = parse(m)
        let volume = p.totalReps.map { Double($0) * kg }
        return Entry(day: wod.day, ts: wod.ts, wodId: wod.id, weightKg: kg, reps: p.reps, sets: p.sets,
                     estimated1RM: epley1RM(weightKg: kg, reps: p.reps), volumeKg: volume, isRecord: false)
    }

    // MARK: - Movements

    public static func movements(from wods: [WodLogRow]) -> [Movement] {
        struct Raw { var entry: Entry; var name: String; var order: Int }
        var groups: [String: [Raw]] = [:]
        var order = 0
        for wod in wods {
            for m in wod.movements {
                let key = normalizedName(m.name)
                guard !key.isEmpty, let e = entry(for: m, in: wod) else { continue }
                groups[key, default: []].append(Raw(entry: e, name: m.name, order: order))
                order += 1
            }
        }
        var out: [Movement] = []
        for (key, raws) in groups {
            let sorted = raws.sorted {
                if $0.entry.ts != $1.entry.ts { return $0.entry.ts < $1.entry.ts }
                if $0.entry.day != $1.entry.day { return $0.entry.day < $1.entry.day }
                return $0.order < $1.order
            }
            var entries: [Entry] = []
            var maxSoFar = -Double.infinity
            for r in sorted {
                var e = r.entry
                e.isRecord = !entries.isEmpty && e.weightKg > maxSoFar
                maxSoFar = max(maxSoFar, e.weightKg)
                entries.append(e)
            }
            let best = entries.map(\.weightKg).max() ?? 0
            let bestDay = entries.first(where: { $0.weightKg == best })?.day ?? ""
            let latest = entries[entries.count - 1]
            let raw = sorted[sorted.count - 1].name
            let display = raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            out.append(Movement(key: key, displayName: display, entries: entries, bestWeightKg: best,
                                bestDay: bestDay, latestWeightKg: latest.weightKg, latestDay: latest.day,
                                best1RM: entries.compactMap(\.estimated1RM).max()))
        }
        return out.sorted {
            if $0.entries.count != $1.entries.count { return $0.entries.count > $1.entries.count }
            return $0.key < $1.key
        }
    }

    // MARK: - Calendar helpers (fixed Gregorian UTC)

    private static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0)!
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }

    private static func pad(_ v: Int, _ n: Int) -> String {
        let s = String(v)
        return String(repeating: "0", count: max(0, n - s.count)) + s
    }

    private static func date(_ day: String) -> Date? {
        let p = day.split(separator: "-", omittingEmptySubsequences: false)
        guard p.count == 3, p[0].count == 4, p[1].count == 2, p[2].count == 2,
              let y = Int(p[0]), let m = Int(p[1]), let d = Int(p[2]) else { return nil }
        let cal = calendar
        guard let dt = cal.date(from: DateComponents(year: y, month: m, day: d)) else { return nil }
        let c = cal.dateComponents([.year, .month, .day], from: dt)
        return (c.year == y && c.month == m && c.day == d) ? dt : nil
    }

    private static func key(_ dt: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: dt)
        return "\(pad(c.year ?? 0, 4))-\(pad(c.month ?? 0, 2))-\(pad(c.day ?? 0, 2))"
    }

    private static func mondayStart(_ dt: Date) -> Date {
        let cal = calendar
        let wd = cal.component(.weekday, from: dt)  // 1 = Sunday
        return cal.date(byAdding: .day, value: -((wd + 5) % 7), to: dt) ?? dt
    }

    private static func dayNumber(_ day: String) -> Int? {
        guard let d = date(day) else { return nil }
        return Int((d.timeIntervalSince1970 / 86_400).rounded(.down))
    }

    // MARK: - Weekly volume

    public static func weeklyVolume(from wods: [WodLogRow], weeks: Int, today: String) -> [WeekVolume] {
        guard weeks > 0, let t = date(today) else { return [] }
        let cal = calendar
        let thisMonday = mondayStart(t)
        var starts: [String] = []
        for i in stride(from: weeks - 1, through: 0, by: -1) {
            guard let d = cal.date(byAdding: .day, value: -7 * i, to: thisMonday) else { return [] }
            starts.append(key(d))
        }
        var acc: [String: (vol: Double, n: Int, skipped: Int)] = [:]
        for s in starts { acc[s] = (0, 0, 0) }
        for wod in wods {
            guard let d = date(wod.day) else { continue }
            let ws = key(mondayStart(d))
            guard var a = acc[ws] else { continue }
            for m in wod.movements {
                guard !normalizedName(m.name).isEmpty, let e = entry(for: m, in: wod) else { continue }
                a.n += 1
                if let v = e.volumeKg { a.vol += v } else { a.skipped += 1 }
            }
            acc[ws] = a
        }
        return starts.map { s in
            let a = acc[s] ?? (0, 0, 0)
            return WeekVolume(weekStart: s, volumeKg: a.vol, entries: a.n, skipped: a.skipped)
        }
    }

    // MARK: - Coach context

    /// Plain-English lines, one per movement with an entry in the last `windowDays` days (today included,
    /// future-dated entries ignored), in the order given, at most `limit`.
    public static func summaryLines(_ movements: [Movement], today: String, windowDays: Int = 90,
                                    limit: Int = 8) -> [String] {
        guard limit > 0, let t = dayNumber(today) else { return [] }
        var lines: [String] = []
        for m in movements {
            let inWindow = m.entries.contains { e in
                guard let n = dayNumber(e.day) else { return false }
                return n <= t && t - n <= windowDays
            }
            guard inWindow else { continue }
            var line = "\(m.displayName): best \(kgText(m.bestWeightKg)) kg on \(m.bestDay)"
            if let r = m.best1RM { line += " (est. 1RM \(Int(r.rounded())) kg)" }
            line += ", latest \(kgText(m.latestWeightKg)) kg on \(m.latestDay)"
            lines.append(line)
            if lines.count >= limit { break }
        }
        return lines
    }

    /// kg with at most one decimal, "." separator, no trailing ".0".
    static func kgText(_ v: Double) -> String {
        let tenths = Int((abs(v) * 10).rounded())
        let sign = v < 0 && tenths != 0 ? "-" : ""
        return tenths % 10 == 0 ? "\(sign)\(tenths / 10)" : "\(sign)\(tenths / 10).\(tenths % 10)"
    }
}
