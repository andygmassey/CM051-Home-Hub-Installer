// SelfRelocatorTests.swift
//
// Tests for the first-launch self-relocator (see
// HR015/launch/TNM_BRIEF_DMG_INSTALLER_UX_2026-05-13.md). Drives the
// closure-based Actions sink so every branch is testable without
// touching the real disk, NSWorkspace, or NSAlert.
//
// The brief mandates three tests minimum:
//
// * testRunningFromApplicationsSkipsRelocation
// * testRunningFromVolumesPathTriggersRelocation
// * testDontMoveChoicePersists
//
// Additional tests cover post-relaunch cleanup, the Replace-existing
// branch, and the copy-failure error path.

import Foundation
import XCTest
@testable import OstlerInstaller

final class SelfRelocatorTests: XCTestCase {

    // MARK: - Per-test isolated UserDefaults

    private var defaults: UserDefaults!
    private var defaultsSuite: String!

    override func setUp() {
        super.setUp()
        // Spin up an isolated UserDefaults suite per test so the
        // "don't move" flag from one test doesn't leak into the next.
        defaultsSuite = "SelfRelocatorTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: defaultsSuite)
        defaults = nil
        defaultsSuite = nil
        super.tearDown()
    }

    // MARK: - Recorder + action factories

    /// Records every closure invocation so tests can assert on the
    /// shape of the calls without a stub library.
    private final class CallRecorder {
        var copiedFrom: [URL] = []
        var copiedTo: [URL] = []
        var removed: [URL] = []
        var recycled: [URL] = []
        var relocationPrompts: [URL] = []
        var replaceExistingPrompts = 0
        var errorAlerts: [(String, String)] = []
        var relaunched: [(URL, String)] = []
        var terminated = 0
    }

    private func makeActions(
        recorder: CallRecorder,
        relocationChoice: SelfRelocator.RelocationChoice = .moveToApplications,
        replaceChoice: SelfRelocator.ReplaceChoice = .replace,
        fileExistsAt: Set<URL> = [],
        copyThrows: Error? = nil,
        removeThrows: Error? = nil
    ) -> SelfRelocator.Actions {
        SelfRelocator.Actions(
            fileExists: { url in fileExistsAt.contains(url) },
            copyItem: { src, dst in
                if let err = copyThrows { throw err }
                recorder.copiedFrom.append(src)
                recorder.copiedTo.append(dst)
            },
            remove: { url in
                if let err = removeThrows { throw err }
                recorder.removed.append(url)
            },
            recycle: { url in recorder.recycled.append(url) },
            showRelocationPrompt: { url in
                recorder.relocationPrompts.append(url)
                return relocationChoice
            },
            showReplaceExistingPrompt: {
                recorder.replaceExistingPrompts += 1
                return replaceChoice
            },
            showError: { title, message in
                recorder.errorAlerts.append((title, message))
            },
            relaunch: { newURL, oldPath in
                recorder.relaunched.append((newURL, oldPath))
            },
            terminate: { recorder.terminated += 1 }
        )
    }

    // MARK: - Brief-required test 1: Applications launch skips relocation

    func testRunningFromApplicationsSkipsRelocation() {
        // Brief: "Already in /Applications/: do nothing, proceed to
        // normal launch." No modal, no copy, no relaunch.
        let recorder = CallRecorder()
        let relocator = SelfRelocator(
            bundleURL: SelfRelocator.targetURL,
            environmentVariables: [:],
            userDefaults: defaults,
            actions: makeActions(recorder: recorder)
        )

        relocator.run()

        XCTAssertTrue(recorder.relocationPrompts.isEmpty,
                      "Relocation prompt must not show when already in /Applications")
        XCTAssertTrue(recorder.copiedFrom.isEmpty)
        XCTAssertTrue(recorder.relaunched.isEmpty)
        XCTAssertEqual(recorder.terminated, 0)
    }

    // MARK: - Brief-required test 2: /Volumes path triggers relocation

