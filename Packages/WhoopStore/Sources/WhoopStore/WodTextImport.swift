import Foundation

// MARK: - WOD text import (paste → structured WODs)
//
// A pure, dependency-free parser that turns a pasted block of text into ready-to-save `WodLogRow`s.
// The intended workflow: the athlete gets the WOD as a PHOTO, hands the photo to any capable vision
// AI with the prompt in `aiPrompt`, and the AI returns text in the lenient labelled format below;
// they paste it into NOOP and it becomes one (or several) logged WODs — no field-by-field typing.
//
// The format is deliberately forgiving so a human OR an AI can produce it. One WOD per block; blocks
// are separated by a rule line (`---`, `===`, …). Within a block, `Label: value` lines set the WOD
// fields (labels are case-insensitive and accept English + Italian synonyms), and bullet lines
// (`-`, `•`, `*`) are movements. Everything is optional; a block with at least a title or one movement
// becomes a WOD, anything unrecognised is ignored (or folded into notes), so a messy paste degrades
// gracefully instead of failing.
//
// Movement line grammar (segments split on `;` or `|`; keywords case-insensitive, EN+IT):
//     - <name>; reps <scheme>; rx <load>; me <load>
//   e.g.  "- Thruster; reps 21-15-9; rx 43; me 30"
//         "- Pull-up; 21-15-9"                         (bare scheme)
//         "- Back Squat; 5x5; rx 100; io 90"
//   A bare load with no keyword is read as the PRESCRIBED (RX) load — a WOD photo shows the
//   prescription; the athlete's own load is the one tagged `me`/`io`/`mio`.
//
// Kept pure (no GRDB, no UIKit) so it lives beside the model and is unit-tested on its own.

public enum WodTextImport {

    /// The copy-paste instruction to hand another AI together with the WOD photo. Kept here so the UI
    /// and any docs share one source of truth.
    public static let aiPrompt = """
    Leggi la foto di questo allenamento (WOD) e restituisci SOLO testo in questo formato, senza \
    commenti. Un blocco per allenamento, separa più allenamenti con una riga "---".

    Data: AAAA-MM-GG
    Tipo: CrossFit
    Nome: <nome del WOD, es. Fran>
    Formato: For Time | AMRAP | EMOM | Strength | Intervals
    Time cap: <minuti>
    RX: rx | scaled
    Risultato: <es. 6:32  oppure  5+12  oppure  80 kg  oppure  120 reps>
    RPE: <1-10>
    Movimenti:
    - <nome>; reps <schema es. 21-15-9>; rx <peso prescritto in kg>; me <peso che ho usato in kg>
    - <nome>; reps <...>; rx <...>; me <...>
    Note: <opzionale>

    Regole: usa i kg. In "rx" metti il peso prescritto dal WOD; in "me" il peso che ho davvero usato \
    (se non lo sai, lascialo vuoto). Ometti le righe che non conosci.
    """

    /// Parse pasted text into zero or more WODs, ready to save. `now` and `calendar` are injected so
    /// the parser is deterministic and testable (a block without a date is stamped `now`).
    public static func parse(_ text: String, now: Date = Date(), calendar: Calendar = .current) -> [WodLogRow] {
        splitBlocks(text).compactMap { parseBlock($0, now: now, calendar: calendar) }
    }

    // MARK: Blocks

