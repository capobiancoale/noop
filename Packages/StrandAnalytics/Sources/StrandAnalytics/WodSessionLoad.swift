import Foundation
import WhoopStore

extension StrainScorer.LoggedSession {
    /// The session-RPE session behind a logged WOD: its RPE over the duration it was rated for (the result
    /// time, else the time cap). nil without an RPE or a duration. Imports that know only the date anchor a
    /// WOD to local noon, so one at exactly 12:00:00 local time is treated as time-unknown.
    public init?(wod: WodLogRow, tzOffsetSeconds: Int) {
        guard let rpe = wod.rpe, rpe > 0, let secs = wod.resultSeconds ?? wod.timeCapS, secs > 0 else { return nil }
        let localSecond = ((wod.ts + tzOffsetSeconds) % 86_400 + 86_400) % 86_400
        self.init(rpe: min(rpe, 10), durationMin: Double(secs) / 60, ts: wod.ts, timeKnown: localSecond != 43_200)
    }
}
