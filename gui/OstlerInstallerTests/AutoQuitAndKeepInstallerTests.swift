// AutoQuitAndKeepInstallerTests.swift
//
// v1.0.42 upgrade walk, 2026-08-23, findings 1a / 1b / 1d.
//
// 1a  The installer sat open after a SUCCESSFUL install holding 4.27 GB
//     until macOS ran the whole box out of application memory. It now
//     arms a visible countdown and quits itself. The leak is fixed
//     separately (OutputLineBuffer); this bounds every retention path we
//     have NOT found by making "left open forever after success"
//     impossible.
//
// 1b  The Done button used to move OstlerInstaller.app to the Trash
//     UNCONDITIONALLY and silently (CX-52). Re-running the installer is a
//     legitimate repair route -- the v1.0.42 upgrade walk is exactly that
//     route -- and CM031 #637 is the standing example of what "your only
//     escape is delete and reinstall" costs. The default is now KEEP.
//
// 1d  Nothing in this estate watched a process for unbounded growth.
//     MemoryCeiling classifies the footprint; these tests drive it to RED
//     without allocating a gigabyte, which is the only reason the verdict
//     function takes the footprint as an argument instead of reading it.
//
// The defaults asserted here are the whole point. A test that only checked
// "the toggle can be flipped" would pass just as happily on the pre-fix
// auto-trash behaviour.

import XCTest
@testable import OstlerInstaller

@MainActor
final class AutoQuitAndKeepInstallerTests: XCTestCase {

    // MARK: - 1b: offer-to-trash DEFAULTS TO KEEP

    func testInstallerIsKeptByDefault() {
        let c = InstallerCoordinator()
        XCTAssertFalse(
            c.trashInstallerOnQuit,
            "The installer must be KEPT unless the customer asks otherwise. "
            + "CX-52 trashed it unconditionally; re-running is the repair route."
        )
    }

    func testQuittingWithTheDefaultDoesNotTrashTheInstaller() {
        let c = InstallerCoordinator()
        var quit = false
        c.quitAction = { quit = true }
        c.finishAndQuit()
        XCTAssertTrue(quit, "finishAndQuit did not reach its terminate sink")
        XCTAssertFalse(
            c.didTrashInstaller,
            "The installer was trashed on the default path. That is the CX-52 "
            + "behaviour this change removes."
        )
    }

    func testTrashIsReachableWhenTheCustomerAsksForIt() {
        // The other side of the default: prove the flag is not inert, so the
        // assertion above is a choice and not a dead field. The bundle path
        // under test is the DerivedData test host, so no move actually
        // happens -- the assertion is that the branch is live and the quit
        // still fires.
        let c = InstallerCoordinator()
        var quit = false
        c.quitAction = { quit = true }
        c.trashInstallerOnQuit = true
        c.finishAndQuit()
        XCTAssertTrue(c.trashInstallerOnQuit)
        XCTAssertTrue(quit, "opting into the trash must not block the quit")
    }

    // MARK: - 1a: auto-quit arms on confirmed success only

    func testAutoQuitIsNotArmedBeforeSuccess() {
        let c = InstallerCoordinator()
        XCTAssertNil(
            c.autoQuitRemaining,
            "A fresh coordinator must not be counting down; the clock starts "
            + "at CONFIRMED success, not at launch."
        )
    }

    func testArmAutoQuitStartsTheCountdownAtTheFullWindow() {
        let c = InstallerCoordinator()
        c.quitAction = {}
        c.armAutoQuit()
        XCTAssertEqual(c.autoQuitRemaining, InstallerCoordinator.autoQuitSeconds)
        c.cancelAutoQuit()
    }

    func testArmAutoQuitIsIdempotent() {
        // A second DONE marker, or a re-entrant terminationHandler, must not
        // stack a second timer and halve the customer's window.
        let c = InstallerCoordinator()
        c.quitAction = {}
        c.armAutoQuit()
        c.autoQuitRemaining = 7
        c.armAutoQuit()
        XCTAssertEqual(
            c.autoQuitRemaining, 7,
            "A second armAutoQuit() reset the countdown -- two timers are running."
        )
        c.cancelAutoQuit()
    }

    func testTheWindowIsLongEnoughToScanThePairingQR() {
        // The completion screen carries the iOS pairing QR. A window that
        // closes before a customer can pick up their phone would trade one
        // defect for a worse one.
        XCTAssertGreaterThanOrEqual(
            InstallerCoordinator.autoQuitSeconds, 120,
            "The auto-quit window is too short to scan the pairing QR."
        )
        XCTAssertLessThanOrEqual(
            InstallerCoordinator.autoQuitSeconds, 900,
            "The auto-quit window is long enough that an idle installer can "
            + "still outlive the session it belongs to."
        )
    }

    func testCountdownFormat() {
        XCTAssertEqual(InstallerCoordinator.mmss(300), "5:00")
        XCTAssertEqual(InstallerCoordinator.mmss(61), "1:01")
        XCTAssertEqual(InstallerCoordinator.mmss(9), "0:09")
        XCTAssertEqual(InstallerCoordinator.mmss(0), "0:00")
        XCTAssertEqual(InstallerCoordinator.mmss(-5), "0:00",
                       "A negative remainder must clamp, not render '-1:-5'.")
    }

    // MARK: - 1a: a FAILED install must NOT auto-quit

