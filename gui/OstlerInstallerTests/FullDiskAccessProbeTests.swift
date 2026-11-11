// FullDiskAccessProbeTests.swift
//
// Regression for the macOS 27 FDA gate dead end: the user TCC.db does not
// exist there, the old probe read only that file, so every customer was
// blocked at the gate with no way out. All file access goes through the
// FDAFileAccess seam; nothing here touches a real protected folder.

import Foundation
import XCTest
@testable import OstlerInstaller

private struct FakeAccess: FDAFileAccess {
    var outcomes: [String: FDAReadOutcome] = [:]
    var fallback: FDAReadOutcome = .missing
    func readOutcome(atPath path: String) -> FDAReadOutcome { outcomes[path] ?? fallback }
}

final class FullDiskAccessProbeTests: XCTestCase {
    private let home = "/fixture-home"

    private func path(_ rel: String) -> String { home + "/" + rel }
    private func report(_ a: FakeAccess) -> FDAProbeReport { FullDiskAccessProbe.run(home: home, access: a) }

    func testEachProbeAlonePasses() {
        for rel in FullDiskAccessProbe.relativePaths {
            // Everything else is denied; only this one reads.
            var a = FakeAccess(fallback: .denied(errno: EPERM))
            a.outcomes[path(rel)] = .readable
            XCTAssertTrue(report(a).granted, "probe \(rel) alone must pass")
        }
    }

    func testMacOS27ShapeTCCMissingOthersReadable() {
        var a = FakeAccess(fallback: .missing)
        a.outcomes[path("Library/Messages/chat.db")] = .readable
        XCTAssertTrue(report(a).granted)
    }

    func testAllMissingDoesNotHardBlock() {
        let r = report(FakeAccess(fallback: .missing))
        XCTAssertFalse(r.granted)
        XCTAssertTrue(r.inconclusive, "all probe files absent must not claim no access")
        XCTAssertEqual(FDAGateState().launchDecision(r), .proceed)
        var g = FDAGateState()
        XCTAssertEqual(g.recheck(r), .proceed)
        XCTAssertEqual(g.failedRechecks, 0)
    }

    func testDeniedEverywhereHoldsThenOffersEscapeAfterTwoRechecks() {
        let r = report(FakeAccess(fallback: .denied(errno: EPERM)))
        XCTAssertFalse(r.granted)
        XCTAssertFalse(r.inconclusive)
        var g = FDAGateState()
        XCTAssertEqual(g.launchDecision(r), .hold)
        XCTAssertEqual(g.recheck(r), .hold)
        XCTAssertFalse(g.showContinueAnyway, "one failed recheck is not enough")
        XCTAssertEqual(g.recheck(r), .hold)
        XCTAssertTrue(g.showContinueAnyway, "escape must show after 2 failed rechecks")
    }

    func testGrantAfterFailedRecheckProceeds() {
        var g = FDAGateState()
        _ = g.recheck(report(FakeAccess(fallback: .denied(errno: EPERM))))
        var ok = FakeAccess(fallback: .denied(errno: EPERM))
        ok.outcomes[path("Library/Safari/History.db")] = .readable
        XCTAssertEqual(g.recheck(report(ok)), .proceed)
    }

    func testDeniedIsDistinguishedFromMissingInLog() {
        var a = FakeAccess(fallback: .missing)
        a.outcomes[path("Library/Mail")] = .denied(errno: EPERM)
        let lines = report(a).failureLines
        XCTAssertTrue(lines.contains(path("Library/Mail") + " (errno \(EPERM))"))
        XCTAssertTrue(lines.contains(path("Library/Messages/chat.db") + " (missing)"))
        XCTAssertEqual(lines.count, FullDiskAccessProbe.relativePaths.count)
    }

    func testProbeListIsExactlyTheFourProtectedSources() {
        XCTAssertEqual(FullDiskAccessProbe.relativePaths, [
            "Library/Application Support/com.apple.TCC/TCC.db",
            "Library/Safari/History.db",
            "Library/Mail",
            "Library/Messages/chat.db",
        ])
    }

