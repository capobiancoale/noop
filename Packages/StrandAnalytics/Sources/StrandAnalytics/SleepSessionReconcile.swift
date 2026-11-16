import Foundation
import WhoopStore

/// Which banked (computed) sleep sessions a re-scoring pass should delete because no pass detects them any
/// more. Sleep sessions are upserted by start time and, unlike daily rows and detected workouts, never
/// delete-reinserted, so a session banked once stayed for good. A pass that runs while the data stops in
/// the middle of a still stretch can see a "sleep" there (an hour of sitting still after waking, cut off by
/// the sync); later passes with the rest of the data drop it, but the banked row kept joining the night and
/// moved its wake time.
public enum SleepSessionReconcile {

    /// The stored sessions to delete: not hand-edited, not already dropped by the overlap heal, waking on a
    /// day this pass re-scored, and overlapping nothing the pass detected. A stored row that overlaps a fresh
    /// detection is the overlap heal's case (a drifted twin), not this one; an edited night is the user's.
    public static func undetected(stored: [CachedSleepSession], fresh: [CachedSleepSession],
                                  scoredDays: Set<String>, alreadyDropped: Set<Int>,
                                  offsetSec: Int) -> [CachedSleepSession] {
        stored.filter { s in
            !s.userEdited && !alreadyDropped.contains(s.startTs)
                && scoredDays.contains(AnalyticsEngine.dayString(s.endTs, offsetSec: offsetSec))
                && !fresh.contains { $0.startTs < s.endTs && s.startTs < $0.endTs }
        }
    }
}
