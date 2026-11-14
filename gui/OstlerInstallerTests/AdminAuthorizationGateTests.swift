// AdminAuthorizationGateTests.swift
//
// Pins the pre-launch admin-grant contract added in
// fix/cm051-sudo-install-blocker-2026-05-19. install.sh line 2574
// runs a bare `sudo -v` under OSTLER_GUI=1 with stdin redirected
// to a pipe; on a fresh Mac with no warm sudo timestamp that exits
// non-zero and trips `fail`. The Coordinator must seed the
// timestamp via the macOS-native admin dialog (AuthorizationHelper)
// BEFORE launching install.sh.
//
// Two contract assertions:
//
//   1. Happy path -- the admin-authorisation provider returns true
//      (user clicked Allow + entered password). The Coordinator
//      proceeds to the launch step.
//
//   2. Cancel path -- the provider returns false (user clicked
//      Cancel, or osascript returned non-zero). The Coordinator
//      must NOT proceed to the launch step. `needsAdminRetry`
//      flips true and `error` carries the retry message so the
//      AdminAccessRequiredView surfaces.
//
// Both cases use the DEBUG-only `setAdminAuthorizationProvider(_:)`
// + `setLaunchInstallerOverride(_:)` seams on the Coordinator,
// mirroring the existing test-injection idiom (see
// `setRegistrationClient` / `simulateLineForTests`). No real
// osascript call + no real Process.launch is performed.

import XCTest
@testable import OstlerInstaller

@MainActor
final class AdminAuthorizationGateTests: XCTestCase {

    /// Build a coordinator with the licence + registration gates
    /// already in the "ready to bootstrap" state. We bypass the
    /// production licence-verification path; nothing else in the
    /// test cares whether the claims are real, only that the
    /// guards in `bootstrapAsync()` let us through to the admin
    /// authorisation step.
    private func makeReadyCoordinator() -> InstallerCoordinator {
        // F006: pin the hardware reading. The default reads the HOST,
        // and a CI runner with under 16 GB would gate bootstrap() before
        // the admin step these tests exist to exercise.
        let coord = InstallerCoordinator(systemReadings: .supportedMacForTests)
        coord.licenseVerified = true
        coord.registrationGate = .ready
        // CX-17 (2026-05-23): bootstrap() now also gates on the
        // permissions-intro flow having finished. The existing
        // admin-gate tests don't exercise the prewarm; advance the
        // state machine to .complete so the legacy admin gate is
        // the only remaining surface under test.
        coord.permissionsIntroState = .complete
        return coord
    }

