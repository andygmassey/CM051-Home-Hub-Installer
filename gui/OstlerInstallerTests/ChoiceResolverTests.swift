// F&F tester report 2026-11-05, items 3 and 5. See ChoiceResolver.swift.
import XCTest
@testable import OstlerInstaller

final class ChoiceResolverTests: XCTestCase {
    func testEmptyChoicesFallBackToTheKnownList() {
        let o = ChoiceResolver.choices(promptId: "channel_choice", choices: [], defaultValue: nil)
        XCTAssertEqual(o, ["1", "2", "3", "4", "5"])
    }

    func testPromptOwnChoicesWin() {
        let o = ChoiceResolver.choices(promptId: "channel_choice", choices: ["1", "2"], defaultValue: "1")
        XCTAssertEqual(o, ["1", "2"])
    }

    func testUnknownPromptWithDefaultStillRendersOne() {
        XCTAssertEqual(ChoiceResolver.choices(promptId: "x", choices: [], defaultValue: "a"), ["a"])
    }

    /// The review-mode screen: a prior answer that is empty or stale must select
    /// something that is in the list, never nothing.
    func testReviewWithEmptyOrStalePriorAnswerStillSelectsAnOption() {
        let o = ["1", "2", "3", "4", "5"]
        for prior in [nil, "", "imessage"] as [String?] {
            let s = ChoiceResolver.selection(promptId: "channel_choice", current: prior, options: o, defaultValue: "3")
            XCTAssertTrue(o.contains(s), "prior \(String(describing: prior)) selected \(s)")
        }
        XCTAssertEqual(ChoiceResolver.selection(promptId: "channel_choice", current: "2", options: o, defaultValue: "3"), "2")
    }

    /// item 5: a disabled primary button must not look like an enabled one.
    func testDisabledPrimaryButtonIsVisiblyDimmed() {
        XCTAssertLessThan(OstlerButtonLook.opacity(isEnabled: false, isPressed: false),
                          OstlerButtonLook.opacity(isEnabled: true, isPressed: false) - 0.3)
    }
}
