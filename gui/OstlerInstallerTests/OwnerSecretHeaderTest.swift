// OwnerSecretHeaderTest.swift
//
// CB137: the pair-code mint is owner-only. GatewayClient must send the owner
// secret as X-Ostler-Owner on the POST mint, read at call time from
// ~/.ostler/secrets/owner_token, and must not send the mint when the secret
// cannot be read. Source-shape guard in the style of PairingQRAutoShowTest.

import XCTest
@testable import OstlerInstaller

final class OwnerSecretHeaderTest: XCTestCase {

    private func loadGatewayClientSource() throws -> String {
        let url = try StringsCatalogueEmDashTest.repoFile(
            relative: "gui/OstlerInstaller/GatewayClient.swift"
        )
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testMintSendsOwnerHeaderOnPostOnly() throws {
        let src = try loadGatewayClientSource()
        XCTAssertTrue(
            src.contains(#"req.setValue(owner, forHTTPHeaderField: "X-Ostler-Owner")"#),
            "GatewayClient must send the owner secret as X-Ostler-Owner (CB137)."
        )
        XCTAssertTrue(
            src.contains("if fresh {"),
            "The owner header must be gated to the POST mint (fresh), not the GET read."
        )
    }

    func testOwnerSecretPathIsTheInstallerFile() throws {
        let src = try loadGatewayClientSource()
        XCTAssertTrue(
            src.contains(#".ostler/secrets/owner_token"#),
            "The owner secret must be read from ~/.ostler/secrets/owner_token, not service_token."
        )
        XCTAssertFalse(
            src.contains("service_token"),
            "The owner gate must never read service_token (distinct credential)."
        )
    }

    func testMissingOwnerSecretFailsClosedBeforeSend() throws {
        let src = try loadGatewayClientSource()
        XCTAssertTrue(
            src.contains("owner = try Self.readOwnerSecret(from: ownerSecretURL)"),
            "The mint must read the owner secret before URLSession sends anything."
        )
        XCTAssertTrue(
            src.contains("owner_secret_missing") && src.contains("owner_secret_empty"),
            "Missing and empty owner secrets must each be named, not silently sent."
        )
    }
}