    /// Drives `bootstrap()` -- which spawns a Task -- and waits for
    /// the inner async work to land its state mutations. Polls the
    /// main run loop for up to `timeout` seconds, returning early
    /// once `condition` flips true. Mirrors the "pump RunLoop"
    /// idiom that XCTest uses for `expectation(forKeyPath:)` but
    /// stays explicit so the test is readable.
    private func waitFor(
        _ condition: @MainActor () -> Bool,
        timeout: TimeInterval = 2.0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 20_000_000) // 20 ms
        }
        XCTFail("Timed out waiting for condition", file: file, line: line)
    }

    // MARK: - Phase 1: park at acknowledgement gate

    func testBootstrapParksAtAcknowledgementGate() async {
        // F3 (Studio retest #2 2026-05-20): bootstrap() must park
        // at `needsAdminAcknowledgement = true` rather than firing
        // the dialog immediately. The provider must NOT be invoked
        // until the customer presses the Continue button.
        let coord = makeReadyCoordinator()

        var providerCalled = false
        var launchCalled = false

        coord.setAdminAuthorizationProvider { _ in
            providerCalled = true
            return true
        }
        coord.setLaunchInstallerOverride { launchCalled = true }

        coord.bootstrap()
        await waitFor { coord.needsAdminAcknowledgement }

        XCTAssertTrue(coord.needsAdminAcknowledgement,
                      "bootstrap must park at the acknowledgement gate")
        XCTAssertFalse(providerCalled,
                       "admin provider MUST NOT fire until the customer acknowledges")
        XCTAssertFalse(launchCalled,
                       "launch step MUST NOT fire until the customer acknowledges")
        XCTAssertFalse(coord.needsAdminRetry)
    }

    // MARK: - Happy path: ack -> grant -> launch

    func testAcknowledgementProceedsToLaunch() async {
        let coord = makeReadyCoordinator()

        var providerCalled = false
        var launchCalled = false
        let promptReason = ViewCopy.shared.string(
            for: "admin_access_required.prompt_reason"
        )
        var capturedReason: String? = nil

        coord.setAdminAuthorizationProvider { reason in
            providerCalled = true
            capturedReason = reason
            return true
        }
        coord.setLaunchInstallerOverride {
            launchCalled = true
        }

        coord.bootstrap()
        await waitFor { coord.needsAdminAcknowledgement }
        coord.userAcknowledgedAdminRequest()
        await waitFor { launchCalled }

        XCTAssertTrue(providerCalled,
                      "admin authorisation provider must be invoked before launch")
        XCTAssertEqual(capturedReason, promptReason,
                       "provider must receive the catalogue prompt-reason string verbatim")
        XCTAssertTrue(launchCalled,
                      "launch step must run once admin grant succeeds")
        XCTAssertFalse(coord.needsAdminRetry,
                       "needsAdminRetry must stay false on happy path")
        XCTAssertFalse(coord.needsAdminAcknowledgement,
                       "acknowledgement gate must clear after the customer proceeds")
        XCTAssertNil(coord.error,
                     "error surface must stay clear on happy path")
    }

    // MARK: - Cancel path

    func testAdminCancelHoldsAtRetryGate() async {
        let coord = makeReadyCoordinator()

        var providerCalled = false
        var launchCalled = false

        coord.setAdminAuthorizationProvider { _ in
            providerCalled = true
            return false   // user clicked Cancel in the macOS dialog
        }
        coord.setLaunchInstallerOverride {
            launchCalled = true
        }

        coord.bootstrap()
        await waitFor { coord.needsAdminAcknowledgement }
        coord.userAcknowledgedAdminRequest()
        await waitFor { coord.needsAdminRetry }

        XCTAssertTrue(providerCalled,
                      "admin authorisation provider must be invoked once the customer acknowledges")
        XCTAssertFalse(launchCalled,
                       "launch step must NOT run when admin grant is declined")
        XCTAssertTrue(coord.needsAdminRetry,
                      "needsAdminRetry must latch true so AdminAccessRequiredView renders")
        XCTAssertEqual(coord.error,
                       ViewCopy.shared.string(for: "admin_access_required.retry_message"),
                       "error surface must carry the retry message from the catalogue")
    }

    // MARK: - Retry after cancel

    func testRetryAfterCancelReinvokesProviderAndLaunches() async {
        let coord = makeReadyCoordinator()

        var providerCalls = 0
        var launchCalled = false

        coord.setAdminAuthorizationProvider { _ in
            providerCalls += 1
            // First call: user-cancel. Second call (post-Retry): user
            // grants. The Coordinator's retry path must re-invoke the
            // provider; the helper's internal 240s cache exists but
            // is not exercised here because we replace the provider
            // entirely with this closure.
            return providerCalls >= 2
        }
        coord.setLaunchInstallerOverride {
            launchCalled = true
        }

        coord.bootstrap()
        await waitFor { coord.needsAdminAcknowledgement }
        coord.userAcknowledgedAdminRequest()
        await waitFor { coord.needsAdminRetry }
        XCTAssertEqual(providerCalls, 1)
        XCTAssertFalse(launchCalled)

        coord.retryAdminAuthorization()
        await waitFor { launchCalled }

        XCTAssertEqual(providerCalls, 2,
                       "retry must re-invoke the admin authorisation provider")
        XCTAssertTrue(launchCalled,
                      "second grant must let the launch step run")
        XCTAssertFalse(coord.needsAdminRetry,
                       "needsAdminRetry must clear after a successful retry")
        XCTAssertNil(coord.error,
                     "error surface must clear after a successful retry")
    }

    // MARK: - Duplicate-fire guard (F2)

    func testDoubleBootstrapDoesNotDoubleFireProvider() async {
        // F2: pre-fix the Studio retest #2 log showed two
        // "Requesting administrator access via macOS native dialog"
        // entries in the same second. Drive bootstrap() twice
        // rapidly and assert the provider only fires once across
        // the ack + launch flow.
        let coord = makeReadyCoordinator()

        var providerCalls = 0
        var launchCalls = 0
        coord.setAdminAuthorizationProvider { _ in
            providerCalls += 1
            // Sleep briefly so a second concurrent caller has time
            // to land its guard check before we resolve.
            try? await Task.sleep(nanoseconds: 50_000_000)
            return true
        }
        coord.setLaunchInstallerOverride { launchCalls += 1 }

        coord.bootstrap()
        coord.bootstrap()
        await waitFor { coord.needsAdminAcknowledgement }
        // Now fire the ack twice in flight -- the second call must
        // short-circuit on `requestingAdmin`.
        coord.userAcknowledgedAdminRequest()
        coord.userAcknowledgedAdminRequest()
        await waitFor { launchCalls >= 1 }
        // Give any pending Task a beat to land its mutations
        // before asserting we don't see a duplicate.
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(providerCalls, 1,
                       "admin provider must fire exactly once even under double-call")
        XCTAssertEqual(launchCalls, 1,
                       "launch step must fire exactly once even under double-call")
    }

    // MARK: - AppleScript quoting (Studio retest #8 regression guard)

    /// Pins the escape behaviour that lets `do shell script` survive
    /// inner-shell commands containing embedded double quotes. Before
    /// 2026-05-21 the inner shell was interpolated raw, so a path
    /// like `"/var/db/sudo/ts/$ORIG_USER"` closed the AppleScript
    /// string early. osascript exited with parse error -2741 instantly
    /// and the coordinator surfaced "admin authorisation declined or
    /// failed" without a password prompt ever appearing.
    func testEscapeForAppleScriptLiteralEscapesDoubleQuoteAndBackslash() {
        XCTAssertEqual(
            escapeForAppleScriptLiteral("/var/db/sudo/ts/$U"),
            "/var/db/sudo/ts/$U",
            "shell-expansion sigils pass through untouched"
        )
        XCTAssertEqual(
            escapeForAppleScriptLiteral("touch \"/var/db/sudo/ts/$U\""),
            "touch \\\"/var/db/sudo/ts/$U\\\"",
            "embedded double quotes must be escaped to \\\""
        )
        XCTAssertEqual(
            escapeForAppleScriptLiteral("a\\b"),
            "a\\\\b",
            "literal backslashes must be doubled before quotes are escaped"
        )
        XCTAssertEqual(
            escapeForAppleScriptLiteral("\\\""),
            "\\\\\\\"",
            "backslash-escape ordering survives mixed input"
        )
    }

    /// Pins the assembled AppleScript shape so a future refactor
    /// cannot silently reintroduce the unescaped-inner-shell bug.
    func testBuildAuthorizationAppleScriptEscapesEmbeddedQuotes() {
        let innerShell = "/usr/bin/touch \"/var/db/sudo/ts/$U\""
        let prompt = "Ostler needs administrator access. \"reason\""
        let script = buildAuthorizationAppleScript(innerShell: innerShell, prompt: prompt)

        // Both literals must appear with their double quotes escaped
        // so the AppleScript string does not close early.
        XCTAssertTrue(
            script.contains("/usr/bin/touch \\\"/var/db/sudo/ts/$U\\\""),
            "inner-shell double quotes must land escaped in the assembled script. Got: \(script)"
        )
        XCTAssertTrue(
            script.contains("administrator access. \\\"reason\\\""),
            "prompt double quotes must land escaped in the assembled script. Got: \(script)"
        )
        XCTAssertTrue(
            script.contains("with administrator privileges"),
            "assembled script must end with the admin-privileges clause"
        )
        // The pre-fix bug: raw interpolation left the inner-shell's
        // double quotes unescaped, producing
        //   `do shell script "/usr/bin/touch "/var/db/...`
        // i.e. the AppleScript do-shell-script string opened, ran
        // /usr/bin/touch and then closed on the inner shell's `"`.
        // Scan the assembled script byte-by-byte and refuse to find
        // any unescaped `"` between the do-shell-script opening
        // quote and its closing one. `osacompile -e <script>` is
        // the authoritative parser but pulling it into the test
        // suite adds a process-spawn dependency; this scanner is a
        // cheap structural guard.
        XCTAssertTrue(
            assembledScriptHasBalancedAppleScriptStrings(script),
            "assembled script must keep the AppleScript string literals balanced. Got: \(script)"
        )
    }

    /// Walks `script` and confirms every double quote inside an open
    /// AppleScript string literal is preceded by a `\` escape. Returns
    /// false if the literal closes early, which is exactly the failure
    /// shape the unescaped-inner-shell bug produced.
    private func assembledScriptHasBalancedAppleScriptStrings(_ script: String) -> Bool {
        var inString = false
        var prev: Character = " "
        var openCount = 0
        var closeCount = 0
        for c in script {
            if c == "\"" && prev != "\\" {
                if inString {
                    closeCount += 1
                } else {
                    openCount += 1
                }
                inString.toggle()
            }
            prev = c
        }
        return !inString && openCount == closeCount && openCount >= 2
    }

    // MARK: - Option B inner-shell shape (2026-05-22 LAUNCH BLOCKER regression)

    /// Pins the Option B inner-shell shape. The 2026-05-22 00:42 HKT
    /// Studio retest LAUNCH BLOCKER fired because install.sh's
    /// `sudo -v` pre-flight ran on the GUI subprocess with no TTY,
    /// sudo refused to prompt, and the install bailed. Option B
    /// makes install.sh not require sudo at all under OSTLER_GUI=1.
    /// For that to work, AuthorizationHelper's privileged shell MUST
    /// pre-create /opt/homebrew + /usr/local/bin owned by the user.
    ///
    /// A future contributor reverting to the touch-based sudo-
    /// timestamp seed (which never worked on Sequoia sudo 1.9.x's
    /// tuple-keyed records, see retests #2-#5 + #8) regresses the
    /// launch blocker. This test refuses that revert.
    func testAuthorizationInnerShellPreCreatesHomebrewAndUserLocalBin() {
        // Re-build the same script the production actor would build.
        // We cannot await the actor (its inner shell is built inside
        // a private function), but we know the contract: the inner
        // shell must contain the brew-dir chown + user-local-bin
        // chown commands, AND it must NOT contain the deprecated
        // touch-based timestamp seed.
        let innerShell = buildAdminInnerShell(resourcePath: "/Applications/OstlerInstaller.app/Contents/Resources")

        // Create-only Homebrew prefix, for the owner, and only when absent.
        XCTAssertTrue(
            innerShell.contains("if [ ! -e /opt/homebrew ]; then /bin/mkdir /opt/homebrew && /usr/sbin/chown $ORIG_USER:admin /opt/homebrew"),
            "/opt/homebrew must be created for the owner only when it does not exist"
        )
        // Never chown /usr/local/bin (root-owned on stock macOS), never chown an existing prefix.
        XCTAssertFalse(innerShell.contains("/usr/local/bin"), "the admin shell must not touch /usr/local/bin")
        XCTAssertFalse(innerShell.contains("chown $ORIG_USER:admin /opt/homebrew ;"),
                       "the admin shell must not chown an existing /opt/homebrew")

        // Refuse the deprecated touch-based timestamp seed (retests #2-#5).
        // sudo 1.9.x on Sequoia tuple-keys timestamp records by
        // (uid, sid, tty, ppid, parent_start), so touch'ing
        // /var/db/sudo/ts/$ORIG_USER from root's session never
        // warms the user's pty-bound cache. A future contributor
        // re-adding this strategy regresses the launch blocker.
        XCTAssertFalse(
            innerShell.contains("/var/db/sudo/ts"),
            "Option B forbids the touch-based sudo-timestamp seed under /var/db/sudo/ts -- it never worked on Sequoia sudo 1.9.x"
        )

        // Inner shell must remain quote-free so the AppleScript
        // string literal stays balanced without needing the PR #125
        // escape function's interpolation transform. The escape is
        // present in `buildAuthorizationAppleScript` for future
        // contributors but the Option B inner shell deliberately
        // does not depend on it. Byte-walk the inner shell looking
        // for `"`; refuse to find any.
        XCTAssertFalse(
            innerShell.contains("\""),
            "Option B inner shell must contain zero double quotes so the AppleScript string literal stays balanced without escape-dependence"
        )

        // The assembled script also passes the balanced-strings
        // assertion (mirrors testBuildAuthorizationAppleScriptEscapesEmbeddedQuotes).
        let prompt = "Ostler needs administrator access. Pre-create Homebrew + PATH directories."
        let script = buildAuthorizationAppleScript(innerShell: innerShell, prompt: prompt)
        XCTAssertTrue(
            assembledScriptHasBalancedAppleScriptStrings(script),
            "Option B assembled script must keep the AppleScript string literals balanced. Got: \(script)"
        )
    }

    // MARK: - CX-6: in-process execution (2026-05-22 dialog-title fix)

    /// Pins the in-process NSAppleScript execution path. Studio retest #7
    /// (2026-05-22) showed the admin password dialog reading "osascript
    /// wants to make changes" because the AppleScript was executed via
    /// `Process()` shelling out to `/usr/bin/osascript`. macOS
    /// Authorization Services attributes the dialog to the calling
    /// process, so the dialog credited osascript.
    ///
    /// Fix: execute the same AppleScript IN-process via `NSAppleScript`.
    /// The calling process is then OstlerInstaller itself, so the
    /// dialog reads "OstlerInstaller wants to make changes".
    ///
    /// This test refuses any revert that reintroduces the
    /// `/usr/bin/osascript` Process shell-out from AuthorizationHelper.
    /// The byte-by-byte source scan mirrors the shape contract used by
    /// `testBuildAuthorizationAppleScriptEscapesEmbeddedQuotes` and the
    /// pattern locked in `feedback_silent_bail_regression_test_shape`.
    func testAuthorizationHelperDoesNotShellOutToOsascript() throws {
        // Resolve the source file via __FILE__-style path arithmetic so
        // the test stays valid wherever the test bundle is copied to at
        // run time. AuthorizationHelper.swift sits one directory up
        // from the test target's source tree.
        let testFileURL = URL(fileURLWithPath: #filePath)
        let helperURL = testFileURL
            .deletingLastPathComponent()      // OstlerInstallerTests/
            .deletingLastPathComponent()      // gui/
            .appendingPathComponent("OstlerInstaller/Auth/AuthorizationHelper.swift")

        let source = try String(contentsOf: helperURL, encoding: .utf8)

        // Refuse the Process-shell-out shape. The two refusal markers
        // together pin the exact failure shape so a future contributor
        // cannot accidentally reintroduce either half (osascript path
        // OR Process() executable-URL invocation against it).
        XCTAssertFalse(
            source.contains("/usr/bin/osascript"),
            "CX-6: AuthorizationHelper must not shell out to /usr/bin/osascript -- the macOS Authorization dialog would then credit osascript, not OstlerInstaller. Use NSAppleScript in-process instead."
        )
        XCTAssertFalse(
            source.contains("URL(fileURLWithPath: \"/usr/bin/osascript\")"),
            "CX-6: AuthorizationHelper must not construct a Process executableURL pointing at /usr/bin/osascript -- the macOS Authorization dialog would then credit osascript."
        )

        // Require the in-process NSAppleScript shape. NSAppleScript runs
        // the same `do shell script ... with administrator privileges`
        // directive but executes inside our process, so the dialog
        // credits OstlerInstaller.
        XCTAssertTrue(
            source.contains("NSAppleScript(source: script)"),
            "CX-6: AuthorizationHelper must execute the AppleScript via NSAppleScript(source:) so the admin dialog credits OstlerInstaller."
        )
        XCTAssertTrue(
            source.contains("executeAndReturnError"),
            "CX-6: AuthorizationHelper must use NSAppleScript.executeAndReturnError(_:) to receive the AppleScript error dictionary on cancel/failure."
        )
    }

    /// v1.0.126 loopback guard: the admin shell installs it from the bundle,
    /// with the resource path quoted, for the console user's uid.
    func testAdminInnerShellInstallsTheLoopbackGuardFromTheBundle() {
        let shell = buildAdminInnerShell(resourcePath: "/Volumes/Ostler Installer/OstlerInstaller.app/Contents/Resources")
        let lib = "'/Volumes/Ostler Installer/OstlerInstaller.app/Contents/Resources/lib/ostler-loopback-guard.sh'"
        XCTAssertTrue(shell.contains("/bin/bash " + lib + " install-root $(/usr/bin/id -u $ORIG_USER) " + lib),
                      "the admin shell must run the bundled guard's install-root for the console user")
        XCTAssertTrue(shell.hasPrefix("/usr/bin/sudo -v ; "), "the existing Option B work still runs first")
    }

    /// A path that cannot be single-quoted is never run as root; install.sh
    /// then fails closed on the missing guard instead.
    func testAdminInnerShellOmitsTheGuardForAnUnquotablePath() {
        XCTAssertFalse(buildAdminInnerShell(resourcePath: "/tmp/it's/Resources").contains("loopback-guard"))
        XCTAssertFalse(buildAdminInnerShell(resourcePath: nil).contains("loopback-guard"))
    }

    /// RED on the pre-change shell: it chowned /opt/homebrew and /usr/local/bin unconditionally.
    /// A foreign-owned prefix must produce the refusal and no chown is possible from the shell.
    func testForeignOwnedHomebrewIsRefusedWithoutAChown() {
        let refusal = sharedHomebrewRefusal(prefixOwnerUID: 502, currentUID: 501)
        XCTAssertNotNil(refusal, "a prefix owned by another account must be refused")
        XCTAssertTrue(refusal?.contains("belongs to another account") ?? false)
        XCTAssertFalse(refusal?.contains("502") ?? true, "the refusal must not name the other account")
        XCTAssertNil(sharedHomebrewRefusal(prefixOwnerUID: 501, currentUID: 501), "the owner's own prefix proceeds")
        XCTAssertNil(sharedHomebrewRefusal(prefixOwnerUID: nil, currentUID: 501), "an absent prefix proceeds (fresh Mac)")
    }

    /// Mutant: the refusal is bypassed and the shell chowns an existing prefix. Must be caught.
    func testChownOfExistingPrefixIsNotInTheShell() {
        let shell = buildAdminInnerShell(resourcePath: nil)
        XCTAssertFalse(shell.contains("/usr/sbin/chown $ORIG_USER:admin /opt/homebrew ;"))
        XCTAssertFalse(shell.contains("/bin/mkdir -p /opt/homebrew"))
    }
}
