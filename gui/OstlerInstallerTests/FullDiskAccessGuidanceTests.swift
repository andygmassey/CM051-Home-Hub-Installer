// FullDiskAccessGuidanceTests.swift
//
// 118 MUST F008/F009. Injected seams only: no real TCC, no real open of
// a protected file, no Finder.

import Foundation
import XCTest
@testable import OstlerInstaller

final class FullDiskAccessGuidanceTests: XCTestCase {

    func testProbeReadHappensBeforeAccessCheckAndStep() {
        var order: [String] = []
        let needed = FullDiskAccessGuidance.gateNeeded(
            register: { order.append("register") },
            hasAccess: { order.append("hasAccess"); return false }
        )
        XCTAssertEqual(order, ["register", "hasAccess"])
        XCTAssertTrue(needed)
    }

    func testProbeOpensMessagesDbUnderGivenHome() {
        var opened: [String] = []
        FullDiskAccessGuidance.registerInList(home: "/Users/example", open: { opened.append($0) })
        XCTAssertEqual(opened, ["/Users/example/Library/Messages/chat.db"])
    }

    func testPaneURLIsPrivacyAllFiles() {
        XCTAssertEqual(
            FullDiskAccessGuidance.paneURLString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
    }

    func testTranslocatedPathDetected() {
        XCTAssertTrue(FullDiskAccessGuidance.isTranslocated(
            bundlePath: "/private/var/folders/ab/xyz/T/AppTranslocation/1234-ABCD/d/OstlerInstaller.app"))
        XCTAssertFalse(FullDiskAccessGuidance.isTranslocated(
            bundlePath: "/Applications/OstlerInstaller.app"))
        XCTAssertFalse(FullDiskAccessGuidance.isTranslocated(
            bundlePath: "/Volumes/Ostler/OstlerInstaller.app"))
    }

    func testShowInFinderRevealsRunningBundle() {
        var revealed: [URL] = []
        let url = URL(fileURLWithPath: "/Applications/OstlerInstaller.app")
        FullDiskAccessGuidance.revealRunningBundle(bundleURL: url, reveal: { revealed = $0 })
        XCTAssertEqual(revealed, [url])
    }

    func testCopyCarriesFallbackForGateAndSheet() throws {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("OstlerInstaller/Resources/ViewCopy.json")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as! [String: Any]
        for group in ["fda_gate", "fda_sheet"] {
            let g = json[group] as! [String: String]
            let fb = try XCTUnwrap(g["fallback"])
            XCTAssertTrue(fb.contains("click +"))
            XCTAssertTrue(fb.contains("Applications folder"))
            XCTAssertEqual(g["show_in_finder_button"], "Show in Finder")
            XCTAssertNotNil(g["translocated_note"])
        }
    }

    func testGateWiresProbeBeforeCheck() throws {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("OstlerInstaller/InstallerCoordinator.swift")
        let src = try String(contentsOf: path)
        XCTAssertTrue(src.contains("FullDiskAccessGuidance.gateNeeded("))
    }
}