    /// Split the paste into per-WOD line groups on rule lines (`---`, `===`, `***`, `___`, 3+ chars).
    /// Blocks that are entirely blank are dropped.
    static func splitBlocks(_ text: String) -> [[String]] {
        var blocks: [[String]] = []
        var current: [String] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if isRule(trimmed) {
                if current.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                    blocks.append(current)
                }
                current = []
            } else {
                current.append(rawLine)
            }
        }
        if current.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            blocks.append(current)
        }
        return blocks
    }

    /// A separator rule: 3+ identical of `- – — = * _`.
    static func isRule(_ s: String) -> Bool {
        guard s.count >= 3 else { return false }
        let seps: Set<Character> = ["-", "–", "—", "=", "*", "_"]
        return s.allSatisfy { seps.contains($0) }
    }

    // MARK: One block → one WOD

    static func parseBlock(_ lines: [String], now: Date, calendar: Calendar) -> WodLogRow? {
        var title = ""
        var type = "CrossFit"
        var format: String? = nil
        var timeCapS: Int? = nil
        var rx: Bool? = nil
        var rpe: Double? = nil
        var notesParts: [String] = []
        var resultRaw: String? = nil
        var date: Date? = nil
        var movements: [WodMovement] = []
        var collectingNotes = false

        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            // Bullet → a movement (whatever section we're in).
            if let bullet = stripBullet(line) {
                if let m = parseMovement(bullet) { movements.append(m) }
                collectingNotes = false
                continue
            }

            // Label: value
            if let (label, value) = splitLabel(line) {
                collectingNotes = false
                switch label {
                case "name", "nome", "wod", "title", "titolo", "workout", "allenamento":
                    title = value
                case "type", "tipo":
                    if !value.isEmpty { type = value }
                case "format", "formato":
                    format = value.isEmpty ? nil : value
                case "date", "data", "day", "giorno":
                    date = parseDate(value, calendar: calendar)
                case "time cap", "timecap", "cap", "tempo limite", "tempo massimo":
                    if let mins = firstDouble(value) { timeCapS = Int(mins * 60) }
                case "rx", "rx/scaled", "scaled", "rx o scaled", "prescritto":
                    rx = parseRx(label: label, value: value)
                case "result", "risultato", "score", "punteggio", "tempo", "time":
                    resultRaw = value
                case "rpe", "sforzo percepito":
                    rpe = firstDouble(value)
                case "notes", "note", "commento", "commenti":
                    if !value.isEmpty { notesParts.append(value) }
                    collectingNotes = true
                case "movements", "movimenti", "esercizi":
                    // Inline movements after the colon (comma-separated) — else the bullets that follow.
                    if !value.isEmpty {
                        for part in value.components(separatedBy: ",") {
                            if let m = parseMovement(part) { movements.append(m) }
                        }
                    }
                default:
                    // Unknown label → treat the whole line as a note so nothing is silently lost.
                    notesParts.append(line)
                }
                continue
            }

            // A non-label, non-bullet line: continuation of notes, else a bare title if we have none.
            if collectingNotes {
                notesParts.append(line)
            } else if title.isEmpty && movements.isEmpty {
                title = line
            } else {
                notesParts.append(line)
            }
        }

        // A block is a WOD only if it carries a title or at least one movement.
        if title.isEmpty {
            title = movements.first?.name ?? ""
        }
        guard !title.isEmpty || !movements.isEmpty else { return nil }
        if title.isEmpty { title = "WOD" }

        // RX inference when not stated: any movement lifted below its prescribed load ⇒ scaled.
        if rx == nil {
            let withBoth = movements.filter { $0.weightKg != nil && $0.rxWeightKg != nil }
            if !withBoth.isEmpty {
                rx = withBoth.allSatisfy { ($0.weightKg ?? 0) >= ($0.rxWeightKg ?? 0) }
            }
        }

        let when = date ?? now
        let (kind, sec, rounds, reps, weight) = parseResult(resultRaw, format: format)
        let notes = notesParts.isEmpty ? nil : notesParts.joined(separator: "\n")

        return WodLogRow(
            id: UUID().uuidString,
            ts: Int(when.timeIntervalSince1970),
            day: dayKey(when, calendar: calendar),
            type: type,
            title: title,
            format: format,
            timeCapS: timeCapS,
            resultKind: kind,
            resultSeconds: sec,
            resultRounds: rounds,
            resultReps: reps,
            resultWeightKg: weight,
            rpe: (rpe ?? 0) > 0 ? rpe : nil,
            rx: rx,
            notes: notes,
            movements: movements,
            createdTs: Int(now.timeIntervalSince1970))
    }

    // MARK: Movements

    /// Parse one movement description (already stripped of its bullet).
    /// Returns nil when there is no usable name.
    static func parseMovement(_ text: String) -> WodMovement? {
        let segments = text.components(separatedBy: CharacterSet(charactersIn: ";|"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let first = segments.first else { return nil }

        var name = first
        var reps: Int? = nil
        var scheme: String? = nil
        var myLoad: Double? = nil
        var rxLoad: Double? = nil

        // If the name segment itself trails into a scheme/load with no separator (e.g. "Thruster 43kg"),
        // peel a trailing number off the name into the RX load.
        if segments.count == 1, let sep = trailingNumberSplit(first) {
            name = sep.head
            rxLoad = sep.value
        }

        for seg in segments.dropFirst() {
            let lower = seg.lowercased()
            if lower.hasPrefix("rx") || lower.hasPrefix("prescr") {
                rxLoad = firstDouble(seg) ?? rxLoad
            } else if lower.hasPrefix("me") || lower.hasPrefix("io") || lower.hasPrefix("mio") || lower.hasPrefix("mine") {
                myLoad = firstDouble(seg) ?? myLoad
            } else if lower.hasPrefix("reps") || lower.hasPrefix("rep") || lower.hasPrefix("ripet") || lower.hasPrefix("schema") || lower.hasPrefix("scheme") {
                let (r, s) = parseReps(stripLeadingWord(seg))
                reps = r; scheme = s
            } else if isSchemeToken(seg) {
                let (r, s) = parseReps(seg)
                reps = r ?? reps; scheme = s ?? scheme
            } else if let n = firstDouble(seg), seg.lowercased().contains("kg") || seg.lowercased().contains("lb") {
                // A bare load with a unit and no keyword → prescribed (RX).
                rxLoad = rxLoad ?? n
            }
        }

        name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        return WodMovement(name: name, reps: reps, scheme: scheme, weightKg: myLoad, rxWeightKg: rxLoad)
    }

    /// Split a "name … trailing-load-with-unit" string into (name, load), e.g. "Back Squat 100 kg" →
    /// ("Back Squat", 100). Requires an explicit kg/lb unit so a bare trailing number (which might be
    /// metres, calories or reps) is never silently read as a weight.
    static func trailingNumberSplit(_ s: String) -> (head: String, value: Double)? {
        let body = s.trimmingCharacters(in: .whitespaces)
        let lower = body.lowercased()
        let stripped: String
        if lower.hasSuffix("kg") { stripped = String(body.dropLast(2)) }
        else if lower.hasSuffix("lbs") { stripped = String(body.dropLast(3)) }
        else if lower.hasSuffix("lb") { stripped = String(body.dropLast(2)) }
        else { return nil }
        let trimmed = stripped.trimmingCharacters(in: .whitespaces)
        guard let spaceIdx = trimmed.lastIndex(of: " ") else { return nil }
        let tail = trimmed[trimmed.index(after: spaceIdx)...].replacingOccurrences(of: ",", with: ".")
        let head = String(trimmed[..<spaceIdx]).trimmingCharacters(in: .whitespaces)
        guard !head.isEmpty, let v = Double(tail) else { return nil }
        return (head, v)
    }

    /// A token that looks like a rep scheme: digits joined by - x × / or a plain count.
    static func isSchemeToken(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard let first = t.first, first.isNumber else { return false }
        let ok: Set<Character> = ["-", "x", "X", "×", "/", " "]
        return t.allSatisfy { $0.isNumber || ok.contains($0) }
    }

    /// A rep field → (single count, scheme). A plain integer is a count; anything else is a scheme.
    static func parseReps(_ raw: String) -> (Int?, String?) {
        let v = raw.trimmingCharacters(in: .whitespaces)
        if v.isEmpty { return (nil, nil) }
        if let n = Int(v) { return (n, nil) }
        return (nil, v)
    }

    // MARK: Result

    /// Parse a result string into (kind, seconds, rounds, reps, weightKg). Falls back to `.none`.
    static func parseResult(_ raw: String?, format: String?) -> (WodResultKind, Int?, Int?, Int?, Double?) {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            return (.none, nil, nil, nil, nil)
        }
        let lower = raw.lowercased()

        // mm:ss (or h:mm:ss) → time
        if raw.contains(":") {
            let parts = raw.split(separator: ":")
            let nums: [Int] = parts.compactMap { part in
                let digits = String(part.filter { $0.isNumber })
                return digits.isEmpty ? nil : Int(digits)
            }
            if nums.count == 2 { return (.time, nums[0] * 60 + nums[1], nil, nil, nil) }
            if nums.count == 3 { return (.time, nums[0] * 3600 + nums[1] * 60 + nums[2], nil, nil, nil) }
        }
        // rounds + reps
        if raw.contains("+") {
            let sides = raw.split(separator: "+", maxSplits: 1).map(String.init)
            let rounds = sides.first.flatMap { firstDouble($0) }.map { Int($0) }
            let reps = sides.count > 1 ? firstDouble(sides[1]).map { Int($0) } : nil
            if rounds != nil { return (.roundsReps, nil, rounds, reps, nil) }
        }
        // explicit load
        if lower.contains("kg") || lower.contains("lb") {
            if let w = firstDouble(raw) { return (.weight, nil, nil, nil, w) }
        }
        // explicit reps
        if lower.contains("rep") {
            if let r = firstDouble(raw) { return (.reps, nil, nil, Int(r), nil) }
        }
        // bare number → infer from format
        if let n = firstDouble(raw) {
            switch (format ?? "").lowercased() {
            case let f where f.contains("amrap"):        return (.roundsReps, nil, Int(n), nil, nil)
            case let f where f.contains("strength") || f.contains("weightlift") || f.contains("forza"):
                return (.weight, nil, nil, nil, n)
            case let f where f.contains("time") || f.contains("tempo"):
                // a bare number of minutes → treat as mm:00
                return (.time, Int(n) * 60, nil, nil, nil)
            default:
                return (.none, nil, nil, nil, nil)
            }
        }
        return (.none, nil, nil, nil, nil)
    }

    // MARK: Small helpers

    /// Strip a leading bullet (`- • *`) and return the remainder, or nil if the line isn't a bullet.
    static func stripBullet(_ line: String) -> String? {
        for b in ["- ", "• ", "* ", "-\t", "–  ", "– "] where line.hasPrefix(b) {
            return String(line.dropFirst(b.count)).trimmingCharacters(in: .whitespaces)
        }
        // a lone leading "-" with content e.g. "-Thruster"
        if line.hasPrefix("-") && line.count > 1 && line[line.index(after: line.startIndex)] != "-" {
            return String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        if line.hasPrefix("•") || line.hasPrefix("*") {
            return String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// Split "Label: value" → (lowercased trimmed label, trimmed value). nil if there's no colon in
    /// the first ~24 chars (so a "6:32" time value isn't mistaken for a label).
    static func splitLabel(_ line: String) -> (String, String)? {
        guard let idx = line.firstIndex(of: ":") else { return nil }
        let label = String(line[line.startIndex..<idx]).trimmingCharacters(in: .whitespaces)
        // a label is short and word-like (no digits at the start), guarding against "21-15-9: ..." etc.
        guard !label.isEmpty, label.count <= 24, let f = label.first, !f.isNumber else { return nil }
        let value = String(line[line.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
        return (label.lowercased(), value)
    }

    /// Drop the first whitespace-delimited word (used to strip a keyword like "reps" off its value).
    static func stripLeadingWord(_ s: String) -> String {
        let parts = s.split(separator: " ", maxSplits: 1)
        return parts.count > 1 ? String(parts[1]) : ""
    }

    /// Interpret an RX/Scaled value. When the label itself is "scaled", an empty value means scaled.
    static func parseRx(label: String, value: String) -> Bool? {
        let v = value.lowercased().trimmingCharacters(in: .whitespaces)
        if v.isEmpty { return label == "scaled" ? false : (label == "rx" ? true : nil) }
        if ["rx", "yes", "y", "sì", "si", "true", "1", "prescritto"].contains(v) { return true }
        if ["scaled", "scalato", "no", "n", "false", "0"].contains(v) { return false }
        // values like "rx+" (heavier than rx) still count as at least RX
        if v.hasPrefix("rx") { return true }
        if v.hasPrefix("scal") { return false }
        return nil
    }

    /// First numeric run in a string, comma or dot decimal, ignoring surrounding text/units.
    static func firstDouble(_ s: String) -> Double? {
        var num = ""
        var started = false
        for ch in s {
            if ch.isNumber { num.append(ch); started = true }
            else if (ch == "." || ch == ",") && started { num.append(".") }
            else if started { break }
        }
        while num.hasSuffix(".") { num.removeLast() }
        return num.isEmpty ? nil : Double(num)
    }

    /// Parse a date in the common shapes; nil if unrecognised.
    static func parseDate(_ s: String, calendar: Calendar) -> Date? {
        let v = s.trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty else { return nil }
        let low = v.lowercased()
        if low == "today" || low == "oggi" { return Date() }
        if low == "yesterday" || low == "ieri" {
            return calendar.date(byAdding: .day, value: -1, to: Date())
        }
        let formats = ["yyyy-MM-dd", "dd/MM/yyyy", "dd-MM-yyyy", "d/M/yyyy", "MM/dd/yyyy", "yyyy/MM/dd"]
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = calendar.timeZone
        for fmt in formats {
            f.dateFormat = fmt
            if let d = f.date(from: v) {
                // Anchor to local noon so the civil day is unambiguous across time zones.
                return calendar.date(bySettingHour: 12, minute: 0, second: 0, of: d) ?? d
            }
        }
        return nil
    }

    /// Canonical yyyy-MM-dd (local) day key, matching the store's day contract.
    static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = calendar.timeZone
        return f.string(from: date)
    }
}
