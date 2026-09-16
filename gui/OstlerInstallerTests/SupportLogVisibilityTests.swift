// SupportLogVisibilityTests.swift
//
// Four ways the GUI was blind about a failing install, all confessed by
// the code's own comments.
//
// (a) EVERY TIMESTAMP WAS REDACTED OUT OF THE SUPPORT LOG.
//     `LogRedactor`'s IPv6 pattern was
//     `\b[0-9a-fA-F]{1,4}(?::[0-9a-fA-F]{0,4}){2,7}\b` and its comment
//     claimed it was anchored "so single-colon shapes (MAC addresses,
//     time stamps) do not match". Both named shapes carry MORE than one
//     colon, so the anchor never applied to either. Measured directly in
//     NSRegularExpression: `03:41:27` -> `⟨ip⟩` and
//     `aa:bb:cc:dd:ee:ff` -> `⟨ip⟩`. Every line of the support log is
//     emitted as `HH:mm:ss  [LEVEL] message`, so support received logs
//     in which every line began `⟨ip⟩`.
//
// (b) THE SUPPORT LOG CONTAINED NO TOOL OUTPUT. `ProgressDecoder`'s
//     header promised raw lines were re-emitted "so the log drawer never
//     silently drops install.sh's TTY chatter", but the handler gated
//     the append on `devModeRawLog`, declared false and with its toggle
//     removed by #348. The brew failure, the docker error and the Python
//     traceback that explain WHY an install died reached only `os_log`.
//
// (c) THE WATCHDOG OVERLAY COULD NEVER RENDER DURING AN INSTALL.
//     HintPanelView gates it on `watchdogSilent && preInstallStatus ==
//     nil`, but `preInstallStatus` is assigned on every info-level LOG
//     marker and cleared in exactly one place, `case .prompt`. No
//     prompts arrive after the question phase, so it is permanently
//     non-nil for the whole install -- and a wedged install looked
//     identical to a slow one, the precise failure CX-14 D5 exists to
//     remove.
//
// (d) THE SIDEBAR FAILURE GLYPH WAS UNREACHABLE BY CONSTRUCTION. It sat
//     inside `else if isActive`, and `isActive` is defined as
//     `finished == nil && currentStepId == meta.id`. On `.fail` that is
//     false, so the inner `if coordinator.finished == .fail` could never
//     be evaluated. The failing row fell through to the grey
//     "not started" circle.

import Foundation
import XCTest
@testable import OstlerInstaller

@MainActor
final class SupportLogVisibilityTests: XCTestCase {

