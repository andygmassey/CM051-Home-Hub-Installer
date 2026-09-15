// RecoveryKeySurvivesFailedInstallTests.swift
//
// LAUNCH BLOCKER. A customer whose install FAILED never saw their
// recovery key, and there was no second chance to show it to them.
//
// THE CHAIN, each link measured on this tree:
//
//   1. install.sh mints the recovery key, emits it once on a
//      `#OSTLER RECOVERY_KEY value=...` marker, and stores it NOWHERE.
//   2. The GUI holds it in `InstallerCoordinator.recoveryKey`, an
//      in-memory @Published property, wiped on acknowledgement.
//   3. The reveal sheet hung off `HintPanelView`, whose own comment
//      claimed the key "is presentable whatever the install's outcome".
//   4. `HintPanelView()` is instantiated at EXACTLY ONE place --
//      ContentView's `installLayout` -- inside the `else` arm of
//      `if coordinator.finished == .fail`. (Control for that search:
//      `SidebarView()` and `InstallFailedBodyView()` resolve to one
//      real site each in the same grep shape, so the search was not
//      silently returning nothing.)
//   5. So on `.fail` SwiftUI renders `InstallFailedBodyView()`,
//      HintPanelView leaves the view tree, and the `.sheet` attached
//      to it leaves with it. The sheet could not present.
//   6. The keychain entry the key protects IS on disk, so the
//      customer's re-run -- their obvious next act -- takes
//      install.sh's "already configured" skip and emits NO marker.
//
// The loss is therefore PERMANENT and silent: the only route back into
// the customer's own encrypted graph, gone, with nothing on screen ever
// having offered it.
//
// WHY THE STRUCTURAL TESTS BELOW CARRY THE WEIGHT. The presentation
// PREDICATE was never the bug -- `(key non-empty) && !acknowledged` was
// correct before the fix and is correct after it. The bug was WHERE the
// sheet was attached. A test that only exercised the predicate would
// have passed on the broken tree, which is precisely how this shipped.
// So the attachment point is pinned as source shape, per locked memory
// `feedback_silent_bail_regression_test_shape`.

import Foundation
import XCTest
@testable import OstlerInstaller

@MainActor
final class RecoveryKeySurvivesFailedInstallTests: XCTestCase {

    // MARK: - Source loaders

