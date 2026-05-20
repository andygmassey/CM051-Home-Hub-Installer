// PIIRedactorTests.swift
//
// Synthetic fixtures only -- alice@example.com / +447700900000 /
// 10.0.0.5 / andy. No real customer data.
//
// Coverage:
//   * email
//   * phones (E.164 + UK + US + HK)
//   * /Users/<u>/ path
//   * IPv4 (redacted + allowlisted)
//   * IPv6 (redacted + allowlisted)
//   * name redaction (caller-supplied + POSIX login)
//   * technical content preservation (/Applications, /tmp, function
//     names, stack frames, error codes, UUIDs, hex digests)

import XCTest
@testable import OstlerInstaller

final class PIIRedactorTests: XCTestCase {

    // MARK: - Helpers

    private func make(names: [String] = [], login: String = "tester") -> PIIRedactor {
        PIIRedactor(names: names, loginName: login)
    }

    // MARK: - Emails

    func testEmailRedaction() {
        let r = make()
        XCTAssertEqual(
            r.redact("send to alice@example.com please"),
            "send to [redacted-email] please"
        )
    }

    func testEmailWithTagAndCoUk() {
        let r = make()
        XCTAssertEqual(
            r.redact("contact alice.bob+tag@example.co.uk now"),
            "contact [redacted-email] now"
        )
    }

    func testMultipleEmailsInOneLine() {
        let r = make()
        let s = r.redact("from alice@example.com to bob@test.org")
        XCTAssertEqual(s, "from [redacted-email] to [redacted-email]")
    }

    func testNotAnEmailLeftIntact() {
        let r = make()
        XCTAssertEqual(r.redact("path/no.at.symbol"), "path/no.at.symbol")
        // Bare username with no domain stays as-is.
        XCTAssertEqual(r.redact("user@"), "user@")
    }

    // MARK: - Phones

    func testE164UKPhoneRedaction() {
        let r = make()
        XCTAssertEqual(
            r.redact("call +447700900000 now"),
            "call [redacted-phone] now"
        )
    }

    func testE164USPhoneRedaction() {
        let r = make()
        XCTAssertEqual(
            r.redact("dial +12025550150 please"),
            "dial [redacted-phone] please"
        )
    }

    func testUKLocal07PhoneRedaction() {
        let r = make()
        XCTAssertEqual(
            r.redact("ring 07700900111 thanks"),
            "ring [redacted-phone] thanks"
        )
    }

    func testUKLocal020PhoneRedaction() {
        let r = make()
        XCTAssertEqual(
            r.redact("office 02071234567 cheers"),
            "office [redacted-phone] cheers"
        )
    }

    func testUSStylePhoneRedaction() {
        let r = make()
        XCTAssertEqual(
            r.redact("number 555-123-4567 please"),
            "number [redacted-phone] please"
        )
        XCTAssertEqual(
            r.redact("alt (555) 123-4567 too"),
            "alt [redacted-phone] too"
        )
    }

    func testHKLocalPhoneRedaction() {
        let r = make()
        XCTAssertEqual(
            r.redact("hk 91234567 mob"),
            "hk [redacted-phone] mob"
        )
    }

    // MARK: - /Users/<u>/ path

    func testUsersPathRedaction() {
        let r = make()
        XCTAssertEqual(
            r.redact("touch /Users/alice/Documents/foo"),
            "touch /Users/[user]/Documents/foo"
        )
    }

    func testUsersPathSharedIsNotRedacted() {
        let r = make()
        XCTAssertEqual(
            r.redact("write /Users/Shared/installer.log"),
            "write /Users/Shared/installer.log"
        )
    }

    func testUsersPathGuestIsNotRedacted() {
        let r = make()
        XCTAssertEqual(
            r.redact("write /Users/Guest/file"),
            "write /Users/Guest/file"
        )
    }

    func testUsersPathWithoutTrailingSlash() {
        let r = make()
        XCTAssertEqual(
            r.redact("cd /Users/alice and back"),
            "cd /Users/[user] and back"
        )
    }

    // MARK: - IPv4

    func testPrivateIPv4Redacted() {
        let r = make()
        XCTAssertEqual(
            r.redact("host 10.0.0.5 is up"),
            "host [redacted-ip] is up"
        )
        XCTAssertEqual(
            r.redact("home 192.168.1.37 works"),
            "home [redacted-ip] works"
        )
    }

    func testPublicIPv4Redacted() {
        let r = make()
        XCTAssertEqual(
            r.redact("contacted 203.0.113.42 successfully"),
            "contacted [redacted-ip] successfully"
        )
    }

    func testLoopbackIPv4PreservedAsDiagnostic() {
        let r = make()
        XCTAssertEqual(
            r.redact("bound 127.0.0.1 ok"),
            "bound 127.0.0.1 ok"
        )
    }

    func testLinkLocalIPv4PreservedAsDiagnostic() {
        let r = make()
        XCTAssertEqual(
            r.redact("apipa 169.254.10.20 self-assigned"),
            "apipa 169.254.10.20 self-assigned"
        )
    }

    func testMulticastIPv4PreservedAsDiagnostic() {
        let r = make()
        XCTAssertEqual(
            r.redact("mdns 224.0.0.251 sent"),
            "mdns 224.0.0.251 sent"
        )
    }

    func testZeroZeroZeroZeroPreservedAsDiagnostic() {
        let r = make()
        XCTAssertEqual(
            r.redact("listen 0.0.0.0:8080 up"),
            "listen 0.0.0.0:8080 up"
        )
    }

    // MARK: - IPv6

    func testIPv6Redacted() {
        let r = make()
        // Global-form (2001:db8::...) gets redacted.
        XCTAssertEqual(
            r.redact("got 2001:db8::1234 from peer"),
            "got [redacted-ip] from peer"
        )
    }

