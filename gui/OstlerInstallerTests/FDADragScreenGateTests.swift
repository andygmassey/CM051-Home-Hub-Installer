// FDADragScreenGateTests.swift
//
// The drag-to-grant screen is for macOS 27.3+ only; everything earlier keeps
// the existing Full Disk Access gate. Also covers the second grant (Ostler,
// probed as Ostler) and the both-grants-or-nothing advance. Nothing here
// launches an app, reads a protected folder or raises a system dialog: the
// assistant runner and the file access are fakes.

import Foundation
import XCTest
@testable import OstlerInstaller

private func v(_ major: Int, _ minor: Int, _ patch: Int = 0) -> OperatingSystemVersion {
    OperatingSystemVersion(majorVersion: major, minorVersion: minor, patchVersion: patch)
}

private struct StubAccess: FDAFileAccess {
    let outcome: FDAReadOutcome
    func readOutcome(atPath path: String) -> FDAReadOutcome { outcome }
}

private func report(_ o: FDAReadOutcome) -> FDAProbeReport {
    FullDiskAccessProbe.run(home: "/fixture-home", access: StubAccess(outcome: o))
}

final class FDADragScreenGateTests: XCTestCase {
    // MARK: which screen

    func testThresholdIsOneConstantAt27Point3() {
        XCTAssertEqual(FDAFlow.dragScreenMinimum.majorVersion, 27)
        XCTAssertEqual(FDAFlow.dragScreenMinimum.minorVersion, 3)
        XCTAssertEqual(FDAFlow.dragScreenMinimum.patchVersion, 0)
    }

    func testMacOS27Point2ShowsTheOldFlow() {
        XCTAssertFalse(FDAFlow.usesDragScreen(version: v(27, 2)))
        XCTAssertFalse(FDAFlow.usesDragScreen(version: v(27, 2, 9)))
    }

    func testMacOS27Point3ShowsTheNewFlow() {
        XCTAssertTrue(FDAFlow.usesDragScreen(version: v(27, 3)))
        XCTAssertTrue(FDAFlow.usesDragScreen(version: v(27, 3, 1)))
        XCTAssertTrue(FDAFlow.usesDragScreen(version: v(27, 10)))
        XCTAssertTrue(FDAFlow.usesDragScreen(version: v(28, 0)))
    }

    func testEarlierMajorsShowTheOldFlow() {
        for old in [v(26, 4), v(26, 99), v(15, 7), v(14, 0)] {
            XCTAssertFalse(FDAFlow.usesDragScreen(version: old), "\(old)")
        }
    }

    func testOverrideParsing() {
        XCTAssertEqual(FDAFlow.parse("27.3")?.minorVersion, 3)
        XCTAssertEqual(FDAFlow.parse("27.2.1")?.patchVersion, 1)
        XCTAssertEqual(FDAFlow.parse("28")?.majorVersion, 28)
        for bad in ["", "x", "27.", "27.3.1.1", "27.-1", "27.a"] {
            XCTAssertNil(FDAFlow.parse(bad), bad)
        }
    }

    #if DEBUG
    func testDebugOverrideSelectsEachScreenOnAnyMac() {
        let real = v(26, 4)
        let old = FDAFlow.currentVersion(environment: ["OSTLER_DEBUG_MACOS_VERSION": "27.2"], real: real)
        let new = FDAFlow.currentVersion(environment: ["OSTLER_DEBUG_MACOS_VERSION": "27.3"], real: real)
        XCTAssertFalse(FDAFlow.usesDragScreen(version: old), "27.2 -> old flow")
        XCTAssertTrue(FDAFlow.usesDragScreen(version: new), "27.3 -> new flow")
    }

    func testUnparseableOverrideFallsBackToTheRealVersion() {
        let got = FDAFlow.currentVersion(environment: ["OSTLER_DEBUG_MACOS_VERSION": "junk"], real: v(26, 4))
        XCTAssertEqual(got.majorVersion, 26)
    }
    #endif

    func testNoOverrideUsesTheRealVersion() {
        let got = FDAFlow.currentVersion(environment: [:], real: v(27, 3))
        XCTAssertTrue(FDAFlow.usesDragScreen(version: got))
    }

    // MARK: Ostler's own answer

    func testSelfTestOutputParsing() {
        XCTAssertEqual(FDAAssistantSelfTest.parse("SELF-TEST: OK\n"), .granted)
        XCTAssertEqual(FDAAssistantSelfTest.parse("noise\nSELF-TEST: DENIED (errno 1)\n"), .denied)
        XCTAssertEqual(FDAAssistantSelfTest.parse("SELF-TEST: ???"), .noAnswer)
        XCTAssertEqual(FDAAssistantSelfTest.parse(""), .noAnswer)
        XCTAssertEqual(FDAAssistantSelfTest.parse(nil), .noAnswer)
        XCTAssertEqual(FDAAssistantSelfTest.parse("OK"), .noAnswer, "no marker, no grant")
    }

