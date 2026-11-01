import XCTest
@testable import StrandAnalytics
import WhoopStore

final class SleepSessionReconcileTests: XCTestCase {

    // 2026-11-01 00:00 local at UTC+1.
    private let midnight = 1_793_487_600
    private let offset = 3_600

    private func at(_ h: Int, _ m: Int) -> Int { midnight + h * 3_600 + m * 60 }

    private func session(_ start: Int, _ end: Int, edited: Bool = false) -> CachedSleepSession {
        CachedSleepSession(startTs: start, endTs: end, efficiency: 0.9, restingHr: 50, avgHrv: 60,
                           stagesJSON: nil, userEdited: edited)
    }

    /// The field case: the night 01:48-08:12 is re-detected, the 09:17-10:24 stretch banked by a 10:24 sync
    /// is not. Only the stretch goes.
    func testBankedStretchNoPassDetectsIsDeleted() {
        let night = session(at(1, 48), at(8, 12))
        let phantom = session(at(9, 17), at(10, 24))
        let gone = SleepSessionReconcile.undetected(stored: [night, phantom], fresh: [night],
                                                    scoredDays: ["2026-11-01"], alreadyDropped: [],
                                                    offsetSec: offset)
        XCTAssertEqual(gone, [phantom])
    }

    /// A stored night whose onset drifted (it overlaps the fresh detection) is the overlap heal's business,
    /// an edited night is never touched, a day this pass did not score is left alone, and a row the heal
    /// already dropped is not deleted twice.
    func testOverlapEditedUnscoredAndHealedRowsAreKept() {
        let fresh = session(at(1, 50), at(8, 12))
        let drifted = session(at(1, 48), at(8, 10))
        let edited = session(at(9, 17), at(10, 24), edited: true)
        let otherDay = session(at(-20, 0), at(-19, 0))           // wakes on Oct 31, not scored here
        let healed = session(at(11, 0), at(12, 30))
        let gone = SleepSessionReconcile.undetected(stored: [drifted, edited, otherDay, healed], fresh: [fresh],
                                                    scoredDays: ["2026-11-01"],
                                                    alreadyDropped: [healed.startTs], offsetSec: offset)
        XCTAssertTrue(gone.isEmpty)
    }
}
