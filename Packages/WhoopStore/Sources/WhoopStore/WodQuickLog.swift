import Foundation

// WodQuickLog.swift — pure helpers behind "log a WOD in ten seconds": parsing a typed result ("4:32",
// "12+5", "150", "100 kg"), the latest earlier use of a movement ("Last time: 5x5 @ 90 kg"), and building the
// row the Siri / Shortcuts "Log a WOD" intent saves. No clock, no UserDefaults, no store access: everything
// comes in as a parameter. Never guesses: text that is not one of the four shapes gives no result.

/// A result read from text. Exactly the fields `WodLogRow` carries for the matching `kind`.
public struct WodQuickResult: Equatable, Sendable {
    public var kind: WodResultKind
    public var seconds: Int?
    public var rounds: Int?
    public var reps: Int?
    public var weightKg: Double?
    public init(kind: WodResultKind, seconds: Int? = nil, rounds: Int? = nil, reps: Int? = nil,
                weightKg: Double? = nil) {
        self.kind = kind; self.seconds = seconds; self.rounds = rounds; self.reps = reps
        self.weightKg = weightKg
    }
}

public enum WodResultParser {
    /// Largest value read as a result, so a pasted phone number or a typo never becomes a record.
    static let maxWhole = 99_999

    /// `m:ss` -> time (seconds under 60), `R+r` -> rounds and reps, `N kg` (comma or dot decimal, space
    /// optional) -> weight, a plain whole number -> reps. Anything else, a zero result, or an out-of-range
    /// number -> nil.
    public static func parse(_ raw: String?) -> WodQuickResult? {
        guard let raw else { return nil }
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }

        // Weight: "<number> kg"
        let lower = t.lowercased()
        if lower.hasSuffix("kg") {
            let body = String(lower.dropLast(2)).trimmingCharacters(in: .whitespaces)
            guard let kg = decimal(body), kg > 0, kg <= 1_000 else { return nil }
            return WodQuickResult(kind: .weight, weightKg: kg)
        }

        // Time: "m:ss"
        if t.contains(":") {
            let parts = t.split(separator: ":", omittingEmptySubsequences: false).map {
                String($0).trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2, let m = whole(parts[0]), let s = whole(parts[1]), s < 60 else { return nil }
            let total = m * 60 + s
            guard total > 0 else { return nil }
            return WodQuickResult(kind: .time, seconds: total)
        }

        // Rounds + reps: "R+r"
        if t.contains("+") {
            let parts = t.split(separator: "+", omittingEmptySubsequences: false).map {
                String($0).trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2, let r = whole(parts[0]), let e = whole(parts[1]), r > 0 || e > 0 else { return nil }
            return WodQuickResult(kind: .roundsReps, rounds: r, reps: e)
        }

        // Reps: a plain whole number
        if let n = whole(t), n > 0 { return WodQuickResult(kind: .reps, reps: n) }
        return nil
    }

    /// Digits only (no sign, no separator), within `maxWhole`.
    private static func whole(_ s: String) -> Int? {
        guard !s.isEmpty, s.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(s), n <= maxWhole else { return nil }
        return n
    }

    /// "62.5" or "62,5" (one separator, digits around it).
    private static func decimal(_ s: String) -> Double? {
        let t = s.replacingOccurrences(of: ",", with: ".")
        guard !t.isEmpty, t.filter({ $0 == "." }).count <= 1,
              t.allSatisfy({ ($0.isASCII && $0.isNumber) || $0 == "." }),
              t.first != ".", t.last != "." else { return nil }
        return Double(t)
    }
}

public enum WodMovementHistory {
    /// A movement name for matching: trimmed, lowercased, diacritics and repeated spaces folded away.
    public static func normalisedName(_ name: String) -> String {
        let folded = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return folded.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
    }

    public struct Entry: Equatable, Sendable {
        public let movement: WodMovement
        /// The logged time (unix seconds) of the WOD the movement was found in.
        public let ts: Int
    }

    /// The movement of the most recent WOD (highest `ts`) in `wods` that has one with this normalised name and
    /// something to show (a rep count / scheme or a load). `excluding` skips the WOD being edited.
    public static func latest(named name: String, in wods: [WodLogRow], excluding id: String? = nil) -> Entry? {
        let key = normalisedName(name)
        guard !key.isEmpty else { return nil }
        for w in wods.sorted(by: { $0.ts > $1.ts }) where w.id != id {
            for m in w.movements where normalisedName(m.name) == key {
                let hasScheme = !(m.scheme ?? "").isEmpty || m.reps != nil
                if hasScheme || m.weightKg != nil { return Entry(movement: m, ts: w.ts) }
            }
        }
        return nil
    }
}

public enum WodQuickLog {
    /// A copy of `source` for a new attempt: the same title, type, format, time cap and movements with their
    /// schemes and loads; result, RPE, notes, RX flag and reps done are blank.
    public static func repeatMovements(of source: WodLogRow) -> [WodMovement] {
        source.movements.map {
            var m = $0
            m.repsDone = nil
            m.notes = nil
            return m
        }
    }

    /// The row the "Log a WOD" intent saves. When `title` matches (trimmed, case-insensitive) an earlier WOD in
    /// `history`, the newest such WOD's type, format and movements are copied; otherwise type "CrossFit" and no
    /// format or movements. `scaled` sets `rx = false`; unscaled leaves it unset (nothing says it was RX).
    /// `dayKey` is the local civil day of `now`, supplied by the caller (no calendar here).
    public static func makeRow(title: String, resultText: String?, rpe: Int?, scaled: Bool,
                               history: [WodLogRow], id: String, now: Int, dayKey: String) -> WodLogRow {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = WodRanking.titleKey(name)
        let previous = history.filter { WodRanking.titleKey($0.title) == key }.max { $0.ts < $1.ts }
        let result = WodResultParser.parse(resultText)
        let rpeValue: Double? = rpe.flatMap { (1...10).contains($0) ? Double($0) : nil }
        return WodLogRow(
            id: id, ts: now, day: dayKey,
            type: previous?.type ?? "CrossFit",
            title: name,
            format: previous?.format,
            timeCapS: previous?.timeCapS,
            resultKind: result?.kind ?? .none,
            resultSeconds: result?.seconds,
            resultRounds: result?.rounds,
            resultReps: result?.reps,
            resultWeightKg: result?.weightKg,
            rpe: rpeValue,
            rx: scaled ? false : nil,
            notes: nil,
            movements: previous.map(repeatMovements(of:)) ?? [],
            createdTs: now,
            endTs: nil)
    }
}
