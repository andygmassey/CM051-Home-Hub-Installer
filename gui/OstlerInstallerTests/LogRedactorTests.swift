// LogRedactorTests.swift
//
// Synthetic-fixture coverage of every category the LogRedactor
// masks before an install log reaches support@ostler.ai via the
// failure-banner "Email support" button or "Copy redacted log"
// button.
//
// Per locked memory `feedback_synthetic_fixtures_no_real_data_default`:
// every fixture in this file is synthetic. Phone numbers use
// +15551234567 (the classic North-American test-prefix), emails use
// example.com (RFC 2606 reserved TLD), IP addresses use the RFC
// documentation ranges (192.0.2.0/24 IPv4 per RFC 5737, 2001:db8::/32
// IPv6 per RFC 3849). API-key fixtures are obvious test strings
// ("test_token_AAAA" suffix). Names are fictional ("John Doe").
//
// Each test asserts two things byte-for-byte:
//   1. The redactor's input DID contain the secret pattern.
//   2. The redactor's output does NOT.
//
// The two-sided assertion guards against a "test passes because the
// fixture forgot the secret" silent regression.
//
// Per locked memory `feedback_silent_bail_regression_test_shape`:
// removing a redactor category would fail-loud here on the next CI
// run, point-and-click.

import Foundation
import XCTest
@testable import OstlerInstaller

final class LogRedactorTests: XCTestCase {

    // MARK: - UUID v4 (licence IDs, fingerprints)

    func testRedactsUuidV4() {
        let input = "Licence id 00000000-0000-4000-8000-000000000000 failed verification."
        let output = LogRedactor.redact(input)
        XCTAssertTrue(input.contains("00000000-0000-4000-8000-000000000000"))
        XCTAssertFalse(output.contains("00000000-0000-4000-8000-000000000000"))
        XCTAssertTrue(output.contains("\u{27E8}uuid\u{27E9}"))
    }

    // MARK: - Email

    func testRedactsEmail() {
        let input = "Customer alice@example.com hit a verify error."
        let output = LogRedactor.redact(input)
        XCTAssertTrue(input.contains("alice@example.com"))
        XCTAssertFalse(output.contains("alice@example.com"))
        XCTAssertTrue(output.contains("\u{27E8}email\u{27E9}"))
    }

    // MARK: - Phone (E.164)

    func testRedactsE164Phone() {
        let input = "WhatsApp recipient +15551234567 set."
        let output = LogRedactor.redact(input)
        XCTAssertTrue(input.contains("+15551234567"))
        XCTAssertFalse(output.contains("+15551234567"))
        XCTAssertTrue(output.contains("\u{27E8}phone\u{27E9}"))
    }

    // MARK: - IPv4

    func testRedactsIpv4() {
        // RFC 5737 documentation prefix.
        let input = "Hub reachable at 192.0.2.1 (LAN)."
        let output = LogRedactor.redact(input)
        XCTAssertTrue(input.contains("192.0.2.1"))
        XCTAssertFalse(output.contains("192.0.2.1"))
        XCTAssertTrue(output.contains("\u{27E8}ip\u{27E9}"))
    }

    // MARK: - IPv6

    func testRedactsIpv6() {
        // RFC 3849 documentation prefix.
        let input = "Hub reachable at 2001:db8::1 (IPv6)."
        let output = LogRedactor.redact(input)
        XCTAssertTrue(input.contains("2001:db8::1"))
        XCTAssertFalse(output.contains("2001:db8::1"))
        XCTAssertTrue(output.contains("\u{27E8}ip\u{27E9}"))
    }

    // MARK: - /Users/<name>/ path

    func testRedactsUserPath() {
        let input = "Wrote /Users/testuser/Documents/foo.json."
        let output = LogRedactor.redact(input)
        XCTAssertTrue(input.contains("/Users/testuser/"))
        XCTAssertFalse(output.contains("/Users/testuser/"))
        // The /Documents/foo.json tail is preserved by design --
        // only the username is redacted, not the rest of the path.
        XCTAssertTrue(output.contains("/Users/\u{27E8}user\u{27E9}/Documents/foo.json"))
    }