    private func source(_ relative: String) throws -> String {
        let url = try StringsCatalogueEmDashTest.repoFile(relative: relative)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func contentViewSource() throws -> String {
        try source("gui/OstlerInstaller/Views/ContentView.swift")
    }

    private func hintPanelSource() throws -> String {
        try source("gui/OstlerInstaller/Views/HintPanelView.swift")
    }

    // MARK: - The regression itself: WHERE the sheet is attached

    /// THE MUTATION DETECTOR. Moving the reveal back onto HintPanelView
    /// re-creates the shipped defect exactly, and this is the assertion
    /// that goes red when it happens.
    func testRecoveryRevealIsNotHostedByAConditionallyRenderedView() throws {
        let hint = try hintPanelSource()
        XCTAssertFalse(
            hint.contains("RecoveryKeyView()"),
            """
            RecoveryKeyView is being presented from HintPanelView again. \
            HintPanelView is instantiated ONLY inside the `else` arm of \
            `if coordinator.finished == .fail` in ContentView.installLayout, \
            so a sheet attached to it cannot present on a failed install -- \
            and install.sh stores the recovery key nowhere, so the customer \
            loses the only way back into their encrypted graph for good. \
            Attach the reveal at the root of ContentView instead.
            """
        )

        // Positive control for this file read: HintPanelView really is
        // the file we think it is and really is non-empty. A typo in the
        // path would otherwise make the assertion above pass by reading
        // nothing at all.
        XCTAssertTrue(
            hint.contains("struct HintPanelView"),
            "Loaded the wrong file for HintPanelView, so the absence check above proved nothing."
        )
    }

    /// The reveal must be hosted by a view that is in the tree for EVERY
    /// branch. `rootContent` is ContentView's unconditional root; the
    /// sheet must hang off it, not off anything inside it.
    func testRecoveryRevealIsAttachedAtTheRootOfContentView() throws {
        let cv = try contentViewSource()

        XCTAssertTrue(
            cv.contains("RecoveryKeyView()"),
            "ContentView must host the recovery-key reveal. It is the only view in the tree on every terminal branch."
        )
        XCTAssertTrue(
            cv.contains("coordinator.shouldPresentRecoveryKey"),
            "The reveal must be driven by InstallerCoordinator.shouldPresentRecoveryKey so the condition is one testable value rather than an inline binding nobody can assert."
        )

        // The attachment must sit in `body`, i.e. textually BEFORE the
        // declaration of `rootContent`. If it drifts inside rootContent
        // (or worse, into installLayout) it is back under a branch.
        guard let sheetAt = cv.range(of: "RecoveryKeyView()")?.lowerBound,
              let rootDeclAt = cv.range(of: "private var rootContent")?.lowerBound
        else {
            return XCTFail("Could not locate both the reveal and the rootContent declaration in ContentView.swift.")
        }
        XCTAssertTrue(
            sheetAt < rootDeclAt,
            """
            The recovery-key sheet has moved inside `rootContent` (or below it). \
            It must be attached to `rootContent` from `body`, so it survives \
            every branch rootContent switches between -- including the \
            `finished == .fail` branch that renders InstallFailedBodyView.
            """
        )
    }

    // MARK: - The predicate, across every terminal state

    /// A key that exists and is unacknowledged is presentable whatever
    /// the outcome. Asserted for each terminal the customer can land in,
    /// not just the happy one.
    func testKeyIsPresentableOnEveryTerminalState() {
        for done in ["ok", "fail", "cancelled"] {
            let c = InstallerCoordinator()
            c.simulateLineForTests("#OSTLER\tRECOVERY_KEY\tvalue=SWAN-OTTER-BIRCH-9421")
            c.simulateLineForTests("#OSTLER\tDONE\tstatus=\(done)")
            XCTAssertTrue(
                c.shouldPresentRecoveryKey,
                "DONE status=\(done): an unacknowledged recovery key must still be presentable. install.sh stores it nowhere and the re-run emits no marker, so not showing it here loses it permanently."
            )
        }
    }

    /// The customer-facing sequence of the actual incident: the key is
    /// minted, THEN the install dies. Both facts must hold at once --
    /// the installer is in its failure terminal AND the reveal is live.
    func testKeyMintedThenInstallFailsStillReveals() {
        let c = InstallerCoordinator()
        c.simulateLineForTests("#OSTLER\tSTEP_BEGIN\tid=encrypt_graph\ttitle=Encrypting your data")
        c.simulateLineForTests("#OSTLER\tRECOVERY_KEY\tvalue=SWAN-OTTER-BIRCH-9421")
        c.simulateLineForTests("#OSTLER\tDONE\tstatus=fail")

        XCTAssertEqual(c.finished, .fail, "Precondition: the install must actually be in its failure terminal.")
        XCTAssertTrue(
            c.shouldPresentRecoveryKey,
            "The install failed AFTER minting the key. This is the measured incident shape, and the reveal must be live."
        )
    }

    /// The other side, so the assertion above is a choice and not a
    /// field that is simply always true: acknowledgement closes it.
    func testAcknowledgementClosesTheReveal() {
        let c = InstallerCoordinator()
        c.simulateLineForTests("#OSTLER\tRECOVERY_KEY\tvalue=SWAN-OTTER-BIRCH-9421")
        XCTAssertTrue(c.shouldPresentRecoveryKey)
        c.recoveryKeyAcknowledged = true
        XCTAssertFalse(
            c.shouldPresentRecoveryKey,
            "Once the customer confirms they have saved it, the sheet must stop presenting."
        )
    }

    /// An empty RECOVERY_KEY marker must not raise an empty sheet.
    func testEmptyKeyDoesNotPresent() {
        let c = InstallerCoordinator()
        c.simulateLineForTests("#OSTLER\tRECOVERY_KEY\tvalue=")
        XCTAssertFalse(
            c.shouldPresentRecoveryKey,
            "An empty marker value must not raise a sheet showing nothing."
        )
    }

    // MARK: - Auto-quit must not close over an unacknowledged key

    /// The second way the same key was lost: the app quits itself 300s
    /// after a SUCCESSFUL install. A customer who read the key and went
    /// to fetch their password manager came back to a terminated app and
    /// a key that existed only in its memory. Same permanent loss as the
    /// failure path, reached by walking away for five minutes.
    func testAutoQuitIsSuspendedWhileAnUnacknowledgedKeyIsOnScreen() {
        let c = InstallerCoordinator()
        var quit = false
        c.quitAction = { quit = true }
        c.simulateLineForTests("#OSTLER\tRECOVERY_KEY\tvalue=SWAN-OTTER-BIRCH-9421")
        c.armAutoQuit()
        let armedAt = c.autoQuitRemaining

        // Drive the countdown far past the whole 300s window.
        for _ in 0..<(InstallerCoordinator.autoQuitSeconds + 60) {
            XCTAssertEqual(
                c.autoQuitTick(),
                .heldByUnacknowledgedRecoveryKey,
                "Each tick must report the countdown held while the key is unacknowledged."
            )
        }

        XCTAssertFalse(
            quit,
            """
            The installer terminated itself while an unacknowledged recovery key \
            was on screen. The key lives only in memory, so quitting destroys it \
            and the customer's re-run emits no new marker.
            """
        )
        XCTAssertEqual(
            c.autoQuitRemaining, armedAt,
            "The countdown must be SUSPENDED, not merely blocked at zero: the customer gets the full window back once they acknowledge."
        )
        c.cancelAutoQuit()
    }

    /// The complement: with no key outstanding the countdown still runs
    /// and still terminates. Without this the test above would pass just
    /// as happily on an auto-quit that had been broken outright.
    func testAutoQuitStillQuitsWhenNoKeyIsOutstanding() {
        let c = InstallerCoordinator()
        var quit = false
        c.quitAction = { quit = true }
        c.armAutoQuit()

        XCTAssertEqual(c.autoQuitTick(), .counted(remaining: InstallerCoordinator.autoQuitSeconds - 1))

        for _ in 0..<InstallerCoordinator.autoQuitSeconds {
            if case .quit = c.autoQuitTick() { break }
        }
        XCTAssertTrue(quit, "With nothing outstanding the auto-quit must still terminate the app.")
        c.cancelAutoQuit()
    }

    /// Acknowledging RESUMES the countdown rather than quitting on the
    /// spot: the customer ticks the box and gets their window, they do
    /// not get the window slammed shut the instant they confirm.
    func testAcknowledgementResumesRatherThanQuitsImmediately() {
        let c = InstallerCoordinator()
        var quit = false
        c.quitAction = { quit = true }
        c.simulateLineForTests("#OSTLER\tRECOVERY_KEY\tvalue=SWAN-OTTER-BIRCH-9421")
        c.armAutoQuit()
        _ = c.autoQuitTick()  // held
        XCTAssertFalse(quit)

        c.recoveryKeyAcknowledged = true
        XCTAssertEqual(
            c.autoQuitTick(),
            .counted(remaining: InstallerCoordinator.autoQuitSeconds - 1),
            "After acknowledgement the countdown resumes from where it was held."
        )
        XCTAssertFalse(quit, "Acknowledging must not terminate the app immediately.")
        c.cancelAutoQuit()
    }
}
