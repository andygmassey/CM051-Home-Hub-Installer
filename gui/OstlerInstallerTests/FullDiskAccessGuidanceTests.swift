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

    // MARK: - Robust probe (118 MUST: granted tester stuck on the gate)

    private typealias G = FullDiskAccessGuidance
    private let home = "/Users/example"

    private func path(_ rel: String) -> String { home + "/" + rel }

    /// Every probe denied except `readable`; `missing` ones absent.
    private func fakeRead(readable: Set<String> = [], missing: Set<String> = []) -> (String) -> G.ProbeResult {
        return { p in
            if readable.contains(p) { return .readable }
            if missing.contains(p) { return .missing }
            return .denied(EPERM)
        }
    }

    func testEachProbeAloneGrantsAccess() {
        XCTAssertEqual(G.accessProbeRelativePaths.count, 5)
        for rel in G.accessProbeRelativePaths {
            let ev = G.evaluateAccess(home: home, read: fakeRead(readable: [path(rel)]))
            XCTAssertEqual(ev.verdict, .granted, "\(rel) alone must pass")
        }
    }

    func testTccDbDeniedButAnotherReadableStillGrants() {
        // The stuck tester: TCC.db unreadable, everything else readable.
        let tcc = path(G.accessProbeRelativePaths[0])
        let ev = G.evaluateAccess(home: home, read: { $0 == tcc ? .denied(EPERM) : .readable })
        XCTAssertEqual(ev.verdict, .granted)
    }

    func testAllMissingIsUnverifiableNotDenied() {
        let ev = G.evaluateAccess(home: home, read: { _ in .missing })
        XCTAssertEqual(ev.verdict, .unverifiable)
        XCTAssertTrue(ev.failures.isEmpty)
        // Not a hard block: the escape is offered with zero rechecks.
        XCTAssertTrue(G.escapeAvailable(verdict: ev.verdict, failedRechecks: 0))
    }

    func testMissingProbesAreNotCountedAsDenials() {
        let rels = G.accessProbeRelativePaths
        let missing = Set(rels.dropFirst().map(path))
        let ev = G.evaluateAccess(home: home, read: fakeRead(missing: missing))
        XCTAssertEqual(ev.verdict, .denied)
        XCTAssertEqual(ev.failures, [G.ProbeFailure(relativePath: rels[0], errnoValue: EPERM)])
    }

    func testDeniedEverywhereShowsEscapeOnlyAfterTwoRechecks() {
        let denied = G.evaluateAccess(home: home, read: { _ in .denied(EPERM) })
        XCTAssertEqual(denied.verdict, .denied)
        XCTAssertEqual(denied.failures.count, 5)
        var state = G.GateState()
        XCTAssertFalse(state.record(denied, isRecheck: false))
        XCTAssertFalse(state.offersContinueAnyway, "first check: no escape")
        XCTAssertFalse(state.record(denied, isRecheck: true))
        XCTAssertFalse(state.offersContinueAnyway, "1 failed recheck: no escape")
        XCTAssertFalse(state.record(denied, isRecheck: true))
        XCTAssertTrue(state.offersContinueAnyway, "2 failed rechecks: escape")
        XCTAssertEqual(state.failedRechecks, 2)
    }

    func testGrantAfterFailedRechecksPasses() {
        let denied = G.evaluateAccess(home: home, read: { _ in .denied(EPERM) })
        let granted = G.evaluateAccess(home: home, read: { _ in .readable })
        var state = G.GateState()
        _ = state.record(denied, isRecheck: true)
        XCTAssertTrue(state.record(granted, isRecheck: true))
    }

    func testFailureLogCarriesPathsAndErrnoOnly() {
        let line = G.failureLogLine([
            G.ProbeFailure(relativePath: "Library/Mail", errnoValue: EPERM),
            G.ProbeFailure(relativePath: "Library/Safari/History.db", errnoValue: EACCES),
        ])
        XCTAssertEqual(line, "Library/Mail=errno1, Library/Safari/History.db=errno13")
    }

    func testRealReadProbeClassifiesMissingAndReadable() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fda-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("f.db")
        try Data([1, 2, 3]).write(to: file)
        XCTAssertEqual(G.readProbe(path: file.path), .readable)
        XCTAssertEqual(G.readProbe(path: dir.path), .readable)
        XCTAssertEqual(G.readProbe(path: dir.appendingPathComponent("nope").path), .missing)
        let empty = dir.appendingPathComponent("empty.db")
        FileManager.default.createFile(atPath: empty.path, contents: Data())
        XCTAssertEqual(G.readProbe(path: empty.path), .readable)
    }

    func testRealReadProbeReportsDeniedForUnreadableFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fda-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("locked.db")
        try Data([1]).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        if getuid() == 0 { throw XCTSkip("root reads anything") }
        XCTAssertEqual(G.readProbe(path: file.path), .denied(EACCES))
    }

    func testQuitAndReopenLaunchesApplicationsCopyThenTerminates() {
        var launched: URL?
        var terminated = false
        let installed = URL(fileURLWithPath: "/Applications/OstlerInstaller.app")
        let running = URL(fileURLWithPath: "/private/var/AppTranslocation/x/d/OstlerInstaller.app")
        let target = G.quitAndReopen(
            installedURL: installed, runningURL: running,
            exists: { _ in true },
            launch: { url, done in launched = url; XCTAssertFalse(terminated); done() },
            terminate: { terminated = true })
        XCTAssertEqual(target, installed)
        XCTAssertEqual(launched, installed)
        XCTAssertTrue(terminated)
    }

    func testQuitAndReopenFallsBackToRunningBundleWhenNotInstalled() {
        let running = URL(fileURLWithPath: "/Volumes/Ostler/OstlerInstaller.app")
        let target = G.quitAndReopen(
            installedURL: URL(fileURLWithPath: "/Applications/OstlerInstaller.app"),
            runningURL: running, exists: { _ in false },
            launch: { _, done in done() }, terminate: {})
        XCTAssertEqual(target, running)
    }

    func testGateWiringCallsRobustProbeEscapeAndRelaunch() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("OstlerInstaller")
        let coord = try String(contentsOf: root.appendingPathComponent("InstallerCoordinator.swift"))
        XCTAssertTrue(coord.contains("FullDiskAccessGuidance.evaluateAccess("))
        XCTAssertTrue(coord.contains("fdaGateState.record("))
        XCTAssertTrue(coord.contains("FullDiskAccessGuidance.quitAndReopen()"))
        let helper = try String(contentsOf: root.appendingPathComponent("Auth/AuthorizationHelper.swift"))
        XCTAssertTrue(helper.contains("FullDiskAccessGuidance.evaluateAccess("))
        XCTAssertFalse(helper.contains("com.apple.TCC/TCC.db"), "probe must not be TCC.db-only again")
        let view = try String(contentsOf: root.appendingPathComponent("Views/FullDiskAccessGateView.swift"))
        XCTAssertTrue(view.contains("continueWithoutConfirmedFullDiskAccess()"))
        XCTAssertTrue(view.contains("quitAndReopenFromApplications()"))
        let copy = try JSONSerialization.jsonObject(with: Data(contentsOf:
            root.appendingPathComponent("Resources/ViewCopy.json"))) as! [String: Any]
        let g = copy["fda_gate"] as! [String: String]
        XCTAssertEqual(g["continue_anyway_button"], "Continue anyway")
        XCTAssertEqual(g["quit_reopen_button"], "Quit and reopen")
        XCTAssertEqual(g["unconfirmed_note"],
            "Ostler could not confirm Full Disk Access. You can continue; Messages, Mail and Safari history will import once access is on.")
    }
}