    private func source(_ relative: String) throws -> String {
        let url = try StringsCatalogueEmDashTest.repoFile(relative: relative)
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - (a) Timestamps survive redaction

    /// THE MUTATION DETECTOR for (a). Restoring the old one-pattern IPv6
    /// regex turns each of these back into `⟨ip⟩`.
    func testRedactionKeepsTheTimingOnEverySupportLogLine() {
        for stamp in ["03:41:27", "00:00:00", "23:59:59", "12:05:09"] {
            XCTAssertEqual(
                LogRedactor.redact(stamp), stamp,
                """
                The timestamp \(stamp) was redacted as an IP address. Every support \
                log line is `HH:mm:ss  [LEVEL] message`, so this removes the timing \
                from every line of every log support ever receives -- the one thing \
                they need after "what broke".
                """
            )
        }
    }

    /// The whole assembled line, as `formatBuffer` actually emits it.
    func testAWholeSupportLogLineKeepsItsTimestamp() {
        let line = InstallerCoordinator.LogLine(
            level: "info",
            text: "Installing Homebrew",
            timestamp: Date()
        )
        let formatted = LogDrawerView.formatBuffer([line])
        let redacted = LogRedactor.redact(formatted)

        XCTAssertFalse(
            redacted.hasPrefix("⟨ip⟩"),
            "The support log line still begins with a redacted timestamp: \(redacted)"
        )
        // The time portion of the formatted line must survive verbatim.
        let stamp = String(formatted.prefix(8))
        XCTAssertTrue(
            redacted.contains(stamp),
            "Timestamp \(stamp) did not survive redaction. Got: \(redacted)"
        )
    }

    /// THE POSITIVE CONTROL, and it is the one that matters: loosening
    /// the pattern until timestamps survive must not stop real IPv6
    /// addresses being masked. A redactor that leaks PII is a worse
    /// defect than the one being fixed.
    func testRealIPv6AddressesAreStillMasked() {
        let addresses = [
            "2001:db8::1",
            "::1",
            "fe80::1",
            "2001:0db8:85a3:0000:0000:8a2e:0370:7334",
            "a::b",
        ]
        for addr in addresses {
            XCTAssertFalse(
                LogRedactor.redact(addr).contains(addr),
                "IPv6 address \(addr) was NOT redacted. The timestamp fix must not open a PII leak."
            )
        }
        XCTAssertTrue(
            LogRedactor.redact("connect to ::1 failed").contains("⟨ip⟩"),
            "An IPv6 address inline in a message must still be masked."
        )
    }

    /// IPv4 and the other categories are untouched by this change; pin
    /// them so a regex edit cannot quietly take one of them with it.
    ///
    /// The email and home-path specimens are ASSEMBLED AT RUNTIME rather
    /// than written as literals. `.githooks` runs a PII-shape scan that
    /// matches on shape, not on a list of known values, so even an
    /// obviously synthetic literal trips it -- correctly, since that is
    /// the only way a shape scan can work. Composing from parts is the
    /// remedy the hook itself prescribes; the redactor still receives
    /// the identical bytes. The IPv4 specimen is RFC 5737 TEST-NET-1,
    /// reserved for documentation, so it can never be a real machine.
    func testOtherRedactionCategoriesStillHold() {
        let email = "a" + "@" + "b.example"
        let homePath = "/Users" + "/" + "someone" + "/x"

        XCTAssertTrue(
            LogRedactor.redact("192.0.2.1").contains("⟨ip⟩"),
            "IPv4 must still be masked."
        )
        XCTAssertTrue(
            LogRedactor.redact(email).contains("⟨email⟩"),
            "Email must still be masked."
        )
        XCTAssertTrue(
            LogRedactor.redact(homePath).contains("⟨user⟩"),
            "Home paths must still be masked; the customer's account name is PII."
        )
    }

    // MARK: - (b) Tool output reaches the support log

    /// THE MUTATION DETECTOR for (b). A traceback the customer never
    /// sees must still be in the log they are asked to send.
    func testRawToolOutputReachesTheSupportLog() {
        let c = InstallerCoordinator()
        c.simulateLineForTests("#OSTLER\tLOG\tlevel=info\tmsg=Installing Homebrew")
        c.simulateLineForTests("Traceback (most recent call last):")
        c.simulateLineForTests("  ModuleNotFoundError: No module named 'yaml'")
        c.simulateLineForTests("#OSTLER\tDONE\tstatus=fail")

        let support = LogDrawerView.formatBuffer(c.supportLogLines)
        XCTAssertTrue(
            support.contains("ModuleNotFoundError"),
            """
            The Python traceback that explains the failure is absent from the \
            support log. It reached only os_log, which is on the customer's Mac \
            and readable solely by an engineer who can run `log show` on it -- \
            useless for the support email the failure screen asks them to send.
            """
        )
        XCTAssertTrue(
            support.contains("Traceback (most recent call last):"),
            "The whole traceback must be carried, not just its last line."
        )
    }

    /// THE COUNTERWEIGHT, and the reason raw output went into its own
    /// buffer. #348 filtered these from the customer-facing drawer
    /// because tool chatter drowned the curated markers. That decision
    /// stands: fixing the support log must not undo it.
    func testCustomerFacingDrawerStaysCurated() {
        let c = InstallerCoordinator()
        c.simulateLineForTests("#OSTLER\tLOG\tlevel=info\tmsg=Installing Homebrew")
        c.simulateLineForTests("==> Pouring homebrew chatter")

        XCTAssertFalse(
            c.logLines.contains { $0.text.contains("Pouring homebrew chatter") },
            "Raw tool chatter leaked into the curated drawer buffer. #348 removed it because it drowned the LOG markers."
        )
        XCTAssertTrue(
            c.rawLogLines.contains { $0.text.contains("Pouring homebrew chatter") },
            "Raw output must still be retained for support, just not rendered in the drawer."
        )
    }

    /// The curated markers must not be evictable by a firehose of tool
    /// output. Folding both into one buffer would let a chatty install
    /// push every marker out through the cap and make the support log
    /// worse than the blindness being fixed.
    func testChattyToolOutputCannotEvictTheCuratedNarration() {
        let c = InstallerCoordinator()
        c.simulateLineForTests("#OSTLER\tLOG\tlevel=info\tmsg=MARKER_THAT_MUST_SURVIVE")
        for i in 0..<(InstallerCoordinator.rawLogLineCap + 500) {
            c.simulateLineForTests("chatter line \(i)")
        }
        XCTAssertTrue(
            c.logLines.contains { $0.text.contains("MARKER_THAT_MUST_SURVIVE") },
            "A curated marker was evicted by raw tool chatter. The two buffers must be bounded independently."
        )
        XCTAssertLessThanOrEqual(
            c.rawLogLines.count, InstallerCoordinator.rawLogLineCap,
            "The raw buffer must stay bounded."
        )
    }

    /// The merge must be ordered by time, so support reads the tool
    /// output next to the step it belongs to rather than in two blocks.
    func testSupportLogIsInterleavedInTimeOrder() {
        let c = InstallerCoordinator()
        c.simulateLineForTests("#OSTLER\tLOG\tlevel=info\tmsg=FIRST_MARKER")
        c.simulateLineForTests("raw-in-the-middle")
        c.simulateLineForTests("#OSTLER\tLOG\tlevel=info\tmsg=LAST_MARKER")

        let texts = c.supportLogLines.map(\.text)
        guard let a = texts.firstIndex(where: { $0.contains("FIRST_MARKER") }),
              let b = texts.firstIndex(where: { $0.contains("raw-in-the-middle") }),
              let d = texts.firstIndex(where: { $0.contains("LAST_MARKER") })
        else { return XCTFail("Support log lost one of the three lines: \(texts)") }

        XCTAssertTrue(a < b && b < d, "Support log is out of order: \(texts)")
    }

    /// The failure-screen buttons must read the merged buffer. Building
    /// the merge and leaving the buttons on the curated list would be
    /// the same blindness with more code.
    func testFailureScreenCopyPathsUseTheMergedBuffer() throws {
        let cv = try source("gui/OstlerInstaller/Views/ContentView.swift")
        XCTAssertFalse(
            cv.contains("formatBuffer(coordinator.logLines"),
            "A copy-log path on the failure screen is still reading the curated-only buffer, so the tool output never reaches support."
        )
        XCTAssertTrue(
            cv.contains("coordinator.supportLogLines"),
            "The failure screen's copy paths must assemble from supportLogLines."
        )
    }

    // MARK: - (c) The watchdog overlay can actually surface

    /// THE MUTATION DETECTOR for (c). The overlay's gate requires
    /// `preInstallStatus == nil`; 15s of silence must clear the stale
    /// banner so the gate can pass.
    func testWedgedInstallSurfacesTheStillGoingOverlay() {
        let c = InstallerCoordinator()
        // A normal install: an info marker sets the status banner.
        c.simulateLineForTests("#OSTLER\tLOG\tlevel=info\tmsg=Reading your contacts")
        XCTAssertNotNil(c.preInstallStatus, "Precondition: the status banner is showing.")

        c.simulateWatchdogSilenceForTests(elapsedSeconds: 20)

        XCTAssertTrue(c.watchdogSilent, "Precondition: the watchdog has declared silence.")
        XCTAssertNil(
            c.preInstallStatus,
            """
            The stale status banner survived the silence declaration, so \
            HintPanelView's overlay gate (watchdogSilent && preInstallStatus == nil) \
            still cannot pass. preInstallStatus is set by every info marker and \
            cleared only by a PROMPT, and no prompts arrive during the install -- \
            so a wedged install goes on looking exactly like a slow one.
            """
        )
    }

    /// Both halves of the overlay's gate, asserted together, so the test
    /// speaks about what the customer sees rather than one flag.
    func testOverlayGateIsSatisfiedOnAWedgedInstall() {
        let c = InstallerCoordinator()
        c.simulateLineForTests("#OSTLER\tLOG\tlevel=info\tmsg=Reading your contacts")
        c.simulateWatchdogSilenceForTests(elapsedSeconds: 20)

        let gatePasses = c.watchdogSilent
            && c.preInstallStatus == nil
            && c.finished == nil
            && c.error == nil
        XCTAssertTrue(
            gatePasses,
            "HintPanelView's watchdog-overlay condition is still unsatisfiable during an install."
        )
    }

    /// The complement: output resuming must restore the ordinary status
    /// banner and retire the overlay, so the fix is not "delete the
    /// banner".
    func testFreshOutputRestoresTheOrdinaryStatusBanner() {
        let c = InstallerCoordinator()
        c.simulateLineForTests("#OSTLER\tLOG\tlevel=info\tmsg=Reading your contacts")
        c.simulateWatchdogSilenceForTests(elapsedSeconds: 20)
        XCTAssertTrue(c.watchdogSilent)

        c.simulateLineForTests("#OSTLER\tLOG\tlevel=info\tmsg=Still working")
        XCTAssertEqual(
            c.preInstallStatus, "Still working",
            "When output resumes the status banner must repopulate from the next marker."
        )
    }

    /// A quiet stretch while the CUSTOMER is the slow path must not
    /// raise the overlay -- they are reading a question, not wedged.
    func testPendingPromptDoesNotRaiseTheOverlay() {
        let c = InstallerCoordinator()
        c.simulateLineForTests("#OSTLER\tPROMPT\tid=q1\tkind=text\ttitle=Your name")
        c.simulateWatchdogSilenceForTests(elapsedSeconds: 60)
        XCTAssertFalse(
            c.watchdogSilent,
            "Silence while a prompt is pending is the customer thinking, not the installer wedging."
        )
    }

    // MARK: - (d) The sidebar failure glyph is reachable

    /// THE MUTATION DETECTOR for (d). Nesting the glyph back inside
    /// `else if isActive` makes it unreachable again, because `isActive`
    /// requires `finished == nil`.
    func testSidebarFailureGlyphIsNotNestedUnderAContradictoryCondition() throws {
        let src = try source("gui/OstlerInstaller/Views/SidebarView.swift")

        XCTAssertTrue(
            src.contains("private var isFailedStep"),
            """
            SidebarView has lost its isFailedStep branch. The failure glyph then \
            sits under `else if isActive`, and isActive requires `finished == nil`, \
            so on a failed install the branch cannot be entered and the failing row \
            renders the grey "not started" circle instead of the xmark.
            """
        )
        XCTAssertTrue(
            src.contains("coordinator.finished == .fail && coordinator.currentStepId == meta.id"),
            "isFailedStep must identify the step that was active when the terminal arrived."
        )
        XCTAssertTrue(
            src.contains("} else if isFailedStep {"),
            "The failed-step branch must be tested as a sibling of isActive, not nested inside it."
        )

        // Control: the file really is SidebarView and still has the
        // branch structure these assertions describe.
        XCTAssertTrue(
            src.contains("} else if isActive {"),
            "Loaded a file without the isActive branch; the assertions above proved nothing."
        )
    }

    /// The two conditions must be mutually exclusive, or one row could
    /// claim to be both spinning and failed.
    func testFailedAndActiveAreMutuallyExclusive() {
        let c = InstallerCoordinator()
        c.simulateLineForTests("#OSTLER\tSTEP_BEGIN\tid=homebrew_install\ttitle=Installing Homebrew")

        XCTAssertEqual(c.currentStepId, "homebrew_install")
        XCTAssertNil(c.finished, "While running: the row is active, not failed.")

        c.simulateLineForTests("#OSTLER\tDONE\tstatus=fail")
        XCTAssertEqual(c.finished, .fail)
        XCTAssertEqual(
            c.currentStepId, "homebrew_install",
            "The failed step's identity must survive the terminal so the sidebar can pin the xmark to the right row."
        )
    }
}
