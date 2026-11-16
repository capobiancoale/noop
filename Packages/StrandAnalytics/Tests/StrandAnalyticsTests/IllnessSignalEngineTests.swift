import XCTest
@testable import StrandAnalytics

final class IllnessSignalEngineTests: XCTestCase {

    private let labels = [
        "restingHR": "RHR +6",
        "skinTemp": "skin temp +0.7 °C",
        "hrv": "HRV −22%",
        "respiration": "respiration up",
    ]

    private func reading(_ z: Double) -> IllnessSignalEngine.SignalReading {
        IllnessSignalEngine.SignalReading(zIllnessward: z)
    }

    // MARK: - Classic illness pattern (no tags) → raised

    func testClassicThreeSignalPatternRaises() {
        // RHR, skin temp and HRV all well over the firing threshold, no confounders.
        let inputs = IllnessSignalEngine.Inputs(
            restingHR: reading(3.2), skinTemp: reading(3.0), hrv: reading(3.5))
        let r = IllnessSignalEngine.evaluate(inputs, context: .init(), firedLabels: labels)
        XCTAssertEqual(r.level, .raised)
        XCTAssertGreaterThanOrEqual(r.score, IllnessSignalEngine.raiseThreshold)
        XCTAssertEqual(r.signalCount, 3)
        XCTAssertEqual(r.firedSignals, ["RHR +6", "skin temp +0.7 °C", "HRV −22%"])
        XCTAssertTrue(r.suppressedBy.isEmpty)
        XCTAssertTrue(r.copy.contains("not a diagnosis"))
    }

    // MARK: - Same pattern + alcohol tag → suppressed (the core false-positive test)

    func testAlcoholTagSuppresses() {
        let inputs = IllnessSignalEngine.Inputs(
            restingHR: reading(3.2), skinTemp: reading(3.0), hrv: reading(3.5))
        let raised = IllnessSignalEngine.evaluate(inputs, context: .init(), firedLabels: labels)
        let suppressed = IllnessSignalEngine.evaluate(
            inputs, context: .init(alcohol: true), firedLabels: labels)
        XCTAssertEqual(suppressed.level, .suppressed)
        XCTAssertEqual(suppressed.suppressedBy, ["alcohol"])
        // Dampened well below the raised score.
        XCTAssertLessThan(suppressed.score, raised.score)
        XCTAssertEqual(suppressed.score, raised.score * IllnessSignalEngine.confounderDampen, accuracy: 1e-9)
        XCTAssertTrue(suppressed.copy.contains("alcohol"))
        XCTAssertTrue(suppressed.copy.contains("not illness"))
        XCTAssertTrue(suppressed.copy.contains("not a diagnosis"))
    }

    func testStressSaunaTravelEachDowngradeWithReason() {
        let inputs = IllnessSignalEngine.Inputs(
            restingHR: reading(3.2), skinTemp: reading(3.0), hrv: reading(3.5))
        let stress = IllnessSignalEngine.evaluate(inputs, context: .init(stress: true), firedLabels: labels)
        XCTAssertEqual(stress.level, .suppressed)
        XCTAssertEqual(stress.suppressedBy, ["stress"])

        let sauna = IllnessSignalEngine.evaluate(inputs, context: .init(sauna: true), firedLabels: labels)
        XCTAssertEqual(sauna.suppressedBy, ["sauna"])

        let travel = IllnessSignalEngine.evaluate(
            inputs, context: .init(travelPhaseJump: true), firedLabels: labels)
        XCTAssertEqual(travel.suppressedBy, ["travel"])
        XCTAssertTrue(travel.copy.contains("travel"))
    }

    func testMultipleConfoundersJoinNaturally() {
        let inputs = IllnessSignalEngine.Inputs(
            restingHR: reading(3.2), skinTemp: reading(3.0), hrv: reading(3.5))
        let r = IllnessSignalEngine.evaluate(
            inputs, context: .init(alcohol: true, stress: true), firedLabels: labels)
        XCTAssertEqual(r.suppressedBy, ["alcohol", "stress"])
        XCTAssertTrue(r.copy.contains("alcohol and stress"))
    }

