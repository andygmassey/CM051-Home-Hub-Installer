// PermissionsPrewarmInfoPlistTest.swift
//
// CX-14 Section E1 regression test. The pre-warmer requests
// Contacts / Calendar / Reminders / Photos via the relevant macOS
// frameworks at app launch. Each framework's requestAccess API
// REQUIRES a matching Info.plist usage-description string; without
// the string macOS silently denies the prompt and the install
// pipeline later wonders why "the customer said no".
//
// Per locked memory `feedback_silent_bail_regression_test_shape`:
// for the exact silent-bail axis (Info.plist key missing => silent
// deny), walk the assembled bundle metadata key-by-key asserting
// every key the pre-warmer touches is present. A "does it launch"
// happy-path test would NOT catch a missing key because macOS does
// not error on a missing usage description -- it just denies.
//
// Required NS keys (cross-referenced against PermissionsPrewarmer):
//   - NSContactsUsageDescription                CNContactStore.requestAccess(for:.contacts)
//   - NSCalendarsFullAccessUsageDescription     EKEventStore.requestFullAccessToEvents
//   - NSRemindersFullAccessUsageDescription     EKEventStore.requestFullAccessToReminders
//   - NSPhotoLibraryUsageDescription            PHPhotoLibrary.requestAuthorization(for:.readWrite)
//
// Also walks the project.yml so a fresh `xcodegen generate` cannot
// regenerate the Info.plist without these keys -- both surfaces are
// checked because either could silently drift.

import Foundation
import XCTest
@testable import OstlerInstaller

final class PermissionsPrewarmInfoPlistTest: XCTestCase {

    private static let requiredKeys: [String] = [
        "NSContactsUsageDescription",
        "NSCalendarsFullAccessUsageDescription",
        "NSRemindersFullAccessUsageDescription",
        "NSPhotoLibraryUsageDescription",
    ]

    // MARK: - Info.plist

    func testInfoPlistContainsAllTCCKeysForPrewarmer() throws {
        let url = try StringsCatalogueEmDashTest.repoFile(
            relative: "gui/OstlerInstaller/Info.plist"
        )
        let data = try Data(contentsOf: url)
        guard let plist = try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        ) as? [String: Any] else {
            XCTFail("Info.plist is not a dictionary")
            return
        }
        for key in Self.requiredKeys {
            guard let value = plist[key] as? String else {
                XCTFail("Info.plist missing \(key). The PermissionsPrewarmer at app launch calls the framework API that requires this key; macOS silently denies the prompt if it is absent. Add the string in BOTH Info.plist + gui/project.yml (xcodegen regenerates Info.plist).")
                continue
            }
            XCTAssertFalse(value.isEmpty,
                "Info.plist \(key) is empty. macOS renders this string verbatim in the TCC dialog; an empty string makes the dialog look broken.")
            // Per Apple HIG, usage description should be a complete
            // sentence ending in a period. Not strict-enforced (a
            // period is convention, not a contract), but length is a
            // soft floor -- a 1-word value is almost certainly wrong.
            XCTAssertGreaterThan(value.count, 20,
                "Info.plist \(key) is suspiciously short (\(value.count) chars). The customer reads this in the TCC dialog; the convention is one or two sentences explaining what data we read and where it stays.")
        }
    }

    // MARK: - project.yml (xcodegen)

    /// `xcodegen generate` regenerates the .xcodeproj from project.yml
    /// and re-writes Info.plist's customised keys. If the keys are
    /// in Info.plist but NOT in project.yml, the next regen drops
    /// them silently. Check both surfaces.
    func testProjectYmlContainsAllTCCKeysForPrewarmer() throws {
        let url = try StringsCatalogueEmDashTest.repoFile(
            relative: "gui/project.yml"
        )
        let text = try String(contentsOf: url, encoding: .utf8)
        for key in Self.requiredKeys {
            XCTAssertTrue(text.contains(key),
                "gui/project.yml missing \(key). xcodegen regen would drop this key from Info.plist; the PermissionsPrewarmer would then silently fail to surface its TCC dialog at next build. Add the key to project.yml's info.properties block.")
        }
    }
}
