import XCTest
@testable import StrandAnalytics

/// The HRV & Autonomic test mode's pure cleaning trace. Pins the lines a fixture beat series produces AND
/// proves the emitter never changes the HRVResult `analyze(...)` returns (Test Centre Group G). Twin of
/// the Android HrvAnalyzerTraceTest. No em-dashes.
final class HRVAnalyzerTraceTests: XCTestCase {

    func testTraceResultIsByteIdenticalToAnalyze() {
        // 22 clean intervals near 800 ms, the same golden series HRVAnalyzerTests uses.
        let nn: [Double] = [800, 810, 805, 815, 800, 820, 810, 800, 815, 805, 810,
                            800, 820, 815, 805, 810, 800, 815, 810, 805, 800, 820]
        let plain = HRVAnalyzer.analyze(rawRR: nn)
        let (traced, lines) = HRVAnalyzer.analyzeTrace(rawRR: nn)
        XCTAssertEqual(traced, plain)
        XCTAssertTrue(lines.contains { $0.contains("nInput=22") && $0.contains("nClean=22") })
        XCTAssertTrue(lines.contains { $0.contains("minBeats need=20") && $0.contains("CLEARED") })
        XCTAssertTrue(lines.contains { $0.hasPrefix("hrv rmssd=") })
        XCTAssertFalse(lines.contains { $0.contains("\u{2014}") })
    }

    func testTraceReportsMinBeatsFailureAndNilResult() {
        // 19 clean intervals → below minBeats(20) → empty result.
        let rr = Array(repeating: 800.0, count: 19)
        let plain = HRVAnalyzer.analyze(rawRR: rr)
        let (traced, lines) = HRVAnalyzer.analyzeTrace(rawRR: rr)
        XCTAssertEqual(traced, plain)
        XCTAssertNil(traced.rmssd)
        XCTAssertTrue(lines.contains { $0.contains("minBeats need=20 clean=19 FAILED") })
        XCTAssertTrue(lines.contains { $0.contains("result=nil") })
    }

    func testTraceReportsDropsAndCorrections() {
        // 60 realistic beats with one dropout (100 ms, below the 150 ms hard bound) and one missed beat (two
        // intervals merged into one): the dropout is dropped, the missed beat is split back.
        var rr = RRFixtures.resting(count: 60, seed: 21)
        rr[30] += rr[31]
        rr.remove(at: 31)
        rr.insert(100, at: 10)
        let (traced, lines) = HRVAnalyzer.analyzeTrace(rawRR: rr)
        XCTAssertEqual(traced, HRVAnalyzer.analyze(rawRR: rr))
        XCTAssertEqual(traced.nClean, 60)
        let line = lines.first { $0.hasPrefix("hrv dropped=") }
        XCTAssertNotNil(line)
        XCTAssertTrue(line!.contains("dropped=1 "))
        XCTAssertTrue(line!.contains("corrected=1 "))
        XCTAssertTrue(line!.contains("Lipponen-Tarvainen: ectopic=0 missed=1 extra=0 longShort=0"))
        XCTAssertFalse(lines.contains { $0.contains("\u{2014}") })
    }

    func testSpotGateLineOnlyWhenCeilingSupplied() {
        let nn: [Double] = Array(repeating: 800.0, count: 22)
        // Nightly/continuous path (nil ceiling): no spotGate line, byte-identical to analyze().
        let (_, contLines) = HRVAnalyzer.analyzeTrace(rawRR: nn, maxRejectedFraction: nil, path: "continuous")
        XCTAssertFalse(contLines.contains { $0.contains("spotGate") })
        XCTAssertTrue(contLines.contains { $0.contains("path=continuous") })
        // Spot path (ceiling supplied): the gate line is present.
        let (_, spotLines) = HRVAnalyzer.analyzeTrace(
            rawRR: nn, maxRejectedFraction: HRVAnalyzer.defaultSpotMaxRejectedFraction, path: "spot")
        XCTAssertTrue(spotLines.contains { $0.contains("spotGate") && $0.contains("PASS") })
    }
}
