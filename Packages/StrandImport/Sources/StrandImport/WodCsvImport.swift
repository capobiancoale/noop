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
// Shape: ONE ROW PER MOVEMENT / EXERCISE, with the WOD-level columns repeated (or left blank and
// carried down). Rows group into entries by (date, name) — or (date, exercise) when there is no name
// column, so a per-exercise maxes/lift log gets one entry per exercise. First non-empty WOD-level cell
// wins; every row that names a movement adds one. Tolerant headers (English + Italian):
//
//   date | name | exercise/movement | reps | reps_done | rx_kg | my_kg | time_cap | actual_time
//        | type | format | rx | result | rpe | notes
//
//   date         dates/groups the entry (blank rows inherit the previous row's date + name/exercise).
//                yyyy-MM-dd, dd/MM/yyyy, "today"/"oggi".
//   exercise     the lift/movement (esercizio); also the entry's name when no `name` column is present.
//   reps         PRESCRIBED count (5) or scheme (21-15-9, 5x5), kept as written.
//   reps_done    reps ACTUALLY completed (ripetizioni fatte).
//   rx_kg        prescribed (RX) load; my_kg the load actually lifted (peso usato).
//   time_cap     minutes; actual_time the real finish time (tempo reale), e.g. 6:32 → the result.
//   rx           "rx"/"scaled" (or sì/no); blank = unset, then inferred from my_kg vs rx_kg.
//   result       6:32 | 5+12 | 80 kg | 120 reps (kind inferred). With no result/actual_time but a
//                logged load, the entry's result becomes that weight — so a maxes log feeds "Bests".
//
// Pure & deterministic (no DB, no I/O). Malformed rows are skipped and counted, never fatal; byte and
// row caps bound a hostile file, exactly like `LabMarkerCsvImport`.

public enum WodCsvImport {

    /// A ready-to-paste template (header + example rows) — surfaced by the import UI so a spreadsheet
    /// can be started from the exact columns the parser reads.
    public static let template = """
    date,exercise,reps,rx_kg,my_kg,reps_done,time_cap,actual_time
    2026-09-18,Back Squat,5,140,140,5,,
    2026-09-18,Deadlift,3,180,175,3,,
    2026-09-20,Thruster,21-15-9,43,30,,10,6:32
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
        let actualTimeCol = resolve(h, ["actual_time", "tempo_reale", "finish_time", "real_time", "tempo_finale"],
                                    ["actual_time", "tempo_reale", "finish_time"])
        let rxCol = resolve(h, ["rx", "rx_scaled", "scaled", "prescritto"], ["scaled"], ["kg"])
        let resultCol = resolve(h, ["result", "risultato", "score", "punteggio"], ["result", "risultato", "score"])
        let rpeCol = resolve(h, ["rpe"], ["rpe"])
        let movementCol = resolve(h, ["movement", "movimento", "exercise", "esercizio", "move"],
                                  ["movement", "movimento", "exercise", "esercizio"])
        let repsCol = resolve(h, ["reps", "scheme", "ripetizioni", "schema"],
                              ["reps", "scheme", "ripet", "schema"], ["done", "fatte", "completat"])
        let repsDoneCol = resolve(h, ["reps_done", "repsdone", "done", "reps_completed",
                                      "ripetizioni_fatte", "fatte", "completate", "ripetizioni_completate"],
                                  ["done", "fatte", "completat"])
        let rxKgCol = resolve(h, ["rx_kg", "rx_weight", "prescribed_kg", "peso_rx", "rx_load"],
                              ["rx_kg", "rx_weight", "prescribed"])
        let myKgCol = resolve(h, ["my_kg", "kg", "weight", "peso", "load", "carico", "mio_kg", "peso_mio"],
                              ["my_kg", "weight", "peso", "load", "carico"], ["rx"])
        let notesCol = resolve(h, ["notes", "note", "comment", "commento", "commenti"], ["note", "comment"])

        var order: [String] = []
        var byKey: [String: Builder] = [:]
        var skipped = 0
        var truncated = false
        var lastDate = now       // carried down when a row leaves the date blank
        var lastDayKey = ""
        var lastName = ""        // carried WITHIN a day (reset when the day changes)

        for (i, row) in table.rows.enumerated() {
            if i >= maxRows { skipped += table.rows.count - maxRows; truncated = true; break }

            let rawDate = dateCol.flatMap { row.cell($0) }
            let rawName = nameCol.flatMap { row.cell($0) }
            if let d = rawDate {
                let date = WodTextImport.parseDate(d, calendar: calendar) ?? now
                let dk = WodTextImport.dayKey(date, calendar: calendar)
                if dk != lastDayKey { lastName = "" }   // a new day starts a fresh name context
                lastDate = date; lastDayKey = dk
            }
            if let n = rawName { lastName = n }
            let movement = movementCol.flatMap { row.cell($0) }

            // The entry name: an explicit WOD name if present, else the exercise itself (so a
            // per-exercise maxes log gets one entry per exercise).
            let groupName = !lastName.isEmpty ? lastName : (movement ?? "")

            // A row with no name/exercise and no movement is blank filler.
            if groupName.isEmpty && movement == nil { skipped += 1; continue }

            let dayStr = lastDayKey.isEmpty ? WodTextImport.dayKey(now, calendar: calendar) : lastDayKey
            let key = dayStr + "\u{1}" + groupName.lowercased()

            if byKey[key] == nil {
                var b = Builder()
                b.day = dayStr
                b.ts = Int(lastDate.timeIntervalSince1970)
                b.createdTs = Int(now.timeIntervalSince1970)
                b.title = groupName
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
            // Result: an explicit result column, else the actual-time (tempo reale) column as a time.
            if b.resultRaw == nil {
                b.resultRaw = resultCol.flatMap { row.cell($0) } ?? actualTimeCol.flatMap { row.cell($0) }
            }
            if b.rpe == nil { b.rpe = rpeCol.flatMap { row.cell($0) }.flatMap { WodTextImport.firstDouble($0) } }
            if let n = notesCol.flatMap({ row.cell($0) }) { b.notes.append(n) }

            // Movement (if this row names one).
            if let mv = movement {
                let (reps, scheme) = WodTextImport.parseReps(repsCol.flatMap { row.cell($0) } ?? "")
                let done = repsDoneCol.flatMap { row.cell($0) }.flatMap { WodTextImport.firstDouble($0) }.map { Int($0) }
                let my = myKgCol.flatMap { row.cell($0) }.flatMap { WodTextImport.firstDouble($0) }
                let rxk = rxKgCol.flatMap { row.cell($0) }.flatMap { WodTextImport.firstDouble($0) }
                b.movements.append(WodMovement(name: mv, reps: reps, scheme: scheme, repsDone: done,
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

            let parsed = WodTextImport.parseResult(b.resultRaw, format: b.format)
            var kind = parsed.0
            var weight = parsed.4
            // No explicit result but a logged load → the heaviest load IS the result, so a per-exercise
            // maxes log surfaces in "Bests" (max weight per exercise over time).
            if kind == .none {
                let loads = b.movements.compactMap { $0.weightKg ?? $0.rxWeightKg }
                if let maxLoad = loads.max() { kind = .weight; weight = maxLoad }
            }
            wods.append(WodLogRow(
                id: UUID().uuidString,
                ts: b.ts,
                day: b.day,
                type: b.type ?? "CrossFit",
                title: title,
                format: b.format,
                timeCapS: b.timeCapS,
                resultKind: kind,
                resultSeconds: parsed.1,
                resultRounds: parsed.2,
                resultReps: parsed.3,
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
