import Foundation
import GRDB

// MARK: - v23 store: WOD / strength log (user-authored)
//
// WodStore.swift — GRDB CRUD over the `wodLog` table (migration v23): the durable record behind the
// user's own logged CrossFit / strength workouts. Fully on-device and user-authored, so it is kept
// SEPARATE from the read-only `workout` rows imported from Apple Health / the strap. Mirrors the
// established store idiom: a plain Codable row struct, raw `Row` fetch + manual decode, idempotent
// upsert keyed by the row's UUID, all GRDB work via the actor's `syncWrite` / `syncRead` helpers.
//
// Movements are stored as a JSON array on the row (no child table): a WOD carries an arbitrary list of
// movements, each with optional reps / weight / notes, and the whole set is read and written together.

/// One movement inside a WOD (e.g. "Thruster", 21 reps, RX 43 kg, lifted 30 kg). All detail fields
/// optional so a quick log ("just the movement name") is valid and a detailed one carries the rep
/// scheme + both loads. `weightKg` is what the athlete actually lifted; `rxWeightKg` is the prescribed
/// (RX) load — kept apart so the log shows "30 kg (RX 43)" and scaling is visible per movement.
/// `scheme` holds a rep scheme as written ("21-15-9", "5x5") that a single `reps` count can't; when a
/// movement is a plain count, `reps` is used instead. Adding these optional fields is backward
/// compatible: rows written before v24 decode with the new fields nil.
public struct WodMovement: Equatable, Codable, Sendable {
    public var name: String
    public var sets: Int?
    public var reps: Int?
    public var scheme: String?
    /// Reps ACTUALLY completed (distinct from the prescribed `reps`/`scheme`) — e.g. prescribed 5×5 but
    /// 4 done on the last set, or the total in an AMRAP. Optional; nil when not recorded.
    public var repsDone: Int?
    public var weightKg: Double?
    public var rxWeightKg: Double?
    public var notes: String?
    public init(name: String, reps: Int? = nil, scheme: String? = nil, repsDone: Int? = nil,
                weightKg: Double? = nil, rxWeightKg: Double? = nil, notes: String? = nil, sets: Int? = nil) {
        self.sets = sets
        self.name = name; self.reps = reps; self.scheme = scheme; self.repsDone = repsDone
        self.weightKg = weightKg; self.rxWeightKg = rxWeightKg; self.notes = notes
    }
}

/// How a WOD's result is scored. `none` = logged without a numeric result (just the movements/notes).
public enum WodResultKind: String, Equatable, Codable, Sendable, CaseIterable {
    case time        // For Time — a finish time in seconds
    case roundsReps  // AMRAP — completed rounds + extra reps
    case reps        // total reps
    case weight      // a load (e.g. a 1-rep-max / heaviest set)
    case none
}

/// One user-logged WOD. Natural key is `id` (a client UUID string). `ts` is when it was performed;
/// `day` is its local civil day (`yyyy-MM-dd`) for grouping. `resultKind` selects which of the
/// `result*` fields is meaningful. `movements` is persisted as a JSON array in `movementsJSON`.
public struct WodLogRow: Equatable, Codable, Sendable, Identifiable {
    public var id: String
    public var ts: Int
    public var day: String
    public var type: String
    public var title: String
    public var format: String?
    public var timeCapS: Int?
    public var resultKind: WodResultKind
    public var resultSeconds: Int?
    public var resultRounds: Int?
    public var resultReps: Int?
    public var resultWeightKg: Double?
    public var rpe: Double?
    /// Whether the WOD was done as prescribed (RX) or scaled. nil = unset (bodyweight WODs, or not
    /// recorded). Per-movement loads carry the finer detail; this is the headline flag.
    public var rx: Bool?
    public var notes: String?
    public var movements: [WodMovement]
    public var durationS: Int?
    public var benchmarkVersion: String?
    public var scaling: String?
    public var createdTs: Int

    public init(id: String, ts: Int, day: String, type: String, title: String,
                format: String? = nil, timeCapS: Int? = nil, resultKind: WodResultKind = .none,
                resultSeconds: Int? = nil, resultRounds: Int? = nil, resultReps: Int? = nil,
                resultWeightKg: Double? = nil, rpe: Double? = nil, rx: Bool? = nil, notes: String? = nil,
                movements: [WodMovement] = [], createdTs: Int,
                durationS: Int? = nil, benchmarkVersion: String? = nil, scaling: String? = nil) {
        self.durationS = durationS; self.benchmarkVersion = benchmarkVersion; self.scaling = scaling
        self.id = id; self.ts = ts; self.day = day; self.type = type; self.title = title
        self.format = format; self.timeCapS = timeCapS; self.resultKind = resultKind
        self.resultSeconds = resultSeconds; self.resultRounds = resultRounds; self.resultReps = resultReps
        self.resultWeightKg = resultWeightKg; self.rpe = rpe; self.rx = rx; self.notes = notes
        self.movements = movements; self.createdTs = createdTs
    }
}

// MARK: - Movements JSON (shared by the store and testable on its own)

public enum WodMovementCodec {
    /// Encode movements to a compact JSON string for the `movementsJSON` column. Empty → "[]".
    public static func encode(_ movements: [WodMovement]) -> String {
        guard let data = try? JSONEncoder().encode(movements),
              let s = String(data: data, encoding: .utf8) else { return "[]" }
        return s
    }
    /// Decode movements from the stored JSON string. Nil/blank/garbage → [] (never a throw), so a bad
    /// row degrades to "no movements" rather than dropping the whole WOD.
    public static func decode(_ json: String?) -> [WodMovement] {
        guard let json, let data = json.data(using: .utf8),
              let m = try? JSONDecoder().decode([WodMovement].self, from: data) else { return [] }
        return m
    }
}

