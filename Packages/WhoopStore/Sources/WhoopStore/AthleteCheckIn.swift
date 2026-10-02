import Foundation
import GRDB

/// Optional subjective observations, not a validated questionnaire or a readiness score.
public enum AthleteCheckInField: String, CaseIterable, Codable, Sendable {
    case energy, muscleFatigue, stress, sleepQuality
    public var journalKey: String { "noop.checkin.v1." + rawValue }
    public func accepts(_ value: Int?) -> Bool { value == nil || (1...5).contains(value!) }
}

extension WhoopStore {
    /// Writes all four answers atomically into the existing native journal; other history is untouched.
    public func saveAthleteCheckIn(day: String, values: [AthleteCheckInField: Int],
                                   updatedAt: Date = Date()) async throws {
        guard values.allSatisfy({ $0.key.accepts($0.value) }) else {
            throw CocoaError(.coderInvalidValue)
        }
        let stamp = ISO8601DateFormatter().string(from: updatedAt)
        try syncWrite { db in
            for field in AthleteCheckInField.allCases {
                if let value = values[field] {
                    try db.execute(sql: """
                        INSERT INTO journal (deviceId, day, question, answeredYes, notes, numericValue)
                        VALUES ('noop-journal', ?, ?, 1, ?, ?)
                        ON CONFLICT(deviceId, day, question) DO UPDATE SET
                        numericValue = excluded.numericValue, notes = excluded.notes, answeredYes = 1
                        """, arguments: [day, field.journalKey, stamp, value])
                } else {
                    try db.execute(sql: "DELETE FROM journal WHERE deviceId = 'noop-journal' AND day = ? AND question = ?",
                                   arguments: [day, field.journalKey])
                }
            }
        }
    }
}
