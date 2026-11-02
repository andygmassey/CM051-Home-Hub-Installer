// LightAppearancePinTests.swift
//
// The installer is drawn in the light brand palette only. A tester on a
// dark-mode Mac (2 Nov 2026) saw every text field white on cream, and the
// consent screen's Cancel became the only working button. The fix pins
// NSApp to Aqua in applicationWillFinishLaunching.

import AppKit
import XCTest
@testable import OstlerInstaller

final class LightAppearancePinTests: XCTestCase {
    private var saved: NSAppearance?

    override func setUp() {
        super.setUp()
        saved = NSApplication.shared.appearance
    }

    override func tearDown() {
        NSApplication.shared.appearance = saved
        super.tearDown()
    }

    /// THE TEST: from darkAqua, the delegate's launch hook leaves the app
    /// on Aqua. (Mutant: make applicationWillFinishLaunching a no-op and
    /// this goes RED, because the control below puts the app in darkAqua.)
    func testLaunchHookPinsAquaEvenWhenTheSystemIsDark() {
        let app = NSApplication.shared
        app.appearance = NSAppearance(named: .darkAqua)
        // Control: the starting state really is dark, so a pass below is
        // not the default appearance answering.
        XCTAssertEqual(
            app.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]),
            .darkAqua
        )
        InstallerAppDelegate().applicationWillFinishLaunching(
            Notification(name: NSApplication.willFinishLaunchingNotification)
        )
        XCTAssertEqual(app.appearance?.name, .aqua)
        XCTAssertEqual(
            app.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]),
            .aqua
        )
    }
}

/// The consent screen's Cancel used to end the install on one click. It now
/// asks first; only the dialog's Stop install sends the cancel sentinel.
final class ConsentCancelAsksFirstTests: XCTestCase {
    func testCancelOpensADialogAndOnlyStopInstallSendsTheSentinel() throws {
        let url = try StringsCatalogueEmDashTest.repoFile(
            relative: "gui/OstlerInstaller/Views/OnboardingQuestionView.swift"
        )
        let src = try String(contentsOf: url, encoding: .utf8)
        let sends = src.components(
            separatedBy: "coordinator.respond(to: q.prompt, with: cancelSentinel)"
        ).count - 1
        XCTAssertEqual(sends, 1, "exactly one place may send the cancel sentinel")
        guard let dialog = src.range(of: ".confirmationDialog("),
              let stop = src.range(of: "consent_install_cancel_confirm_stop"),
              let send = src.range(of: "with: cancelSentinel)")
        else {
            return XCTFail("the Cancel confirmation dialog is gone")
        }
        // The one send sits inside the dialog's Stop install button.
        XCTAssertTrue(dialog.lowerBound < stop.lowerBound && stop.lowerBound < send.lowerBound)
        XCTAssertTrue(src.contains("confirmingConsentCancel = true"))
    }
}