extension WhoopStore {

    /// Insert or replace one WOD (keyed by `id`). Idempotent — used for both create and edit.
    @discardableResult
    public func upsertWod(_ r: WodLogRow) async throws -> Int {
        let movementsJSON = WodMovementCodec.encode(r.movements)
        return try syncWrite { db in
            try db.execute(sql: """
                INSERT INTO wodLog
                    (id, ts, day, type, title, format, timeCapS, resultKind, resultSeconds, resultRounds,
                     resultReps, resultWeightKg, rpe, rx, notes, movementsJSON, createdTs, durationS, benchmarkVersion, scaling)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    ts = excluded.ts, day = excluded.day, type = excluded.type, title = excluded.title,
                    format = excluded.format, timeCapS = excluded.timeCapS, resultKind = excluded.resultKind,
                    resultSeconds = excluded.resultSeconds, resultRounds = excluded.resultRounds,
                    resultReps = excluded.resultReps, resultWeightKg = excluded.resultWeightKg,
                    rpe = excluded.rpe, rx = excluded.rx, notes = excluded.notes,
                    movementsJSON = excluded.movementsJSON,
                    durationS = excluded.durationS, benchmarkVersion = excluded.benchmarkVersion,
                    scaling = excluded.scaling
                """, arguments: [r.id, r.ts, r.day, r.type, r.title, r.format, r.timeCapS,
                                 r.resultKind.rawValue, r.resultSeconds, r.resultRounds, r.resultReps,
                                 r.resultWeightKg, r.rpe, r.rx, r.notes, movementsJSON, r.createdTs, r.durationS, r.benchmarkVersion, r.scaling])
            return db.changesCount
        }
    }

    /// All logged WODs, newest first. `limit` caps the fetch.
    public func allWods(limit: Int = 1000) async throws -> [WodLogRow] {
        try syncRead { db in
            try Row.fetchAll(db, sql: "SELECT * FROM wodLog ORDER BY ts DESC LIMIT ?", arguments: [limit])
                .map(Self.decodeWod)
        }
    }

    /// Every attempt at one WOD title (case-insensitive), newest first — the progress history.
    public func wods(title: String, limit: Int = 500) async throws -> [WodLogRow] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM wodLog WHERE title = ? COLLATE NOCASE ORDER BY ts DESC LIMIT ?
                """, arguments: [title, limit])
                .map(Self.decodeWod)
        }
    }

    /// Delete one WOD by id. Returns rows removed.
    @discardableResult
    public func deleteWod(id: String) async throws -> Int {
        try syncWrite { db in
            try db.execute(sql: "DELETE FROM wodLog WHERE id = ?", arguments: [id])
            return db.changesCount
        }
    }

    /// Decode a `wodLog` row into a `WodLogRow`. Kept in one place so every fetch above maps identically.
    private static func decodeWod(_ row: Row) -> WodLogRow {
        WodLogRow(
            id: row["id"], ts: row["ts"], day: row["day"], type: row["type"], title: row["title"],
            format: row["format"], timeCapS: row["timeCapS"],
            resultKind: WodResultKind(rawValue: row["resultKind"] ?? "none") ?? .none,
            resultSeconds: row["resultSeconds"], resultRounds: row["resultRounds"],
            resultReps: row["resultReps"], resultWeightKg: row["resultWeightKg"],
            rpe: row["rpe"], rx: row["rx"], notes: row["notes"],
            movements: WodMovementCodec.decode(row["movementsJSON"]),
            createdTs: row["createdTs"], durationS: row["durationS"],
            benchmarkVersion: row["benchmarkVersion"], scaling: row["scaling"])
    }
}

extension WodLogRow {
    /// Exact protocol identity. Missing version/scaling stays unclassified, never silently comparable.
    public func isComparable(to other: WodLogRow) -> Bool {
        func norm(_ s: String?) -> String { (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        guard !norm(benchmarkVersion).isEmpty, !norm(scaling).isEmpty,
              !movements.isEmpty, rx != nil else { return false }
        return norm(title) == norm(other.title) && type == other.type && format == other.format
            && resultKind == other.resultKind && timeCapS == other.timeCapS
            && norm(benchmarkVersion) == norm(other.benchmarkVersion)
            && norm(scaling) == norm(other.scaling) && rx == other.rx
            && movements.count == other.movements.count
            && zip(movements, other.movements).allSatisfy { a, b in
                norm(a.name) == norm(b.name) && a.reps == b.reps && a.scheme == b.scheme
                    && a.sets == b.sets && a.weightKg == b.weightKg && a.rxWeightKg == b.rxWeightKg
                    && a.notes == b.notes
            }
    }

    /// Recorded external volume only, never an estimate of muscular fatigue.
    public var recordedVolumeKg: Double? {
        let terms = movements.compactMap { m -> Double? in
            guard let kg = m.weightKg, kg.isFinite, kg >= 0,
                  let reps = m.repsDone, reps >= 0 else { return nil }
            return kg * Double(reps)
        }
        return terms.isEmpty ? nil : terms.reduce(0, +)
    }
}