    func testIPv6LoopbackPreserved() {
        let r = make()
        XCTAssertEqual(
            r.redact("bound ::1 ok"),
            "bound ::1 ok"
        )
    }

    // MARK: - Names

    func testCallerSuppliedNameRedacted() {
        let r = make(names: ["Andy Massey"])
        XCTAssertEqual(
            r.redact("Hi Andy Massey from support"),
            "Hi [redacted-name] from support"
        )
    }

    func testFirstNameAloneRedacted() {
        let r = make(names: ["Andy"])
        XCTAssertEqual(
            r.redact("Hey Andy how are you"),
            "Hey [redacted-name] how are you"
        )
    }

    func testNameWordBoundaryProtected() {
        // "Sandy" must not be redacted just because "Andy" is a name.
        let r = make(names: ["Andy"])
        XCTAssertEqual(
            r.redact("sandy beaches at /Applications"),
            "sandy beaches at /Applications"
        )
    }

    func testPosixLoginRedacted() {
        let r = make(names: [], login: "alex")
        XCTAssertEqual(
            r.redact("user alex hit retry"),
            "user [redacted-name] hit retry"
        )
    }

    func testOneCharLoginNotRedacted() {
        // Defensive: a one-char login would chew the buffer up.
        let r = make(names: [], login: "a")
        XCTAssertEqual(
            r.redact("a quick fox jumps"),
            "a quick fox jumps"
        )
    }

    // MARK: - Technical content preservation

    func testApplicationsPathPreserved() {
        let r = make()
        XCTAssertEqual(
            r.redact("running /Applications/OstlerInstaller.app/Contents/MacOS/OstlerInstaller"),
            "running /Applications/OstlerInstaller.app/Contents/MacOS/OstlerInstaller"
        )
    }

    func testSystemPathPreserved() {
        let r = make()
        XCTAssertEqual(
            r.redact("execve /System/Library/Frameworks/Foundation.framework/Foundation"),
            "execve /System/Library/Frameworks/Foundation.framework/Foundation"
        )
    }

    func testTmpPathPreserved() {
        let r = make()
        XCTAssertEqual(
            r.redact("staged at /tmp/ostler-install.XXXX"),
            "staged at /tmp/ostler-install.XXXX"
        )
    }

    func testFunctionNameStackFramePreserved() {
        let r = make()
        let frame = "OstlerInstaller.InstallerCoordinator.bootstrapAsync() at line 412"
        XCTAssertEqual(r.redact(frame), frame)
    }

    func testErrorCodePreserved() {
        let r = make()
        let line = "exit code 137 (SIGKILL) errno=ENOENT (2)"
        XCTAssertEqual(r.redact(line), line)
    }

    func testUUIDPreserved() {
        let r = make()
        let uuid = "licence 8c7e3f9a-1234-4abc-9def-0123456789ab issued"
        XCTAssertEqual(r.redact(uuid), uuid)
    }

    func testHexDigestPreserved() {
        let r = make()
        let sha = "sha256 0fae3b22c4e07f1a9b8d6c5e4f3a2b1c0fae3b22c4e07f1a9b8d6c5e4f3a2b1c"
        XCTAssertEqual(r.redact(sha), sha)
    }

    // MARK: - Combined sample

    func testCombinedSampleLog() {
        let r = make(names: ["Andy Massey"], login: "andy")
        let input = """
        2026-05-21 02:14:33 [INFO] starting install for Andy Massey
        2026-05-21 02:14:34 [INFO] license file at /Users/andy/Downloads/ostler-licence.json
        2026-05-21 02:14:34 [INFO] notifying support@ostler.ai of run
        2026-05-21 02:14:35 [WARN] hub 192.168.1.37 unreachable; falling back to 127.0.0.1
        2026-05-21 02:14:36 [ERROR] phone +447700900000 push failed
        2026-05-21 02:14:36 [INFO] working dir /tmp/ostler-install.AbCd
        2026-05-21 02:14:37 [INFO] dispatched OstlerInstaller.InstallerCoordinator.bootstrapAsync()
        """
        let output = r.redact(input)

        // What MUST be redacted
        XCTAssertFalse(output.contains("Andy Massey"))
        XCTAssertFalse(output.contains("/Users/andy/"))
        XCTAssertFalse(output.contains("support@ostler.ai"))
        XCTAssertFalse(output.contains("192.168.1.37"))
        XCTAssertFalse(output.contains("+447700900000"))

        // What MUST be preserved
        XCTAssertTrue(output.contains("/Users/[user]/Downloads/ostler-licence.json"))
        XCTAssertTrue(output.contains("[redacted-name]"))
        XCTAssertTrue(output.contains("[redacted-email]"))
        XCTAssertTrue(output.contains("[redacted-ip]"))
        XCTAssertTrue(output.contains("[redacted-phone]"))
        XCTAssertTrue(output.contains("127.0.0.1"))  // diagnostic
        XCTAssertTrue(output.contains("/tmp/ostler-install.AbCd"))
        XCTAssertTrue(output.contains("OstlerInstaller.InstallerCoordinator.bootstrapAsync()"))
        XCTAssertTrue(output.contains("[WARN]"))
        XCTAssertTrue(output.contains("[ERROR]"))
    }

    // MARK: - Lines variant

    func testRedactLinesProcessesEach() {
        let r = make(names: ["Andy"])
        let input = ["hi Andy", "from /Users/andy/x", "ok"]
        XCTAssertEqual(
            r.redactLines(input),
            ["hi [redacted-name]", "from /Users/[user]/x", "ok"]
        )
    }
}