    // MARK: - Already-sick tag → "rest up" copy, not "early warning"

    func testAlreadyUnwellSwitchesCopy() {
        let inputs = IllnessSignalEngine.Inputs(
            restingHR: reading(3.2), skinTemp: reading(3.0), hrv: reading(3.5))
        let r = IllnessSignalEngine.evaluate(
            inputs, context: .init(alreadyUnwell: true), firedLabels: labels)
        XCTAssertEqual(r.level, .alreadyUnwell)
        XCTAssertTrue(r.copy.contains("Rest up"))
        XCTAssertTrue(r.copy.contains("numbers agree"))
        XCTAssertFalse(r.copy.contains("Heads-up"))
    }

    // MARK: - Gates: single noisy night / untrusted baseline → silent

    func testSingleSignalDoesNotRaise() {
        // Only one signal over threshold → below corroboration gate → quiet.
        let inputs = IllnessSignalEngine.Inputs(restingHR: reading(4.0))
        let r = IllnessSignalEngine.evaluate(inputs, context: .init(), firedLabels: labels)
        XCTAssertEqual(r.level, .quiet)
        XCTAssertEqual(r.signalCount, 1)
    }

    func testUntrustedBaselineStaysSilent() {
        let inputs = IllnessSignalEngine.Inputs(
            restingHR: reading(3.2), skinTemp: reading(3.0), hrv: reading(3.5))
        let r = IllnessSignalEngine.evaluate(
            inputs, context: .init(baselineTrusted: false), firedLabels: labels)
        XCTAssertEqual(r.level, .quiet)
        XCTAssertFalse(r.copy.contains("Heads-up"))
    }

    func testBelowThresholdSignalsAreMildNotRaised() {
        // Two signals just over the firing threshold but composite below raiseThreshold → mild.
        let inputs = IllnessSignalEngine.Inputs(
            restingHR: reading(2.6), skinTemp: reading(2.6))
        let r = IllnessSignalEngine.evaluate(inputs, context: .init(), firedLabels: labels)
        XCTAssertEqual(r.signalCount, 2)
        XCTAssertEqual(r.level, .mild)
        XCTAssertLessThan(r.score, IllnessSignalEngine.raiseThreshold)
        XCTAssertGreaterThanOrEqual(r.score, IllnessSignalEngine.mildThreshold)
    }

    func testAbsentSignalsDoNotCount() {
        let inputs = IllnessSignalEngine.Inputs(
            restingHR: reading(3.2),
            skinTemp: IllnessSignalEngine.SignalReading(zIllnessward: 9.0, present: false),
            hrv: reading(3.5))
        let r = IllnessSignalEngine.evaluate(inputs, context: .init(), firedLabels: labels)
        // The absent skin-temp does not fire despite its huge z.
        XCTAssertEqual(r.signalCount, 2)
        XCTAssertFalse(r.firedSignals.contains("skin temp +0.7 °C"))
    }

    // MARK: - Copy never names a condition

    func testCopyNeverNamesACondition() {
        let inputs = IllnessSignalEngine.Inputs(
            restingHR: reading(3.2), skinTemp: reading(3.0), hrv: reading(3.5))
        let banned = ["covid", "flu", "fever", "infection", "sick with", "illness with", "disease"]
        for ctx in [IllnessSignalEngine.Context(),
                    .init(alcohol: true),
                    .init(alreadyUnwell: true)] {
            let copy = IllnessSignalEngine.evaluate(inputs, context: ctx, firedLabels: labels).copy.lowercased()
            for b in banned { XCTAssertFalse(copy.contains(b), "copy contained banned term \(b): \(copy)") }
        }
    }

    // MARK: - A low glucose at night is a confounder like the others

