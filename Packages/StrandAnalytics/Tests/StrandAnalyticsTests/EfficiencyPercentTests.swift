import XCTest
@testable import StrandAnalytics

final class EfficiencyPercentTests: XCTestCase {
    func testFractionBecomesPercent() {
        XCTAssertEqual(EfficiencyPercent.percent(0.92)!, 92, accuracy: 1e-9)
        XCTAssertEqual(EfficiencyPercent.percent(1.0)!, 100, accuracy: 1e-9)
    }

    func testPercentIsUnchanged() {
        XCTAssertEqual(EfficiencyPercent.percent(88)!, 88, accuracy: 1e-9)
        XCTAssertEqual(EfficiencyPercent.percent(100)!, 100, accuracy: 1e-9)
        XCTAssertEqual(EfficiencyPercent.percent(1.5)!, 1.5, accuracy: 1e-9)
    }

    func testZeroAndGarbage() {
        XCTAssertEqual(EfficiencyPercent.percent(0)!, 0, accuracy: 1e-9)
        XCTAssertNil(EfficiencyPercent.percent(-3))
        XCTAssertNil(EfficiencyPercent.percent(.nan))
    }
}