    func testRunningFromVolumesPathTriggersRelocation() {
        // Brief: "Running from inside a mounted DMG (path matches
        // /Volumes/<volname>/...): same modal as above. After move
        // + relaunch, the trash step is skipped."
        let recorder = CallRecorder()
        let dmgPath = URL(fileURLWithPath: "/Volumes/Ostler Installer 0.2.1/OstlerInstaller.app")
        let relocator = SelfRelocator(
            bundleURL: dmgPath,
            environmentVariables: [:],
            userDefaults: defaults,
            actions: makeActions(
                recorder: recorder,
                relocationChoice: .moveToApplications
            )
        )

        relocator.run()

        // Modal shown.
        XCTAssertEqual(recorder.relocationPrompts.count, 1)
        XCTAssertEqual(recorder.relocationPrompts.first, dmgPath)
        // Copy invoked from DMG → /Applications.
        XCTAssertEqual(recorder.copiedFrom, [dmgPath])
        XCTAssertEqual(recorder.copiedTo, [SelfRelocator.targetURL])
        // Relaunched with the OSTLER_RELOCATED_FROM handoff.
        XCTAssertEqual(recorder.relaunched.count, 1)
        XCTAssertEqual(recorder.relaunched.first?.0, SelfRelocator.targetURL)
        XCTAssertEqual(recorder.relaunched.first?.1, dmgPath.path)
        // Original process terminated so the new /Applications copy
        // can take over.
        XCTAssertEqual(recorder.terminated, 1)
        // Don't-move flag NOT set (the customer chose to move).
        XCTAssertFalse(defaults.bool(forKey: SelfRelocator.dontMoveDefaultsKey))
    }

    // MARK: - Brief-required test 3: "Don't Move" persists

    func testDontMoveChoicePersists() {
        // Brief: "Persist the user's 'don't move' choice in
        // UserDefaults so subsequent launches from outside
        // /Applications don't keep prompting."
        let recorder = CallRecorder()
        let downloadsPath = URL(fileURLWithPath: "/Users/test/Downloads/OstlerInstaller.app")

        // First launch: customer clicks Don't Move.
        let firstRun = SelfRelocator(
            bundleURL: downloadsPath,
            environmentVariables: [:],
            userDefaults: defaults,
            actions: makeActions(recorder: recorder, relocationChoice: .dontMove)
        )
        firstRun.run()

        XCTAssertEqual(recorder.relocationPrompts.count, 1, "First launch must prompt")
        XCTAssertTrue(defaults.bool(forKey: SelfRelocator.dontMoveDefaultsKey),
                      "Don't-move flag must be persisted")
        XCTAssertTrue(recorder.copiedFrom.isEmpty)
        XCTAssertEqual(recorder.terminated, 0)

        // Second launch from the same out-of-Applications path: silent.
        let secondRecorder = CallRecorder()
        let secondRun = SelfRelocator(
            bundleURL: downloadsPath,
            environmentVariables: [:],
            userDefaults: defaults,
            actions: makeActions(recorder: secondRecorder)
        )
        secondRun.run()

        XCTAssertTrue(secondRecorder.relocationPrompts.isEmpty,
                      "Second launch must NOT prompt after Don't Move")
        XCTAssertTrue(secondRecorder.copiedFrom.isEmpty)
    }

    // MARK: - Post-relaunch cleanup

    func testPostRelaunchCleanupTrashesPriorBundle() {
        // After moving from ~/Downloads to /Applications, the new
        // /Applications copy receives OSTLER_RELOCATED_FROM and
        // trashes the original.
        let recorder = CallRecorder()
        let priorPath = "/Users/test/Downloads/OstlerInstaller.app"
        let relocator = SelfRelocator(
            bundleURL: SelfRelocator.targetURL,
            environmentVariables: [SelfRelocator.relocatedFromEnvKey: priorPath],
            userDefaults: defaults,
            actions: makeActions(recorder: recorder)
        )

        relocator.run()

        XCTAssertEqual(recorder.recycled, [URL(fileURLWithPath: priorPath)])
        XCTAssertTrue(recorder.relocationPrompts.isEmpty)
    }

    func testPostRelaunchCleanupSkipsDMGSource() {
        // Brief: "After move + relaunch, the trash step is skipped
        // (can't trash from a read-only DMG; user ejects manually)."
        let recorder = CallRecorder()
        let dmgPath = "/Volumes/Ostler Installer 0.2.1/OstlerInstaller.app"
        let relocator = SelfRelocator(
            bundleURL: SelfRelocator.targetURL,
            environmentVariables: [SelfRelocator.relocatedFromEnvKey: dmgPath],
            userDefaults: defaults,
            actions: makeActions(recorder: recorder)
        )

        relocator.run()

        XCTAssertTrue(recorder.recycled.isEmpty,
                      "Must not attempt to trash a DMG-mounted source")
    }

