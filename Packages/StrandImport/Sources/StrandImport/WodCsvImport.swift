import Foundation
import WhoopStore

// MARK: - WOD CSV import (spreadsheet → logged WODs)
//
// The file-based sibling of `WodTextImport`, mirroring the Lab Book markers CSV flow
// (`LabMarkerCsvImport`): a person who keeps their training in a spreadsheet exports a CSV and
// imports it in one go, instead of typing each WOD. It reuses the shared `CSVTable` (delimiter
// sniffing for `,`/`;`/tab, BOM + latin-1 tolerance) and the pure field parsers from `WodTextImport`
// (result / RX / rep-scheme / load / date), so text-paste and CSV agree on how a value is read.
//
// Shape: ONE ROW PER MOVEMENT, with the WOD-level columns repeated (or left blank and carried down).
// Rows are grouped into WODs by (date, name); within a group the first non-empty WOD-level cell wins
// and every row that names a movement adds one. Tolerant headers (English + Italian):
//
//   date | name | type | format | time_cap | rx | result | rpe | movement | reps | rx_kg | my_kg | notes
//
//   date      required to date/group a WOD (blank rows inherit the previous row's date + name, so a
//             multi-movement WOD only needs them on its first line). yyyy-MM-dd, dd/MM/yyyy, "today"/"oggi".
//   rx        "rx"/"scaled" (or sì/no); blank = unset, then inferred from my_kg vs rx_kg.
//   result    6:32 | 5+12 | 80 kg | 120 reps (kind inferred; format nudges a bare number).
//   reps      a count (21) or a scheme (21-15-9, 5x5) kept as written.
//   rx_kg     prescribed load; my_kg the load actually lifted.
//
// Pure & deterministic (no DB, no I/O). Malformed rows are skipped and counted, never fatal; byte and
// row caps bound a hostile file, exactly like `LabMarkerCsvImport`.

public enum WodCsvImport {

    /// A ready-to-paste template (header + example rows) — surfaced by the import UI so a spreadsheet
    /// can be started from the exact columns the parser reads.
    public static let template = """
    date,name,type,format,time_cap,rx,result,rpe,movement,reps,rx_kg,my_kg,notes
    2026-09-20,Fran,CrossFit,For Time,10,scaled,6:32,8,Thruster,21-15-9,43,30,felt strong
    2026-09-20,Fran,,,,,,,Pull-up,21-15-9,,,
    2026-09-18,Back Squat 5x5,Weightlifting,Strength,,rx,100 kg,7,Back Squat,5x5,100,100,
    """

    /// Byte cap — a training-log CSV is a few KB; 8 MB is already absurd.
    public static let maxBytes = 8 << 20
    /// Row cap — bounds a hostile file without ever touching a real one.
    public static let maxRows = 20_000

    public struct Result: Sendable, Equatable {
        /// Parsed WODs, in first-seen order, ready to save.
        public var wods: [WodLogRow]
        /// Data rows dropped (fully blank, or a movement/WOD with no usable content). Reported, never fatal.
        public var skippedRows: Int
        /// True when the row cap stopped the parse early.
        public var truncated: Bool
        /// True when the file was rejected for exceeding the byte cap.
        public var fileTooLarge: Bool
        public var earliestDay: String?
        public var latestDay: String?

        public init(wods: [WodLogRow], skippedRows: Int, truncated: Bool, fileTooLarge: Bool,
                    earliestDay: String?, latestDay: String?) {
            self.wods = wods; self.skippedRows = skippedRows
            self.truncated = truncated; self.fileTooLarge = fileTooLarge
            self.earliestDay = earliestDay; self.latestDay = latestDay
        }
        public var importedWods: Int { wods.count }
        public var totalMovements: Int { wods.reduce(0) { $0 + $1.movements.count } }
    }

    public static func parse(data: Data, now: Date = Date(), calendar: Calendar = .current) -> Result {
        guard data.count <= maxBytes else {
            return Result(wods: [], skippedRows: 0, truncated: false, fileTooLarge: true,
                          earliestDay: nil, latestDay: nil)
        }
        return parseTable(CSVTable(data: data), maxRows: maxRows, now: now, calendar: calendar)
    }