    func testNocturnalLowSuppressesLikeOtherConfounders() {
        let inputs = IllnessSignalEngine.Inputs(
            restingHR: reading(3.2), skinTemp: reading(3.0), hrv: reading(3.5))
        let raised = IllnessSignalEngine.evaluate(inputs, context: .init(), firedLabels: labels)
        let low = IllnessSignalEngine.evaluate(
            inputs, context: .init(nocturnalLow: true), firedLabels: labels)
        XCTAssertEqual(raised.level, .raised)
        XCTAssertEqual(low.level, .suppressed)
        XCTAssertEqual(low.suppressedBy, ["a low glucose at night"])
        XCTAssertEqual(low.score, raised.score * IllnessSignalEngine.confounderDampen, accuracy: 1e-9)
        XCTAssertTrue(low.copy.contains("a low glucose at night"))
        XCTAssertTrue(low.copy.contains("not a diagnosis"))
    }

    func testNocturnalLowComesAfterTheOtherReasons() {
        let inputs = IllnessSignalEngine.Inputs(
            restingHR: reading(3.2), skinTemp: reading(3.0), hrv: reading(3.5))
        let r = IllnessSignalEngine.evaluate(
            inputs, context: .init(alcohol: true, travelPhaseJump: true, nocturnalLow: true),
            firedLabels: labels)
        XCTAssertEqual(r.suppressedBy, ["alcohol", "travel", "a low glucose at night"])
        XCTAssertTrue(r.copy.contains("alcohol, travel and a low glucose at night"))
    }

    func testNocturnalLowDefaultsOffAndLeavesEveryOtherPathUnchanged() {
        XCTAssertFalse(IllnessSignalEngine.Context().nocturnalLow)
        XCTAssertNil(IllnessSignalEngine.Context().personalRaiseThreshold)
        // A quiet day stays quiet and an already-unwell day stays already-unwell with the flag set:
        // the flag only adds a reason where the engine would otherwise have raised.
        let quiet = IllnessSignalEngine.evaluate(
            IllnessSignalEngine.Inputs(restingHR: reading(4.0)),
            context: .init(nocturnalLow: true), firedLabels: labels)
        XCTAssertEqual(quiet.level, .quiet)
        XCTAssertTrue(quiet.suppressedBy.isEmpty)
        let unwell = IllnessSignalEngine.evaluate(
            IllnessSignalEngine.Inputs(restingHR: reading(3.2), hrv: reading(3.5)),
            context: .init(alreadyUnwell: true, nocturnalLow: true), firedLabels: labels)
        XCTAssertEqual(unwell.level, .alreadyUnwell)
    }

    func testNocturnalLowThresholdIsLevelOneHypoglycaemia() {
        XCTAssertEqual(IllnessSignalEngine.nocturnalLowMgdl, 70.0)
    }

    // MARK: - Personal raise threshold (only ever stricter)

    /// Two signals: z 3.5 and 3.5 → 2 × 22 × 1.5 = 66.
    private let midInputs = IllnessSignalEngine.Inputs(restingHR: .init(zIllnessward: 3.5),
                                                       hrv: .init(zIllnessward: 3.5))

    func testPersonalThresholdAboveScoreTurnsRaisedIntoMild() {
        let base = IllnessSignalEngine.evaluate(midInputs, context: .init(), firedLabels: labels)
        XCTAssertEqual(base.level, .raised)
        XCTAssertEqual(base.score, 66, accuracy: 1e-9)
        let strict = IllnessSignalEngine.evaluate(
            midInputs, context: .init(personalRaiseThreshold: 70), firedLabels: labels)
        XCTAssertEqual(strict.level, .mild)
        XCTAssertEqual(strict.score, 66, accuracy: 1e-9)          // the score itself is untouched
        let atScore = IllnessSignalEngine.evaluate(
            midInputs, context: .init(personalRaiseThreshold: 66), firedLabels: labels)
        XCTAssertEqual(atScore.level, .raised)                    // at the threshold counts
    }