    private final class FakeRunner: FDAAssistantRunning {
        var supports: Bool
        var output: String?
        var capabilityChecks = 0
        var launches = 0
        init(supports: Bool, output: String?) { self.supports = supports; self.output = output }
        func supportsSelfTest(bundle: URL) async -> Bool { capabilityChecks += 1; return supports }
        func runAsApp(bundle: URL) async -> String? { launches += 1; return output }
    }

    func testProbeReportsWhatTheAppSays() async {
        let url = URL(fileURLWithPath: "/fixture/OstlerAssistant.app")
        var p = FDAAssistantProbe(runner: FakeRunner(supports: true, output: "SELF-TEST: OK"), bundle: url)
        let granted = await p.probe()
        XCTAssertEqual(granted, .granted)
        var d = FDAAssistantProbe(runner: FakeRunner(supports: true, output: "SELF-TEST: DENIED"), bundle: url)
        let denied = await d.probe()
        XCTAssertEqual(denied, .denied)
    }

    func testBinaryWithoutTheSelfTestIsNeverLaunchedThroughOpen() async {
        let runner = FakeRunner(supports: false, output: "SELF-TEST: OK")
        var p = FDAAssistantProbe(runner: runner, bundle: URL(fileURLWithPath: "/fixture/OstlerAssistant.app"))
        let first = await p.probe()
        let second = await p.probe()
        XCTAssertEqual(first, .noAnswer)
        XCTAssertEqual(second, .noAnswer)
        XCTAssertEqual(runner.launches, 0, "an older binary would start its daemon; it must not be launched")
        XCTAssertEqual(runner.capabilityChecks, 1, "capability is checked once")
    }

    // MARK: both grants or nothing

    func testAdvancesOnlyWhenBothHaveAccess() {
        var w = FDATwoGrantWatch()
        XCTAssertFalse(w.tick(installer: report(.readable), assistant: .denied), "installer alone is not enough")
        XCTAssertFalse(w.tick(installer: report(.readable), assistant: .noAnswer))
        XCTAssertTrue(w.tick(installer: report(.readable), assistant: .granted), "both -> advance")
    }

    func testAssistantAloneDoesNotAdvance() {
        var w = FDATwoGrantWatch()
        XCTAssertFalse(w.tick(installer: report(.denied(errno: EPERM)), assistant: .granted))
        XCTAssertTrue(w.assistantGranted)
        XCTAssertFalse(w.installerGranted)
    }

    func testGrantsAcrossDifferentTicksCombine() {
        var w = FDATwoGrantWatch()
        XCTAssertFalse(w.tick(installer: report(.denied(errno: EPERM)), assistant: .granted))
        XCTAssertTrue(w.tick(installer: report(.readable), assistant: nil), "assistant stays granted when not re-probed")
    }

    func testInconclusiveInstallerNeverAdvances() {
        var w = FDATwoGrantWatch()
        XCTAssertFalse(w.tick(installer: report(.missing), assistant: .granted))
    }

    func testFiresOnlyOnce() {
        var w = FDATwoGrantWatch()
        XCTAssertTrue(w.tick(installer: report(.readable), assistant: .granted))
        XCTAssertFalse(w.tick(installer: report(.readable), assistant: .granted))
    }

    func testNoAssistantBundleWaitsOnTheInstallerAlone() {
        var w = FDATwoGrantWatch()
        XCTAssertFalse(w.tick(installer: report(.denied(errno: EPERM)), assistant: nil))
        XCTAssertTrue(w.tick(installer: report(.readable), assistant: nil))
    }

    // MARK: tile order

    func testTilesAreOstlerThenInstaller() {
        XCTAssertEqual(FDATileSequence.order(hasAssistant: true), [.assistant, .installer])
        XCTAssertEqual(FDATileSequence.order(hasAssistant: false), [.installer])
    }

    func testActiveTileFollowsTheGrants() {
        XCTAssertEqual(FDATileSequence.active(hasAssistant: true, assistantGranted: false, installerGranted: false), .assistant)
        XCTAssertEqual(FDATileSequence.active(hasAssistant: true, assistantGranted: false, installerGranted: true), .assistant)
        XCTAssertEqual(FDATileSequence.active(hasAssistant: true, assistantGranted: true, installerGranted: false), .installer)
        XCTAssertNil(FDATileSequence.active(hasAssistant: true, assistantGranted: true, installerGranted: true))
        XCTAssertEqual(FDATileSequence.active(hasAssistant: false, assistantGranted: false, installerGranted: false), .installer)
    }

    // MARK: Ostler's name

    func testAssistantNameIsItsDisplayNameNotTheFileName() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fda-name-\(UUID().uuidString)")
        let app = dir.appendingPathComponent("OstlerAssistant.app/Contents")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let plist: [String: Any] = ["CFBundleIdentifier": "ai.ostler.assistant", "CFBundleName": "Ostler Assistant",
                                    "CFBundleDisplayName": "Ostler", "CFBundlePackageType": "APPL"]
        (plist as NSDictionary).write(to: app.appendingPathComponent("Info.plist"), atomically: true)
        XCTAssertEqual(FDAHandoff.displayName(ofAppAt: dir.appendingPathComponent("OstlerAssistant.app")), "Ostler")
    }
}
