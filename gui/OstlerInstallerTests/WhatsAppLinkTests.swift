// WhatsAppLinkTests.swift
//
// v1.0.103: in-app WhatsApp linking on the install-complete screen.
//
// RED ON MAIN: `testTheCompletionScreenOffersInAppLinking` fails against
// main's InstallCompleteView (it only ever pointed at a Terminal command),
// and the rest of this file does not compile there because the types it
// exercises do not exist.
//
// What is pinned, and why each one is here:
//   * the three readers against the SHAPES their writers actually emit
//     (install.sh's [channels.whatsapp] echo lines, the daemon's
//     write_pair_code_state format string, wa-rs's `device.pn` column);
//   * the phase function, including the two ways a stale code could be
//     shown with confidence (a pre-restart file, a code under 5 s);
//   * every phase renders, and with OSTLER_SNAPSHOT_DIR set the renders are
//     written out as PNGs for review.

import XCTest
import SwiftUI
import SQLite3
@testable import OstlerInstaller

final class WhatsAppLinkTests: XCTestCase {

    // MARK: - Wiring

    func testTheCompletionScreenOffersInAppLinking() throws {
        let url = try StringsCatalogueEmDashTest.repoFile(
            relative: "gui/OstlerInstaller/Views/InstallCompleteView.swift")
        let src = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(src.contains("WhatsAppLinkSection()"),
            "The install-complete screen must carry the Connect WhatsApp step; without it the only way to link is a Terminal command and a pair code that expired during install.")
    }

    func testTheKickstartTargetsTheLabelInstallShipsTheAssistantUnder() throws {
        let url = try StringsCatalogueEmDashTest.repoFile(relative: "install.sh")
        let sh = try String(contentsOf: url, encoding: .utf8)
        let label = WhatsAppLinkIO.live().assistantLabel
        XCTAssertTrue(sh.contains(label),
            "install.sh no longer mentions \(label); a kickstart of it would restart nothing and no new code would ever arrive.")
    }

    func testInstallShStillWritesTheKeysTheConfigReaderUses() throws {
        let url = try StringsCatalogueEmDashTest.repoFile(relative: "install.sh")
        let sh = try String(contentsOf: url, encoding: .utf8)
        for needle in ["echo \"[channels.whatsapp]\"",
                       "echo \"enabled = true\"",
                       "echo \"session_path = ",
                       "echo \"pair_phone = "] {
            XCTAssertTrue(sh.contains(needle), "install.sh no longer emits \(needle)")
        }
    }

    // MARK: - Config reader

    private let installShapedConfig = """
    [channels.imessage]
    enabled = true

    [channels.whatsapp]
    enabled = true
    mode = "personal"
    session_path = "/opt/ostler-test/state/whatsapp-session.db"
    pair_phone = "447700900123"
    allowed_numbers = ["+447700900123"]

    [gateway]
    port = 8000
    """

    func testConfigWithPairPhoneIsTheCodeFlow() {
        XCTAssertEqual(WhatsAppConfig.parse(configTOML: installShapedConfig),
                       .pairCode(sessionPath: "/opt/ostler-test/state/whatsapp-session.db"))
    }

    func testConfigWithoutPairPhoneCannotShowACode() {
        let cfg = installShapedConfig.replacingOccurrences(of: "pair_phone = \"447700900123\"\n", with: "")
        XCTAssertEqual(WhatsAppConfig.parse(configTOML: cfg),
                       .enabledWithoutPhone(sessionPath: "/opt/ostler-test/state/whatsapp-session.db"))
    }

    func testConfigWithoutTheBlockOrDisabledIsHidden() {
        XCTAssertEqual(WhatsAppConfig.parse(configTOML: "[channels.imessage]\nenabled = true\n"), .notEnabled)
        let off = installShapedConfig.replacingOccurrences(
            of: "[channels.whatsapp]\nenabled = true", with: "[channels.whatsapp]\nenabled = false")
        XCTAssertEqual(WhatsAppConfig.parse(configTOML: off), .notEnabled)
    }

    func testKeysUnderALaterTableAreNotReadAsWhatsApp() {
        let cfg = "[channels.whatsapp]\nenabled = true\n[other]\nsession_path = \"/x\"\npair_phone = \"1\"\n"
        XCTAssertEqual(WhatsAppConfig.parse(configTOML: cfg), .notEnabled,
                       "a session_path from another table must not enable the section")
    }

