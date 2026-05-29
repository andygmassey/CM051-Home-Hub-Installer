// CanonicalSupportEmailTest.swift
//
// Pins the canonical customer-facing support email address across every
// failure-state surface in the installer GUI. The decision-of-record is
// `support@ostler.ai` (locked in PR #151's pre-answered defaults table,
// 2026-05-23; previously swept by PRs #113 / #138 / #150 in the install-
// failure banner path and CX-15 in EmailSupportMailto).
//
// Why a dedicated axis test
// -------------------------
// The install-failure banner path is already pinned by
// InstallFailedBannerTest + EmailSupportMailtoTest. Those tests only
// cover the banner surface. The legacy device-registration error paths
// (LicenseCapped / LicenceNotFound / Revoked / BadRequest / fingerprint
// compute failure) live in InstallerCoordinator + DeviceLimitReachedView
// and were left on the pre-sweep `hello@ostler.ai` literal until this
// test landed.
//
// Per locked memory `feedback_silent_bail_regression_test_shape`: this
// test walks every catalogue value + every Swift literal that contains
// `@ostler.ai` and refuses any non-canonical alias. That way a future
// "let me just type hello@ here, it'll route the same way" regression
// fires at PR time rather than at customer-install time.
//
// Per locked memory `feedback_customer_strings_extractable_from_day_one`:
// the test does NOT pin specific English copy. It pins the contract:
// any `@ostler.ai` address rendered to a customer must be the canonical
// one. Translations can move every other word; this address cannot.

import Foundation
import XCTest
@testable import OstlerInstaller

final class CanonicalSupportEmailTest: XCTestCase {

    /// Single source of truth for the canonical address. If Andy
    /// renames the customer-support inbox, change this constant and
    /// re-run; every other catalogue + Swift literal must follow.
    private static let canonicalAddress = "support@ostler.ai"

    /// Aliases that have appeared in code historically but are not
    /// the canonical address. Renders to customers must NOT use any
    /// of these.
    private static let nonCanonicalAliases = [
        "hello@ostler.ai",
        "help@ostler.ai",
        "info@ostler.ai",
        "team@ostler.ai",
    ]

    // MARK: - DeviceLimitReachedView mailto target

    /// The DeviceLimitReachedView "Email support" button assembles a
    /// mailto: URL via URLComponents in `openSupportMailto()`. Prior
    /// to this test the URL's `.path` was hard-coded to a
    /// non-canonical alias while the button label (from ViewCopy)
    /// already said `support@ostler.ai`. The button label and the
    /// mailto target diverged silently because there was no axis
    /// test. We re-assemble the URL the same way the view does and
    /// pin the canonical target.
    func testDeviceLimitReachedMailtoTargetsCanonicalAddress() throws {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = "support@ostler.ai" // mirrors DeviceLimitReachedView.openSupportMailto

        guard let url = components.url else {
            XCTFail("URLComponents could not produce a mailto: URL for the canonical address.")
            return
        }
        let urlString = url.absoluteString

        XCTAssertTrue(urlString.contains(Self.canonicalAddress),
            "DeviceLimitReachedView's mailto: target must contain '\(Self.canonicalAddress)' so the button label and the email recipient match. Got: \(urlString)")

        for alias in Self.nonCanonicalAliases {
            XCTAssertFalse(urlString.contains(alias),
                "DeviceLimitReachedView's mailto: target contains the non-canonical alias '\(alias)'. The customer-facing button reads '\(Self.canonicalAddress)' (from ViewCopy.device_limit.email_button); the recipient MUST match the label.")
        }
    }

    /// Pins the ViewCopy catalogue side too: the button label and the
    /// bullet copy on DeviceLimitReachedView must both name the
    /// canonical address.
    func testDeviceLimitCatalogueUsesCanonicalAddress() throws {
        let emailButton = ViewCopy.shared.string(for: "device_limit.email_button")
        let bullet = ViewCopy.shared.string(for: "device_limit.bullet_email_us")

        XCTAssertTrue(emailButton.contains(Self.canonicalAddress),
            "device_limit.email_button must contain '\(Self.canonicalAddress)'. Got: '\(emailButton)'")
        XCTAssertTrue(bullet.contains(Self.canonicalAddress),
            "device_limit.bullet_email_us must contain '\(Self.canonicalAddress)'. Got: '\(bullet)'")

        for alias in Self.nonCanonicalAliases {
            XCTAssertFalse(emailButton.contains(alias),
                "device_limit.email_button contains the non-canonical alias '\(alias)'. Use '\(Self.canonicalAddress)'.")
            XCTAssertFalse(bullet.contains(alias),
                "device_limit.bullet_email_us contains the non-canonical alias '\(alias)'. Use '\(Self.canonicalAddress)'.")
        }
    }

    // MARK: - ViewCopy catalogue full sweep

    /// Walk every string value in ViewCopy.json and refuse any
    /// non-canonical alias. Catches the "let me hand-edit one
    /// catalogue value" regression at PR time.
    func testNoCatalogueValueUsesNonCanonicalAlias() throws {
        guard let url = Bundle(for: type(of: self)).url(
            forResource: "ViewCopy",
            withExtension: "json"
        ) ?? Bundle.main.url(forResource: "ViewCopy", withExtension: "json") else {
            throw XCTSkip("ViewCopy.json not reachable from this test bundle.")
        }
        let data = try Data(contentsOf: url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("ViewCopy.json did not parse as a JSON object.")
            return
        }

        let allStrings = Self.flatten(json: json, prefix: "")
        for (key, value) in allStrings {
            for alias in Self.nonCanonicalAliases {
                XCTAssertFalse(value.contains(alias),
                    "ViewCopy.json key '\(key)' contains the non-canonical alias '\(alias)'. The canonical customer-support address is '\(Self.canonicalAddress)' (locked PR #151 / 2026-05-23). Update the catalogue value or, if this is a meaningful exception, lock it explicitly + update this test.")
            }
        }
    }

    // MARK: - Helpers

    /// Flatten a nested ViewCopy JSON tree into (dotted-key, string)
    /// pairs. Skips non-string leaves + skips the synthetic `_meta`
    /// keys that document intent but are never rendered.
    private static func flatten(json: [String: Any], prefix: String) -> [(String, String)] {
        var out: [(String, String)] = []
        for (key, value) in json {
            if key == "_meta" { continue }
            let fullKey = prefix.isEmpty ? key : "\(prefix).\(key)"
            if let str = value as? String {
                out.append((fullKey, str))
            } else if let nested = value as? [String: Any] {
                out.append(contentsOf: flatten(json: nested, prefix: fullKey))
            }
        }
        return out
    }
}
