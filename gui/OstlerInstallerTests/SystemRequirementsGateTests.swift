// SystemRequirementsGateTests.swift
//
// F006 (2026-10-24). An F&F tester on an 8 GB Mac reached
// ERR-02-PREREQ-RAM-LOW only after the permission prompts, licence
// acceptance, a device slot being registered, the admin password and a
// Command Line Tools download. These tests pin the GUI-side floor:
//
//   - an 8 GB Mac stops on the FIRST screen: no relocator, no FDA
//     probe, and even after the customer skips permissions it is still
//     the requirements screen, never the licence screen;
//   - a validly signed licence handed to it is NOT accepted, NOT
//     persisted and does NOT reach the device-registration endpoint;
//   - bootstrap (the admin prompt, then install.sh and the CLT
//     download) does not run;
//   - a 16 GB Apple Silicon Mac on macOS 14 passes straight through to
//     the normal flow;
//   - the Swift floors equal install.sh's floors.
//
// The memory reading is injected through
// `InstallerCoordinator(systemReadings:)`. No real keychain, TCC,
// network or ~/.ostler is touched: the licence path is a temp dir and
// the registration transport is a recording stub.

import CryptoKit
import SwiftUI
import XCTest
@testable import OstlerInstaller

extension SystemReadings {
    /// A Mac exactly at every floor. For tests that exercise paths past
    /// the hardware gate and must not depend on the machine running them
    /// (GitHub's macOS runners have less than 16 GB).
    static let supportedMacForTests = SystemReadings(
        memoryBytes: 16 * 1_073_741_824,
        macOSMajor: 14,
        macOSVersion: "14.5",
        isAppleSilicon: true
    )
}

@MainActor
final class SystemRequirementsGateTests: XCTestCase {

    // MARK: - Readings

    private static let gb: UInt64 = 1_073_741_824

    private func readings(
        gb memGB: UInt64,
        macOSMajor: Int = 14,
        version: String = "14.5",
        appleSilicon: Bool = true
    ) -> SystemReadings {
        SystemReadings(
            memoryBytes: memGB * Self.gb,
            macOSMajor: macOSMajor,
            macOSVersion: version,
            isAppleSilicon: appleSilicon
        )
    }

    // MARK: - Stubs

