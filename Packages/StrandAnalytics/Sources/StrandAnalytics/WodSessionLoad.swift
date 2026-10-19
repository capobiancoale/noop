import Foundation
import WhoopStore

extension StrainScorer.LoggedSession {
    /// The session-RPE session behind a logged WOD: its RPE over the duration it was rated for. When the user
    /// timed the whole session (start and end), that is the session: Foster's session-RPE rates the whole
    /// training session and multiplies by its full duration, warm-up and skill work included (Foster 2001),
    /// and its heart rate is read over exactly that span. Otherwise the result time, else the time cap. nil
    /// without an RPE or a duration. Imports that know only the date anchor a WOD to local noon, so one at
    /// exactly 12:00:00 local time is treated as time-unknown.
    public init?(wod: WodLogRow, tzOffsetSeconds: Int) {
        guard let rpe = wod.rpe, rpe > 0 else { return nil }
        if let span = wod.sessionSpan {
            self.init(rpe: min(rpe, 10), durationMin: Double(span.end - span.start) / 60, ts: span.start,
                      timeKnown: true, end: span.end)
            return
        }
        guard let secs = wod.resultSeconds ?? wod.timeCapS, secs > 0 else { return nil }
        let localSecond = ((wod.ts + tzOffsetSeconds) % 86_400 + 86_400) % 86_400
        self.init(rpe: min(rpe, 10), durationMin: Double(secs) / 60, ts: wod.ts, timeKnown: localSecond != 43_200)
    }
}