    func testReadableNonProtectedPathNeverCounts() {
        // A path outside the probe list that reads fine (as sharedfilelist
        // can without FDA) must not grant; every listed probe is denied.
        let unprotected = path("Library/Application Support/com.apple.sharedfilelist")
        var a = FakeAccess(fallback: .denied(errno: EPERM))
        a.outcomes[unprotected] = .readable
        let r = report(a)
        XCTAssertFalse(r.granted, "a readable non-protected path must never grant")
        XCTAssertFalse(r.results.contains { $0.path == unprotected })
    }

    func testSystemAccessClassifiesRealTempPaths() throws {
        let dir = NSTemporaryDirectory() + "fda-probe-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let file = dir + "/f"
        try Data([1]).write(to: URL(fileURLWithPath: file))
        let s = SystemFDAFileAccess()
        XCTAssertEqual(s.readOutcome(atPath: file), .readable)
        XCTAssertEqual(s.readOutcome(atPath: dir), .readable)
        XCTAssertEqual(s.readOutcome(atPath: dir + "/nope"), .missing)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file)
        if getuid() != 0 {
            XCTAssertEqual(s.readOutcome(atPath: file), .denied(errno: EACCES))
        }
    }

    func testRelaunchTargetsApplicationsBundleOnly() {
        XCTAssertEqual(InstallerCoordinator.relaunchCommand.last, "/Applications/OstlerInstaller.app")
    }
}

// MARK: - FDA handoff (macOS 27.3: the app cannot add itself to the list)

final class FDAHandoffTests: XCTestCase {
    private func report(_ outcome: FDAReadOutcome) -> FDAProbeReport {
        FullDiskAccessProbe.run(home: "/fixture-home", access: FakeAccess(fallback: outcome))
    }

    /// The tile must drag the binary whose protected read is being probed,
    /// not a look-alike bundle. The probe runs in this process, so the
    /// bundle it names must own this process's executable.
    func testDragURLIsTheBundleOwningTheProbingProcess() throws {
        // Only meaningful when hosted in OstlerInstaller.app (project.yml
        // TEST_HOST). Under a bare SwiftPM runner Bundle.main is not an app.
        try XCTSkipUnless(Bundle.main.bundleURL.pathExtension == "app", "needs the app host")
        let url = FDAHandoff.appBundleURL()
        XCTAssertEqual(url.pathExtension, "app")
        XCTAssertEqual(Bundle(url: url)?.executableURL?.standardizedFileURL,
                       Bundle.main.executableURL?.standardizedFileURL,
                       "the dragged bundle must be the one whose executable is probing")
    }

    func testDragProviderCarriesTheBundleFileURL() {
        let url = FDAHandoff.appBundleURL()
        let provider = FDAHandoff.dragProvider(for: url)
        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier("public.file-url"),
                      "a real drag source must offer a file URL to the Finder list")
    }

    func testDisplayNameIsTheAppNameWithoutExtension() {
        XCTAssertFalse(FDAHandoff.displayName().hasSuffix(".app"))
        XCTAssertFalse(FDAHandoff.displayName().isEmpty)
    }

    /// Auto-advance: fires exactly once, on the first tick that reads.
    func testGrantWatchAdvancesOnTheTickAccessAppears() {
        var watch = FDAGrantWatch()
        XCTAssertFalse(watch.tick(report(.denied(errno: EPERM))), "denied must not advance")
        XCTAssertFalse(watch.tick(report(.denied(errno: EPERM))), "still denied must not advance")
        XCTAssertTrue(watch.tick(report(.readable)), "the first readable tick advances")
    }

    func testGrantWatchFiresOnlyOnce() {
        var watch = FDAGrantWatch()
        XCTAssertTrue(watch.tick(report(.readable)))
        XCTAssertFalse(watch.tick(report(.readable)), "must not advance twice")
    }

    func testGrantWatchDoesNotAdvanceOnAnInconclusiveProbe() {
        var watch = FDAGrantWatch()
        XCTAssertFalse(watch.tick(report(.missing)),
                       "every probe absent says nothing about access; the poll must not advance on it")
    }
}
