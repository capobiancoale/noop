import XCTest
@testable import Strand

/// Pins the decimal separator of every number the app prints. `String(format: "%.1f", …)` ignores the
/// locale, so an Italian screen read "59.2"; `DisplayNumber` writes "59,2" there and "59.2" in English.
/// The locale is passed in, so these hold whatever the machine running them is set to.
final class DisplayNumberTests: XCTestCase {

    private let italian = Locale(identifier: "it_IT")
    private let english = Locale(identifier: "en_US")

    func testItalianUsesTheCommaEnglishTheDot() {
        XCTAssertEqual(DisplayNumber.decimal(59.24, locale: italian), "59,2")
        XCTAssertEqual(DisplayNumber.decimal(59.24, locale: english), "59.2")
    }

    func testFractionDigitsAreExact() {
        XCTAssertEqual(DisplayNumber.decimal(75, locale: italian), "75,0")
        XCTAssertEqual(DisplayNumber.decimal(-0.36, digits: 2, locale: italian), "-0,36")
        XCTAssertEqual(DisplayNumber.decimal(3, digits: 0, locale: italian), "3")
    }

    /// No thousands separator, so a four-digit value matches `%.Nf` digit for digit in English.
    func testNoGrouping() {
        XCTAssertEqual(DisplayNumber.decimal(1234.5, locale: english), "1234.5")
        XCTAssertEqual(DisplayNumber.decimal(1234.5, locale: italian), "1234,5")
    }

    func testSignedAlwaysCarriesASign() {
        XCTAssertEqual(DisplayNumber.signed(1.25, digits: 2, locale: italian), "+1,25")
        XCTAssertEqual(DisplayNumber.signed(-0.4, locale: english), "-0.4")
    }

    /// The unit formatter is what prints weight, distance and temperature; it follows the locale too.
    func testUnitFormatterFollowsTheLocale() {
        let separator = Locale.autoupdatingCurrent.decimalSeparator ?? "."
        XCTAssertEqual(UnitFormatter.massFromKilograms(75, system: .metric), "75\(separator)0 kg")
    }

    // MARK: - Journal questions (display only)

    /// A built-in question is translated for display; the stored text and every matcher keep English.
    func testStarterQuestionsHaveADisplayLabelAndCustomOnesStayVerbatim() {
        for q in JournalCatalogStore.starterQuestions {
            XCTAssertNotNil(JournalCatalogStore.localizedStarter(q), q)
        }
        XCTAssertNil(JournalCatalogStore.localizedStarter("Did you meditate?"))
        XCTAssertEqual(JournalCatalogStore.displayLabel(forQuestion: "  Did you meditate?\n"), "Did you meditate?")
    }

    /// Matching is on the catalog's normalised key (case and spacing), as the dedupe is.
    func testStarterLabelMatchesOnTheNormalisedKey() {
        XCTAssertNotNil(JournalCatalogStore.localizedStarter("did  you take MAGNESIUM?\n"))
    }
}