    // MARK: - Pair file reader

    /// Byte-for-byte the shape ostler-assistant's write_pair_code_state emits
    /// (crates/zeroclaw-channels/src/whatsapp_web.rs, format! string).
    private func daemonFile(code: String, requested: Int, validity: Int) -> Data {
        let s = "{\n  \"code\": \"\(code)\",\n  \"requested_at\": \(requested),\n  \"expires_at\": \(requested + validity),\n  \"validity_secs\": \(validity)\n}\n"
        return Data(s.utf8)
    }

    func testALiveDaemonCodeIsShown() {
        let f = daemonFile(code: "ABCD2345", requested: 1000, validity: 180)
        XCTAssertEqual(WhatsAppPairCode.parse(data: f, now: 1010),
                       .live(code: "ABCD2345", requestedAt: 1000, expiresAt: 1180))
    }

    func testACodeUnderFiveSecondsIsExpiredNotShown() {
        let f = daemonFile(code: "ABCD2345", requested: 1000, validity: 180)
        XCTAssertEqual(WhatsAppPairCode.parse(data: f, now: 1176), .expired(requestedAt: 1000))
        XCTAssertEqual(WhatsAppPairCode.parse(data: f, now: 1174),
                       .live(code: "ABCD2345", requestedAt: 1000, expiresAt: 1180))
    }

