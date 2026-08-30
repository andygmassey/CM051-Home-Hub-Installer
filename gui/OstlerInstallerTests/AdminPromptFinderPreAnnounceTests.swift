// AdminPromptFinderPreAnnounceTests.swift
//
// Task #361 regression tests (clean v1.0.52 walk, 2026-08-30).
//
// Andy hit this live on the first genuinely clean-machine walk. macOS
// raised:
//
//   LARGE: "OstlerInstaller" wants access to control "Finder".
//          Allowing control will provide access to documents and data
//          in "Finder", and to perform actions within that app.
//   grey:  Ostler needs to ask for your administrator password to
//          install Hub services.
//
// and his verdict was "that's not great wording, though....".
//
// He is right, and the reason it cannot be fixed where you would first
// reach for it is the point of this file:
//
//   WE NEVER ASK FOR FINDER.
//
// AuthorizationHelper.swift issues a bare
//
//     do shell script "<inner>" with prompt "<p>" with administrator privileges
//
// with no `tell application "Finder"` anywhere in the app target.
// macOS names Finder itself, because the app was launched from Finder.
// So NSAppleEventsUsageDescription (the grey line) CANNOT honestly be
// written to explain the large line -- any wording we put there would
// be describing a request we did not make, and it renders BELOW the
// alarming sentence anyway.
//
// The fix that fits a cut is therefore to PRE-ANNOUNCE on our own
// screen, immediately before, so the customer meets the odd sentence
// as something expected rather than as an accusation. That is the
// "pre-announce does not land" half of #361.
//
// Why this matters more than an ordinary copy nit: Ostler's entire
// pitch is that your data stays on your Mac. "Allowing control will
// provide access to documents and data" is the worst possible sentence
// to show, unexplained, in the first minute of first run. It is a
// first-impression defect, which is a different and arguably worse
// category than a functional one -- the install itself proceeds fine.
//
// 🔵 SUCCESSOR, NOT COVERED HERE: the real fix is to stop escalating
// via AppleScript at all and use a privileged helper
// (ServiceManagement / SMJobBless). Then there is no Apple Event, no
// TCC prompt, and no sentence to explain. Tracked on #361 as the
// v1.0.1 option. If that lands, THESE TESTS SHOULD BE DELETED, not
// worked around -- their whole subject will have ceased to exist.
//
// ⚠️ DO NOT "simplify" AuthorizationHelper back to shelling out to
// /usr/bin/osascript. Studio retest #7 (2026-05-22) found that made
// the admin dialog credit "osascript" rather than Ostler; the
// in-process NSAppleScript path is itself the fix for that, and is
// pinned by AdminAuthorizationGateTests.

import Foundation
import XCTest
@testable import OstlerInstaller

final class AdminPromptFinderPreAnnounceTests: XCTestCase {

    /// Load ViewCopy.json from the repo and return the parsed
    /// `admin_access_required` block.
    ///
    /// Deliberately parses rather than greps. Editing prose inside a
    /// JSON file is a code change: a trailing comma or an unescaped
    /// quote turns the whole catalogue into a parse error that a
    /// substring search would sail straight past, reporting the copy
    /// as present in a file the app can no longer load.
    private func loadAdminBlock() throws -> [String: String] {
        let url = try StringsCatalogueEmDashTest.repoFile(
            relative: "gui/OstlerInstaller/Resources/ViewCopy.json"
        )
        let data = try Data(contentsOf: url)
        guard let root = try JSONSerialization.jsonObject(with: data)
                as? [String: Any] else {
            throw XCTSkip("ViewCopy.json did not parse as a JSON object")
        }
        guard let block = root["admin_access_required"] as? [String: String] else {
            XCTFail("ViewCopy.json has no admin_access_required block")
            return [:]
        }
        return block
    }