    /// Records every registration request. Answers 404 so that, if the
    /// gate were missing, the coordinator lands on `.fatal` and writes
    /// nothing to disk (the .ok and networkFailure arms write fingerprint
    /// state under HOME).
    actor RecordingTransport: DeviceRegistrationTransport {
        private(set) var calls = 0
        func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
            calls += 1
            let resp = HTTPURLResponse(
                url: request.url!, statusCode: 404,
                httpVersion: nil, headerFields: nil
            )!
            return (Data("{}".utf8), resp)
        }
        func count() -> Int { calls }
    }

    /// Records permission requests instead of making them. Installed on
    /// EVERY coordinator in this file, so no arm of any test (including
    /// a mutant with the gate removed) can raise a real TCC dialog.
    final class CountingRequester: PermissionRequester {
        private(set) var calls = 0
        func request(_ permission: PrewarmPermission) async -> Bool {
            calls += 1
            return true
        }
    }

    private var tempDir: URL!
    private var requester: CountingRequester!

    override func setUp() async throws {
        // The prewarm's AppleEvent probe (`tell application "Contacts"`)
        // is a static switch, not part of the requester. Off for this
        // whole class so no test can put an Automation prompt on screen.
        PermissionsPrewarmer.appleEventContactsProbeEnabled = false
        requester = CountingRequester()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("f006-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        await settle()
        PermissionsPrewarmer.appleEventContactsProbeEnabled = true
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func signedLicence() throws -> (LicenseVerifier, Data) {
        let key = Curve25519.Signing.PrivateKey()
        let body: [String: Any] = [
            "version": 1,
            "license_id": "8c7e3f9a-1234-4abc-9def-0123456789ab",
            "issued_to_email": "tester@example.com",
            "purchased_at": "2026-04-23T14:00:00Z",
            "update_window_expires_at": "2099-04-23T14:00:00Z",
            "max_hardware_fingerprints": 2,
            "stripe_payment_id": "pi_TEST_0123456789",
            "signature_algorithm": "Ed25519",
        ]
        let canonical = try XCTUnwrap(LicenseVerifier.canonicalJSON(body))
        var full = body
        full["signature"] = try key.signature(for: canonical).base64EncodedString()
        let data = try JSONSerialization.data(withJSONObject: full, options: [.sortedKeys])
        return (LicenseVerifier(publicKey: key.publicKey), data)
    }

    /// A coordinator with every outward seam stubbed.
    private func makeCoordinator(_ r: SystemReadings) -> (InstallerCoordinator, RecordingTransport) {
        let coord = InstallerCoordinator(systemReadings: r)
        coord.licensePath = tempDir.appendingPathComponent("license.json")
        coord.fullDiskAccessReport = {
            FDAProbeReport(results: [FDAProbeResult(path: "synthetic", outcome: .readable)])
        }
        let req = requester!
        coord.setPermissionsPrewarmerFactory {
            PermissionsPrewarmer(emitLog: { _, _ in }, requester: req, gapMillis: 0)
        }
        let transport = RecordingTransport()
        coord.setRegistrationClient(DeviceRegistrationClient(
            endpoint: URL(string: "https://registration.invalid/register-device")!,
            transport: transport
        ))
        return (coord, transport)
    }

    private func settle() async {
        // Let any Task spawned by the call under test run to completion.
        for _ in 0..<25 { try? await Task.sleep(nanoseconds: 20_000_000) }
    }

    // MARK: - 8 GB: stops on screen 1

    func test8GBMacStopsOnFirstScreenAndNeverReachesLicence() async throws {
        let (coord, transport) = makeCoordinator(readings(gb: 8))

        var relocated = false
        coord.startFromFirstScreen(relocate: { relocated = true })

        XCTAssertEqual(coord.rootScreen, .systemRequirements,
                       "an 8 GB Mac must see the requirements screen first")
        XCTAssertFalse(relocated, "the move-to-Applications modal must not run on an unsupported Mac")
        XCTAssertFalse(coord.needsFullDiskAccessUpfront, "the FDA gate must not be raised")

        // The customer cannot press anything that leads on, but even if
        // the permissions flow were finished the root must not move to
        // the licence screen.
        coord.skipPermissionsPrewarm()
        XCTAssertEqual(coord.rootScreen, .systemRequirements,
                       "must not reach the licence screen on an 8 GB Mac")

        // A validly signed licence must not be accepted, persisted or
        // registered.
        let (verifier, licence) = try signedLicence()
        coord.setLicenseVerifierForTests(verifier)
        _ = coord.verifyLicense(data: licence, source: "drop")
        await settle()
        XCTAssertFalse(coord.licenseVerified, "no licence drop may be accepted")
        XCTAssertFalse(FileManager.default.fileExists(atPath: coord.licensePath.path),
                       "no licence may be persisted")
        let calls = await transport.count()
        XCTAssertEqual(calls, 0, "no device-registration call may be made")
        XCTAssertEqual(coord.registrationGate, .idle)
    }

    func test8GBMacNeverStartsThePermissionPrompts() async {
        let (coord, _) = makeCoordinator(readings(gb: 8))
        coord.beginPermissionsPrewarm()
        await settle()
        XCTAssertEqual(coord.permissionsIntroState, .intro, "the prewarm must not start")
        XCTAssertEqual(requester.calls, 0, "no permission request may be made")
    }

    func test8GBMacNeverRaisesTheAdminPrompt() async {
        let (coord, _) = makeCoordinator(readings(gb: 8))
        // Force every downstream gate open, so the ONLY thing between
        // bootstrap and the admin prompt is the hardware floor.
        coord.licenseVerified = true
        coord.registrationGate = .ready
        coord.permissionsIntroState = .complete

        var providerCalled = false
        var launchCalled = false
        coord.setAdminAuthorizationProvider { _ in providerCalled = true; return true }
        coord.setLaunchInstallerOverride { launchCalled = true }

        coord.bootstrap()
        await settle()

        XCTAssertFalse(coord.needsAdminAcknowledgement, "the admin explanation must not appear")
        XCTAssertFalse(providerCalled, "the admin password prompt must not fire")
        XCTAssertFalse(launchCalled, "install.sh (and so the CLT download) must not launch")
    }

    // MARK: - 16 GB: passes

    func test16GBAppleSiliconMacOS14PassesToTheNormalFlow() async throws {
        let (coord, transport) = makeCoordinator(readings(gb: 16))
        XCTAssertNil(coord.systemShortfall)

        var relocated = false
        coord.startFromFirstScreen(relocate: { relocated = true })
        XCTAssertTrue(relocated, "a supported Mac runs the relocator as before")
        XCTAssertNotEqual(coord.rootScreen, .systemRequirements)

        XCTAssertFalse(coord.needsFullDiskAccessUpfront, "stubbed FDA probe reports access present")
        coord.skipPermissionsPrewarm()
        XCTAssertEqual(coord.rootScreen, .licence, "a 16 GB Mac reaches the licence screen")

        let (verifier, licence) = try signedLicence()
        coord.setLicenseVerifierForTests(verifier)
        _ = coord.verifyLicense(data: licence, source: "drop")
        await settle()
        XCTAssertTrue(coord.licenseVerified)
        let calls = await transport.count()
        XCTAssertEqual(calls, 1, "a 16 GB Mac registers its device as before")
    }

    // MARK: - Each floor

    func testEachFloorIsEnforcedAndNamed() {
        XCTAssertNil(SystemRequirements.evaluate(readings(gb: 16)))
        XCTAssertNil(SystemRequirements.evaluate(readings(gb: 24, macOSMajor: 26, version: "26.5")))

        let mem = SystemRequirements.evaluate(readings(gb: 8))
        XCTAssertEqual(mem?.memoryTooLow, true)
        XCTAssertEqual(mem?.macOSTooOld, false)
        XCTAssertEqual(mem?.notAppleSilicon, false)

        // 15.x GB of addressable memory is still below the floor, same
        // integer division as install.sh.
        let almost = SystemReadings(memoryBytes: 16 * Self.gb - 1, macOSMajor: 14,
                                    macOSVersion: "14.5", isAppleSilicon: true)
        XCTAssertEqual(SystemRequirements.evaluate(almost)?.memoryTooLow, true)

        XCTAssertEqual(SystemRequirements.evaluate(readings(gb: 16, appleSilicon: false))?.notAppleSilicon, true)
        XCTAssertEqual(SystemRequirements.evaluate(readings(gb: 16, macOSMajor: 13, version: "13.6"))?.macOSTooOld, true)
    }

    func testTheScreenSaysWhatThisMacHas() throws {
        let s = try XCTUnwrap(SystemRequirements.evaluate(readings(gb: 8)))
        let view = SystemRequirementsView(shortfall: s)
        XCTAssertEqual(view.detailLines, ["This Mac has 8 GB of memory."])

        let all = try XCTUnwrap(SystemRequirements.evaluate(
            readings(gb: 8, macOSMajor: 13, version: "13.6", appleSilicon: false)))
        XCTAssertEqual(SystemRequirementsView(shortfall: all).detailLines, [
            "This Mac has an Intel processor.",
            "This Mac has 8 GB of memory.",
            "This Mac is running macOS 13.6.",
        ])

        for key in ["heading", "body", "memory_line", "chip_line", "macos_line",
                    "nothing_changed", "requirements_link", "requirements_url", "quit_button"] {
            let full = "system_requirements.\(key)"
            let v = ViewCopy.shared.string(for: full)
            XCTAssertNotEqual(v, full, "missing catalogue string \(full)")
            XCTAssertFalse(v.contains("\u{2014}"), "em dash in \(full)")
        }
    }

    // MARK: - Parity with install.sh, the backstop

    func testSwiftFloorsEqualInstallShFloors() throws {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // OstlerInstallerTests
            .deletingLastPathComponent()   // gui
            .deletingLastPathComponent()   // repo root
        let installSh = try String(contentsOf: repo.appendingPathComponent("install.sh"), encoding: .utf8)

        XCTAssertTrue(installSh.contains("OSTLER_MACOS_FLOOR_MAJOR=\(SystemRequirements.macOSFloorMajor)\n"),
                      "install.sh macOS floor differs from SystemRequirements.macOSFloorMajor")
        XCTAssertTrue(installSh.contains("if [[ $RAM_GB -lt \(SystemRequirements.minimumMemoryGB) ]]; then\n    fail_with_code \"ERR-02-PREREQ-RAM-LOW\""),
                      "install.sh RAM floor differs from SystemRequirements.minimumMemoryGB")
        XCTAssertTrue(installSh.contains("if [[ \"$ARCH\" == \"arm64\" ]]; then"),
                      "install.sh no longer requires arm64")
    }

    // MARK: - Screenshot for the PR

    func testRenderSystemRequirementsScreenToPNG() throws {
        let (coord, _) = makeCoordinator(readings(gb: 8))
        let s = try XCTUnwrap(coord.systemShortfall)
        let view = SystemRequirementsView(shortfall: s)
            .environmentObject(coord)
            .frame(width: 880, height: 620)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2.0
        guard let nsImage = renderer.nsImage else {
            throw XCTSkip("ImageRenderer returned nil (host may not support headless SwiftUI rendering)")
        }
        guard let tiff = nsImage.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            return XCTFail("could not encode PNG")
        }
        let outDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ostler-snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let outURL = outDir.appendingPathComponent("system-requirements-8gb.png")
        try png.write(to: outURL)
        print("SNAPSHOT: \(outURL.path)")
    }
}