    func testPersonalThresholdBelowTheDefaultIsIgnored() {
        // Two signals at z 2.6: score 26.4 (mild) and still mild with a "personal" 10, never raised.
        let inputs = IllnessSignalEngine.Inputs(restingHR: reading(2.6), skinTemp: reading(2.6))
        let r = IllnessSignalEngine.evaluate(
            inputs, context: .init(personalRaiseThreshold: 10), firedLabels: labels)
        XCTAssertEqual(r.level, .mild)
        // A score of 44 (two signals at z 3.0) is below the shipped 50, so a "personal" 10 cannot raise it.
        let at44 = IllnessSignalEngine.Inputs(restingHR: reading(3.0), hrv: reading(3.0))
        XCTAssertEqual(IllnessSignalEngine.evaluate(at44, context: .init(personalRaiseThreshold: 10),
                                                    firedLabels: labels).level, .mild)
        XCTAssertEqual(IllnessSignalEngine.effectiveRaiseThreshold(personal: 10), 50)
        XCTAssertEqual(IllnessSignalEngine.effectiveRaiseThreshold(personal: nil), 50)
        XCTAssertEqual(IllnessSignalEngine.effectiveRaiseThreshold(personal: 83), 83)
    }

    func testPersonalThresholdDoesNotTouchSuppressedOrUnwellPaths() {
        let strong = IllnessSignalEngine.Inputs(
            restingHR: reading(3.2), skinTemp: reading(3.0), hrv: reading(3.5))
        let alc = IllnessSignalEngine.evaluate(
            strong, context: .init(alcohol: true, personalRaiseThreshold: 95), firedLabels: labels)
        XCTAssertEqual(alc.level, .suppressed)
        let unwell = IllnessSignalEngine.evaluate(
            strong, context: .init(alreadyUnwell: true, personalRaiseThreshold: 95), firedLabels: labels)
        XCTAssertEqual(unwell.level, .alreadyUnwell)
    }

    /// `wouldRaise` (what the calibration replay counts) must be exactly "evaluate reaches .raised on a
    /// day with no confounder and a trusted baseline", over a grid of z's and personal thresholds.
    func testWouldRaiseAgreesWithEvaluate() {
        let zs: [Double] = [0, 1.9, 2.2, 2.6, 3.0, 3.5, 4.2, 6, 12]
        for a in zs { for b in zs { for c in [0.0, 2.5, 5.0] {
            let inputs = IllnessSignalEngine.Inputs(restingHR: reading(a), skinTemp: reading(b),
                                                    hrv: reading(c))
            let comp = IllnessSignalEngine.composite(inputs)
            for personal in [nil, 20.0, 50.0, 62.0, 80.0, 100.0] as [Double?] {
                let r = IllnessSignalEngine.evaluate(
                    inputs, context: .init(personalRaiseThreshold: personal), firedLabels: labels)
                let predicted = IllnessSignalEngine.wouldRaise(
                    score: comp.score, signalCount: comp.firedKeys.count, personalRaiseThreshold: personal)
                XCTAssertEqual(r.level == .raised, predicted, "z=\(a),\(b),\(c) personal=\(String(describing: personal))")
                XCTAssertEqual(r.score, comp.score, accuracy: 1e-12)
            }
        } } }
    }

    func testScorePerSignalCapping() {
        // A single enormous z is capped, so it alone can't saturate the composite.
        let inputs = IllnessSignalEngine.Inputs(restingHR: reading(100.0), skinTemp: reading(2.5))
        let r = IllnessSignalEngine.evaluate(inputs, context: .init(), firedLabels: labels)
        // RHR caps at perSignalCap (40) + skinTemp small contribution.
        let expectedSkin = IllnessSignalEngine.kZToScore * (2.5 - IllnessSignalEngine.signalZThreshold)
        XCTAssertEqual(r.score, IllnessSignalEngine.perSignalCap + expectedSkin, accuracy: 1e-9)
    }
}