    public static func parse(text: String, now: Date = Date(), calendar: Calendar = .current) -> Result {
        parseTable(CSVTable(text: text), maxRows: maxRows, now: now, calendar: calendar)
    }

    // MARK: - Core (row cap injectable for tests)

    /// One WOD under construction. WOD-level fields are `nil` until the first row supplies them
    /// (first-non-empty wins); movements accumulate across the group's rows.
    private struct Builder {
        var title = ""
        var type: String?
        var format: String?
        var timeCapS: Int?
        var rx: Bool?
        var rpe: Double?
        var resultRaw: String?
        var notes: [String] = []
        var movements: [WodMovement] = []
        var day = ""
        var ts = 0
        var createdTs = 0
    }

    static func parseTable(_ table: CSVTable, maxRows: Int, now: Date, calendar: Calendar) -> Result {
        let h = table.normalizedHeaders
        let dateCol = resolve(h, ["date", "day", "data", "giorno"], ["date", "data"])
        let nameCol = resolve(h, ["name", "wod", "title", "nome", "titolo", "workout", "allenamento"],
                              ["wod", "name", "nome", "titolo"], ["movement", "movimento"])
        let typeCol = resolve(h, ["type", "tipo"], ["type", "tipo"])
        let formatCol = resolve(h, ["format", "formato"], ["format", "formato"])
        let capCol = resolve(h, ["time_cap", "timecap", "cap", "tempo_limite", "tempo_massimo"], ["cap"])
        let rxCol = resolve(h, ["rx", "rx_scaled", "scaled", "prescritto"], ["scaled"], ["kg"])
        let resultCol = resolve(h, ["result", "risultato", "score", "punteggio"], ["result", "risultato", "score"])
        let rpeCol = resolve(h, ["rpe"], ["rpe"])
        let movementCol = resolve(h, ["movement", "movimento", "exercise", "esercizio", "move"],
                                  ["movement", "movimento", "exercise", "esercizio"])
        let repsCol = resolve(h, ["reps", "scheme", "ripetizioni", "schema"],
                              ["reps", "scheme", "ripet", "schema"])
        let rxKgCol = resolve(h, ["rx_kg", "rx_weight", "prescribed_kg", "peso_rx", "rx_load"],
                              ["rx_kg", "rx_weight", "prescribed"])
        let myKgCol = resolve(h, ["my_kg", "kg", "weight", "peso", "load", "carico", "mio_kg", "peso_mio"],
                              ["my_kg", "weight", "peso", "load", "carico"], ["rx"])
        let notesCol = resolve(h, ["notes", "note", "comment", "commento", "commenti"], ["note", "comment"])

        var order: [String] = []
        var byKey: [String: Builder] = [:]
        var skipped = 0
        var truncated = false
        var lastDay = ""     // carried down when a row leaves date/name blank (multi-movement WODs)
        var lastName = ""

        for (i, row) in table.rows.enumerated() {
            if i >= maxRows { skipped += table.rows.count - maxRows; truncated = true; break }

            let rawDate = dateCol.flatMap { row.cell($0) }
            let rawName = nameCol.flatMap { row.cell($0) }
            if let d = rawDate { lastDay = d }
            if let n = rawName { lastName = n }
            let movement = movementCol.flatMap { row.cell($0) }

            // A row with no date/name of its own AND no carried context AND no movement is blank filler.
            if rawDate == nil && rawName == nil && movement == nil && lastDay.isEmpty && lastName.isEmpty {
                skipped += 1
                continue
            }

            let date = lastDay.isEmpty ? now : (WodTextImport.parseDate(lastDay, calendar: calendar) ?? now)
            let dayStr = WodTextImport.dayKey(date, calendar: calendar)
            let key = dayStr + "\u{1}" + lastName.lowercased()

            if byKey[key] == nil {
                var b = Builder()
                b.day = dayStr
                b.ts = Int(date.timeIntervalSince1970)
                b.createdTs = Int(now.timeIntervalSince1970)
                b.title = lastName
                byKey[key] = b
                order.append(key)
            }
            var b = byKey[key]!

            // WOD-level fields: first non-empty across the group wins.
            if b.type == nil { b.type = typeCol.flatMap { row.cell($0) } }
            if b.format == nil { b.format = formatCol.flatMap { row.cell($0) } }
            if b.timeCapS == nil, let c = capCol.flatMap({ row.cell($0) }),
               let m = WodTextImport.firstDouble(c) { b.timeCapS = Int(m * 60) }
            if b.rx == nil, let rc = rxCol.flatMap({ row.cell($0) }) {
                b.rx = WodTextImport.parseRx(label: "rx", value: rc)
            }
            if b.resultRaw == nil { b.resultRaw = resultCol.flatMap { row.cell($0) } }
            if b.rpe == nil { b.rpe = rpeCol.flatMap { row.cell($0) }.flatMap { WodTextImport.firstDouble($0) } }
            if let n = notesCol.flatMap({ row.cell($0) }) { b.notes.append(n) }

            // Movement (if this row names one).
            if let mv = movement {
                let (reps, scheme) = WodTextImport.parseReps(repsCol.flatMap { row.cell($0) } ?? "")
                let my = myKgCol.flatMap { row.cell($0) }.flatMap { WodTextImport.firstDouble($0) }
                let rxk = rxKgCol.flatMap { row.cell($0) }.flatMap { WodTextImport.firstDouble($0) }
                b.movements.append(WodMovement(name: mv, reps: reps, scheme: scheme,
                                               weightKg: my, rxWeightKg: rxk))
            }
            byKey[key] = b
        }

        var wods: [WodLogRow] = []
        for key in order {
            guard let b = byKey[key] else { continue }
            var title = b.title
            if title.isEmpty { title = b.movements.first?.name ?? "" }
            guard !title.isEmpty || !b.movements.isEmpty else { skipped += 1; continue }
            if title.isEmpty { title = "WOD" }

            var rx = b.rx
            if rx == nil {
                let withBoth = b.movements.filter { $0.weightKg != nil && $0.rxWeightKg != nil }
                if !withBoth.isEmpty {
                    rx = withBoth.allSatisfy { ($0.weightKg ?? 0) >= ($0.rxWeightKg ?? 0) }
                }
            }

            let (kind, sec, rounds, reps, weight) = WodTextImport.parseResult(b.resultRaw, format: b.format)
            wods.append(WodLogRow(
                id: UUID().uuidString,
                ts: b.ts,
                day: b.day,
                type: b.type ?? "CrossFit",
                title: title,
                format: b.format,
                timeCapS: b.timeCapS,
                resultKind: kind,
                resultSeconds: sec,
                resultRounds: rounds,
                resultReps: reps,
                resultWeightKg: weight,
                rpe: (b.rpe ?? 0) > 0 ? b.rpe : nil,
                rx: rx,
                notes: b.notes.isEmpty ? nil : b.notes.joined(separator: "\n"),
                movements: b.movements,
                createdTs: b.createdTs))
        }

        let days = wods.map(\.day)
        return Result(wods: wods, skippedRows: skipped, truncated: truncated, fileTooLarge: false,
                      earliestDay: days.min(), latestDay: days.max())
    }

    /// Pick the normalized column feeding a field: an exact header match first, then a substring match
    /// (skipping any header that also matches an `excluding` term). Mirrors the Lab/Nutrition idiom.
    private static func resolve(_ headers: [String], _ exact: [String], _ contains: [String],
                                _ excluding: [String] = []) -> String? {
        for e in exact where headers.contains(e) { return e }
        for h in headers {
            if excluding.contains(where: { h.contains($0) }) { continue }
            if contains.contains(where: { h.contains($0) }) { return h }
        }
        return nil
    }
}