    // MARK: - Replace-existing flow

    func testReplaceExistingHappyPath() {
        // Brief open question #3 resolution: offer Replace, default
        // accepted -> old copy removed, new copy installed, relaunch.
        let recorder = CallRecorder()
        let downloadsPath = URL(fileURLWithPath: "/Users/test/Downloads/OstlerInstaller.app")
        let relocator = SelfRelocator(
            bundleURL: downloadsPath,
            environmentVariables: [:],
            userDefaults: defaults,
            actions: makeActions(
                recorder: recorder,
                relocationChoice: .moveToApplications,
                replaceChoice: .replace,
                fileExistsAt: [SelfRelocator.targetURL]
            )
        )

        relocator.run()

        XCTAssertEqual(recorder.replaceExistingPrompts, 1,
                       "Must prompt before clobbering existing /Applications copy")
        XCTAssertEqual(recorder.removed, [SelfRelocator.targetURL])
        XCTAssertEqual(recorder.copiedTo, [SelfRelocator.targetURL])
        XCTAssertEqual(recorder.terminated, 1)
    }

    func testReplaceExistingCancelAborts() {
        // Customer cancels the Replace prompt -> nothing happens.
        let recorder = CallRecorder()
        let downloadsPath = URL(fileURLWithPath: "/Users/test/Downloads/OstlerInstaller.app")
        let relocator = SelfRelocator(
            bundleURL: downloadsPath,
            environmentVariables: [:],
            userDefaults: defaults,
            actions: makeActions(
                recorder: recorder,
                relocationChoice: .moveToApplications,
                replaceChoice: .cancel,
                fileExistsAt: [SelfRelocator.targetURL]
            )
        )

        relocator.run()

        XCTAssertEqual(recorder.replaceExistingPrompts, 1)
        XCTAssertTrue(recorder.removed.isEmpty)
        XCTAssertTrue(recorder.copiedFrom.isEmpty)
        XCTAssertEqual(recorder.terminated, 0)
    }

    // MARK: - Failure paths

    func testCopyFailureShowsErrorAndDoesNotTerminate() {
        struct CopyError: Error, LocalizedError {
            var errorDescription: String? { "permission denied" }
        }
        let recorder = CallRecorder()
        let downloadsPath = URL(fileURLWithPath: "/Users/test/Downloads/OstlerInstaller.app")
        let relocator = SelfRelocator(
            bundleURL: downloadsPath,
            environmentVariables: [:],
            userDefaults: defaults,
            actions: makeActions(
                recorder: recorder,
                relocationChoice: .moveToApplications,
                copyThrows: CopyError()
            )
        )

        relocator.run()

        XCTAssertEqual(recorder.errorAlerts.count, 1)
        XCTAssertEqual(recorder.errorAlerts.first?.1, "permission denied")
        XCTAssertEqual(recorder.terminated, 0,
                       "Process must not quit when relocation failed")
    }

    // MARK: - Path classification

    func testIsInApplicationsHelper() {
        XCTAssertTrue(SelfRelocator.isInApplications(
            URL(fileURLWithPath: "/Applications/OstlerInstaller.app")
        ))
        XCTAssertTrue(SelfRelocator.isInApplications(
            URL(fileURLWithPath: "/Applications/OstlerInstaller.app/Contents/MacOS/OstlerInstaller")
        ))
        XCTAssertFalse(SelfRelocator.isInApplications(
            URL(fileURLWithPath: "/Volumes/Ostler Installer 0.2.1/OstlerInstaller.app")
        ))
        XCTAssertFalse(SelfRelocator.isInApplications(
            URL(fileURLWithPath: "/Users/test/Downloads/OstlerInstaller.app")
        ))
        XCTAssertFalse(SelfRelocator.isInApplications(
            URL(fileURLWithPath: "/Applications/OtherApp.app")
        ))
    }

    func testIsInDMGHelper() {
        XCTAssertTrue(SelfRelocator.isInDMG(
            URL(fileURLWithPath: "/Volumes/Ostler Installer 0.2.1/OstlerInstaller.app")
        ))
        XCTAssertFalse(SelfRelocator.isInDMG(
            URL(fileURLWithPath: "/Applications/OstlerInstaller.app")
        ))
        XCTAssertFalse(SelfRelocator.isInDMG(
            URL(fileURLWithPath: "/Users/test/Downloads/OstlerInstaller.app")
        ))
    }
}