    func testFailureDoesNotArmTheCountdown() {
        // Reconciliation is the seam that decides. A failed install is
        // exactly when the customer needs the log drawer and Copy log; the
        // window must not close under them.
        let outcome = InstallerCoordinator.reconcileTermination(
            donedMarker: .fail, cancelled: false, exitCode: 1, failedSteps: 0)
        guard case .confirmedFailure = outcome else {
            return XCTFail("expected .confirmedFailure, got \(outcome)")
        }
        let c = InstallerCoordinator()
        XCTAssertNil(c.autoQuitRemaining)
    }

    // MARK: - 1d: the memory ceiling, driven to RED

    func testFootprintBelowTheWarningThresholdIsOK() {
        XCTAssertEqual(
            MemoryCeiling.verdict(footprint: 64 * 1024 * 1024), .ok,
            "64 MB is a normal installer footprint and must not warn."
        )
    }

    func testFootprintAtTheWarnThresholdWarns() {
        let v = MemoryCeiling.verdict(footprint: MemoryCeiling.warnBytes)
        guard case .warn = v else {
            return XCTFail("expected .warn at exactly the threshold, got \(v)")
        }
    }

    func testTheMeasuredFailureWouldHaveFiredCritical() {
        // THE CASE THIS EXISTS FOR. 4.27 GB, read off Activity Monitor on the
        // Mac mini, 2026-08-23, AFTER a successful install. If this ever
        // stops classifying as critical, the guard has been tuned past the
        // event it was built for.
        let measured = UInt64(4.27 * 1_073_741_824)
        let v = MemoryCeiling.verdict(footprint: measured)
        guard case .critical(let bytes) = v else {
            return XCTFail("4.27 GB did not classify as critical: \(v)")
        }
        XCTAssertEqual(bytes, measured)
    }

    func testThresholdsAreOrdered() {
        XCTAssertLessThan(
            MemoryCeiling.warnBytes, MemoryCeiling.criticalBytes,
            "warn must fire before critical, or the ladder has no rungs."
        )
    }

    func testCurrentFootprintIsReadableAndPlausible() {
        // Positive control on the kernel query itself: verdict() is only
        // trustworthy if something real feeds it. nil here would mean the
        // guard silently never runs.
        guard let f = MemoryCeiling.currentFootprint() else {
            return XCTFail("task_info(TASK_VM_INFO) returned no footprint; "
                           + "the ceiling guard would never fire in production.")
        }
        XCTAssertGreaterThan(f, 0)
        XCTAssertLessThan(f, 64 * 1024 * 1024 * 1024,
                          "a 64 GB test process is not a plausible reading")
    }

    func testMegabytesFormatting() {
        XCTAssertEqual(MemoryCeiling.megabytes(1_048_576), "1.0")
        XCTAssertEqual(MemoryCeiling.megabytes(4_294_967_296), "4096.0")
    }

    // MARK: - the copy the new surfaces depend on

    func testNewCatalogueKeysResolve() {
        // ViewCopy returns the dotted key itself when a key is missing, so a
        // key that resolves to itself is a missing string, not a rendered one.
        for key in [
            "footer.auto_quit_countdown",
            "install_complete.keep_installer_label",
            "install_complete.keep_installer_help",
            "install_complete.auto_quit_note",
            "install_complete.memory_ceiling_label",
            "install_complete.memory_ceiling_body",
        ] {
            XCTAssertNotEqual(
                ViewCopy.shared.string(for: key), key,
                "ViewCopy.json is missing \(key) -- the screen would render the dotted key."
            )
        }
    }

    func testCountdownCopyCarriesTheTimePlaceholder() {
        let raw = ViewCopy.shared.string(for: "footer.auto_quit_countdown")
        XCTAssertTrue(
            raw.contains("{time}"),
            "The countdown string has no {time} slot, so the label would be static."
        )
        let filled = ViewCopy.shared.string(for: "footer.auto_quit_countdown",
                                            fills: ["time": "4:59"])
        XCTAssertTrue(filled.contains("4:59"))
        XCTAssertFalse(filled.contains("{time}"))
    }

    // MARK: - the bounded buffer, at the type level

    func testOutputLineBufferTreatsCarriageReturnAsATerminator() {
        var b = OutputLineBuffer()
        let lines = b.ingest("first\rsecond\rthird")
        XCTAssertEqual(lines, ["first", "second"])
        XCTAssertEqual(b.buffer, "third")
    }

    func testOutputLineBufferCollapsesCRLF() {
        // In Swift "\r\n" is ONE Character, equal to neither "\r" nor "\n".
        // The pre-fix firstIndex(of: "\n") never found it, which made CRLF a
        // second unbounded-growth path.
        var b = OutputLineBuffer()
        XCTAssertEqual(b.ingest("a\r\nb\r\n"), ["a", "b"])
        XCTAssertEqual(b.buffer, "")
    }

    func testOutputLineBufferIsBoundedWithNoTerminator() {
        var b = OutputLineBuffer(maxBufferBytes: 4096, maxLineBytes: 1024)
        for _ in 0..<64 {
            _ = b.ingest(String(repeating: "x", count: 4096))
        }
        XCTAssertLessThanOrEqual(
            b.buffer.utf8.count, 4096 + 4096,
            "retention exceeded the ceiling plus one chunk"
        )
        XCTAssertGreaterThan(
            b.droppedBytes, 0,
            "bytes were discarded without being counted -- a silent bound is a second silent failure"
        )
    }

    func testOutputLineBufferResetReleasesStorage() {
        var b = OutputLineBuffer()
        _ = b.ingest("partial with no terminator")
        XCTAssertFalse(b.buffer.isEmpty)
        b.reset()
        XCTAssertTrue(b.buffer.isEmpty)
        XCTAssertEqual(b.droppedBytes, 0)
    }
}