    /// CONTROL, and it must be non-vacuous.
    ///
    /// Every assertion below is of the form "this string contains X".
    /// If the block were missing, empty, or renamed, those would all
    /// fail for a reason that has nothing to do with the pre-announce
    /// -- and a maintainer reading the failure would go looking for a
    /// copy regression that was not there. This arm proves the subject
    /// exists before the others interrogate it.
    func testAdminBlockExistsAndIsPopulated() throws {
        let block = try loadAdminBlock()
        XCTAssertGreaterThanOrEqual(
            block.count, 5,
            "admin_access_required should carry the full screen's copy; got \(block.count) keys"
        )
        for key in ["reassurance", "requesting_status", "continue_button"] {
            let value = block[key] ?? ""
            XCTAssertFalse(
                value.isEmpty,
                "admin_access_required.\(key) must be non-empty -- an empty string would satisfy no assertion here and silently remove the pre-announce"
            )
        }
    }

    /// THE REGRESSION ITSELF.
    ///
    /// Pre-fix, `reassurance` read:
    ///
    ///   "Your password stays on this Mac, never sent anywhere.
    ///    macOS will ask for it on the next screen."
    ///
    /// Truthful, and useless against the actual dialog: it promises a
    /// password request and macOS then says "control Finder ...
    /// documents and data". This test fails on that exact string,
    /// which is what makes it a regression test rather than a
    /// restatement of the current copy.
    func testReassuranceWarnsAboutTheFinderWordingBeforeItAppears() throws {
        let block = try loadAdminBlock()
        let reassurance = block["reassurance"] ?? ""

        XCTAssertTrue(
            reassurance.contains("Finder"),
            """
            admin_access_required.reassurance MUST name Finder before macOS does. \
            The customer is about to be told Ostler "wants access to control Finder" \
            and that this "will provide access to documents and data". If our screen \
            has not already said that is coming, the OS sentence reads as an \
            accusation we failed to disclose. Got: \(reassurance)
            """
        )

        // Naming Finder is not enough on its own -- a string could
        // mention Finder and still leave the documents-and-data
        // accusation unanswered. The copy has to actually rebut it.
        let lower = reassurance.lowercased()
        XCTAssertTrue(
            lower.contains("does not read your files")
                || lower.contains("not a request for your files")
                || (lower.contains("documents") && lower.contains("not")),
            """
            admin_access_required.reassurance must REBUT the documents-and-data \
            claim, not merely mention Finder. macOS's sentence is the one the \
            customer will remember; ours has to answer it in the same breath. \
            Got: \(reassurance)
            """
        )

        // The wording is macOS's, and saying so is the honest move --
        // it is also the only accurate one, since the app never
        // requests Finder.
        XCTAssertTrue(
            lower.contains("macos"),
            "reassurance must attribute the odd phrasing to macOS, because that is whose phrasing it is -- the app never asks for Finder. Got: \(reassurance)"
        )
    }

    /// The status line shown WHILE the dialog is up.
    ///
    /// The pre-announce on the previous screen can be missed or
    /// forgotten by the time the sheet appears, so the live status
    /// line has to carry it too. Pre-fix this read "A macOS password
    /// dialog will appear in a moment", which again describes a
    /// dialog the customer is not the one they see.
    func testRequestingStatusAlsoNamesFinder() throws {
        let block = try loadAdminBlock()
        let status = block["requesting_status"] ?? ""
        XCTAssertTrue(
            status.contains("Finder"),
            """
            admin_access_required.requesting_status must also name Finder. This is \
            the line on screen WHILE the macOS sheet is up, so it is the customer's \
            last chance to reconcile what they were promised with what they are \
            reading. Got: \(status)
            """
        )
    }

    /// House style, scoped to the strings this fix touches.
    ///
    /// StringsCatalogueEmDashTest covers the shell catalogue; this
    /// block lives in JSON and is not in that file's denominator.
    func testPreAnnounceCopyCarriesNoEmDashes() throws {
        let block = try loadAdminBlock()
        for (key, value) in block {
            XCTAssertFalse(
                value.contains("\u{2014}") || value.contains("\u{2013}"),
                "admin_access_required.\(key) contains an em or en dash, which is against house style. Got: \(value)"
            )
        }
    }
}