    func testNoFileAndBadFilesAreDistinct() {
        XCTAssertEqual(WhatsAppPairCode.parse(data: nil, now: 0), .notRequested)
        XCTAssertEqual(WhatsAppPairCode.parse(data: Data("{".utf8), now: 0), .unreadable)
        XCTAssertEqual(WhatsAppPairCode.parse(data: Data(#"{"code":"","expires_at":9}"#.utf8), now: 0), .unreadable)
        XCTAssertEqual(WhatsAppPairCode.parse(data: Data(#"{"code":"ABCD2345","expires_at":true}"#.utf8), now: 0), .unreadable)
    }

    func testTheCodeIsShownAsWhatsAppAsksForIt() {
        XCTAssertEqual(WhatsAppPairCode.display("ABCD2345"), "ABCD-2345")
    }

    // MARK: - Linked reader (wa-rs device table)

    private func makeSessionDB(pn: String?) throws -> String {
        let path = NSTemporaryDirectory() + "wa-session-\(UUID().uuidString).db"
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        // Column subset of ostler-assistant whatsapp_storage.rs `device`.
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE device (id INTEGER PRIMARY KEY, lid TEXT, pn TEXT, registration_id INTEGER)", nil, nil, nil), SQLITE_OK)
        let value = pn.map { "'\($0)'" } ?? "NULL"
        XCTAssertEqual(sqlite3_exec(db, "INSERT INTO device (id, lid, pn, registration_id) VALUES (1, NULL, \(value), 7)", nil, nil, nil), SQLITE_OK)
        return path
    }

    func testAnUnpairedDeviceRowIsNotLinked() throws {
        // What the daemon writes at first boot, before the phone confirms:
        // measured on macstudio, 1 device row, 0 with a pn.
        let path = try makeSessionDB(pn: nil)
        XCTAssertEqual(WhatsAppSession.linkedState(sessionPath: path), .notLinked)
    }

    func testADeviceRowWithAPhoneJidIsLinked() throws {
        let path = try makeSessionDB(pn: "447700900123@s.whatsapp.net")
        XCTAssertEqual(WhatsAppSession.linkedState(sessionPath: path), .linked)
    }

    func testMissingAndUnreadableSessionsAreNotConfused() throws {
        XCTAssertEqual(WhatsAppSession.linkedState(sessionPath: "/nonexistent/\(UUID().uuidString).db"), .notLinked)
        let junk = NSTemporaryDirectory() + "wa-junk-\(UUID().uuidString).db"
        try Data("not a database at all, just bytes".utf8).write(to: URL(fileURLWithPath: junk))
        XCTAssertEqual(WhatsAppSession.linkedState(sessionPath: junk), .cannotTell,
                       "a file we could not read must not be reported as 'not linked'")
    }

    // MARK: - Phase

    private let cfg = WhatsAppConfig.pairCode(sessionPath: "/x")

    private func phase(pair: WhatsAppPairCode, now: Int = 2000, linked: WhatsAppLinkedState = .notLinked,
                       skipped: Bool = false, started: Int? = nil, timedOut: Bool = false,
                       config: WhatsAppConfig? = nil) -> WhatsAppLinkPhase {
        WhatsAppLinkPhase.derive(config: config ?? cfg, linked: linked, pair: pair, now: now,
                                 skipped: skipped, requestStartedAt: started, requestTimedOut: timedOut)
    }

    func testNotChosenIsHiddenAndNoNumberSaysSo() {
        XCTAssertEqual(phase(pair: .notRequested, config: .notEnabled), .hidden)
        XCTAssertEqual(phase(pair: .notRequested, config: .enabledWithoutPhone(sessionPath: "/x")), .noPhoneNumber)
    }

    func testNothingOnDiskOffersAButton() {
        XCTAssertEqual(phase(pair: .notRequested), .ready)
    }

    func testAFirstBootCodeStillAliveIsShown() {
        XCTAssertEqual(phase(pair: .live(code: "ABCD2345", requestedAt: 1990, expiresAt: 2170)),
                       .showing(code: "ABCD2345", secondsLeft: 170))
    }

    func testAPreRestartCodeIsNotShownAfterAskingForANewOne() {
        // The kickstart supersedes the old code; showing it would have the
        // customer type a code the daemon no longer holds.
        XCTAssertEqual(phase(pair: .live(code: "OLDC0DE1", requestedAt: 1990, expiresAt: 2170), started: 2000),
                       .requesting)
    }

    func testTheNewCodeIsShownOnceItLands() {
        XCTAssertEqual(phase(pair: .live(code: "NEWC0DE2", requestedAt: 2003, expiresAt: 2183), now: 2004, started: 2000),
                       .showing(code: "NEWC0DE2", secondsLeft: 179))
    }

    func testTheNewCodeAgingOutOffersAnotherAndATimeoutSaysSo() {
        XCTAssertEqual(phase(pair: .expired(requestedAt: 2003), now: 2200, started: 2000), .expired)
        XCTAssertEqual(phase(pair: .notRequested, now: 2061, started: 2000, timedOut: true), .failed)
    }

    func testLinkedWinsOverEverythingAndSkipIsHonoured() {
        XCTAssertEqual(phase(pair: .live(code: "ABCD2345", requestedAt: 1990, expiresAt: 2170), linked: .linked), .linked)
        XCTAssertEqual(phase(pair: .notRequested, linked: .linked, skipped: true), .linked)
        XCTAssertEqual(phase(pair: .notRequested, skipped: true), .skipped)
    }

    // MARK: - Every phase renders, and the copy exists

    func testEveryPhaseHasItsCopy() {
        for key in ["title", "intro", "get_code_button", "requesting", "steps_heading", "step1", "step2",
                    "step3", "expires_in", "waiting", "expired", "new_code_button", "failed",
                    "try_again_button", "linked", "skip_button", "skipped", "connect_now_button",
                    "no_phone", "later_command"] {
            let s = ViewCopy.shared.string(for: "whatsapp_link.\(key)")
            XCTAssertNotEqual(s, "whatsapp_link.\(key)", "missing copy for \(key)")
            XCTAssertFalse(s.contains("\u{2014}") || s.contains("\u{2013}"), "no em or en dash in \(key)")
            XCTAssertFalse(s.lowercased().contains("recording"), "say transcribing, not recording: \(key)")
        }
    }

    @MainActor
    func testEveryPhaseRenders() throws {
        let phases: [(String, WhatsAppLinkPhase)] = [
            ("1-ready", .ready),
            ("2-requesting", .requesting),
            ("3-showing", .showing(code: "ABCD2345", secondsLeft: 164)),
            ("4-expired", .expired),
            ("5-failed", .failed),
            ("6-linked", .linked),
            ("7-skipped", .skipped),
            ("8-no-phone", .noPhoneNumber),
        ]
        let outDir = ProcessInfo.processInfo.environment["OSTLER_SNAPSHOT_DIR"]
        for (name, p) in phases {
            let view = WhatsAppLinkSection(previewPhase: p)
                .padding(24)
                .frame(width: 620, alignment: .topLeading)
                .background(Color.ostlerChassis)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.cgImage, "phase \(name) did not render")
            XCTAssertGreaterThan(image.height, 60, "phase \(name) rendered empty")
            if let dir = outDir {
                let rep = NSBitmapImageRep(cgImage: image)
                let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("whatsapp-link-\(name).png"))
            }
        }
    }
}