    // MARK: - API-key shapes

    func testRedactsAnthropicApiKey() {
        let input = "Header: Authorization Bearer sk-ant-test-token-AAAAAAAAAAAAAAAAAAAA"
        let output = LogRedactor.redact(input)
        XCTAssertTrue(input.contains("sk-ant-test-token-AAAAAAAAAAAAAAAAAAAA"))
        XCTAssertFalse(output.contains("sk-ant-test-token-AAAAAAAAAAAAAAAAAAAA"))
        XCTAssertTrue(output.contains("\u{27E8}api-key\u{27E9}"))
    }

    func testRedactsOpenAiApiKey() {
        // 40-char `sk-` token shape that the OpenAI regex matches
        // (and the Anthropic regex does NOT pre-consume because
        // it requires the `sk-ant-` prefix).
        let input = "Token sk-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA captured."
        let output = LogRedactor.redact(input)
        XCTAssertTrue(input.contains("sk-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"))
        XCTAssertFalse(output.contains("sk-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"))
        XCTAssertTrue(output.contains("\u{27E8}api-key\u{27E9}"))
    }

    func testRedactsGithubPatTokenGhp() {
        let input = "Cloning with token ghp_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        let output = LogRedactor.redact(input)
        XCTAssertTrue(input.contains("ghp_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"))
        XCTAssertFalse(output.contains("ghp_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"))
        XCTAssertTrue(output.contains("\u{27E8}api-key\u{27E9}"))
    }

    func testRedactsGithubOauthTokenGho() {
        let input = "Auth header gho_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        let output = LogRedactor.redact(input)
        XCTAssertTrue(input.contains("gho_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"))
        XCTAssertFalse(output.contains("gho_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"))
        XCTAssertTrue(output.contains("\u{27E8}api-key\u{27E9}"))
    }

    func testRedactsGithubFineGrainedPat() {
        let input = "Bearer github_pat_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        let output = LogRedactor.redact(input)
        XCTAssertTrue(input.contains("github_pat_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"))
        XCTAssertFalse(output.contains("github_pat_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"))
        XCTAssertTrue(output.contains("\u{27E8}api-key\u{27E9}"))
    }

    // MARK: - Name shape (two capitalised words)

    func testRedactsTwoCapitalisedWords() {
        // Synthetic name. Deliberately not a real customer.
        let input = "Subject: John Doe wants help."
        let output = LogRedactor.redact(input)
        XCTAssertTrue(input.contains("John Doe"))
        XCTAssertFalse(output.contains("John Doe"))
        XCTAssertTrue(output.contains("\u{27E8}name\u{27E9}"))
    }

    // MARK: - Multi-category line

    func testRedactsMultipleCategoriesInOneLine() {
        // The realistic case: one log line carries several
        // secret shapes. Confirm every category gets stripped.
        let input = "POST /api alice@example.com from /Users/testuser/Library/Logs token=ghp_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA ip=192.0.2.1"
        let output = LogRedactor.redact(input)
        XCTAssertFalse(output.contains("alice@example.com"))
        XCTAssertFalse(output.contains("/Users/testuser/"))
        XCTAssertFalse(output.contains("ghp_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"))
        XCTAssertFalse(output.contains("192.0.2.1"))
        // Order of substitution matters for non-overlapping patterns;
        // confirm at least one of each replacement landed.
        XCTAssertTrue(output.contains("\u{27E8}email\u{27E9}"))
        XCTAssertTrue(output.contains("\u{27E8}user\u{27E9}"))
        XCTAssertTrue(output.contains("\u{27E8}api-key\u{27E9}"))
        XCTAssertTrue(output.contains("\u{27E8}ip\u{27E9}"))
    }

    // MARK: - Pass-through guard

    func testEmptyInputRoundTrips() {
        XCTAssertEqual(LogRedactor.redact(""), "")
    }

    func testCleanInputUnchanged() {
        // A line that contains no secret shapes should pass through
        // byte-for-byte. Guards against an over-eager future regex
        // that would corrupt clean log output.
        let input = "Phase 3 step ollama_install begin"
        XCTAssertEqual(LogRedactor.redact(input), input)
    }
}
