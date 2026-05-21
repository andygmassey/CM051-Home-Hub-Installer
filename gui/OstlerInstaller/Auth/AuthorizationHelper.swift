// AuthorizationHelper.swift
//
// Wrapper around osascript's `do shell script ... with administrator
// privileges` for the FIRST sudo grant. install.sh's existing
// keepalive loop refreshes the timestamp every 60s so we only need
// to seed it once.
//
// 2026-05-20 (Studio retest #2 failure at 15:30:42): PR #95 wired
// AuthorizationHelper into `bootstrap()` and ran `/usr/bin/sudo -v`
// inside the privileged shell. Root cause we missed: when AppleScript
// elevates via `with administrator privileges`, the inner command
// runs AS ROOT, not as the original user. `sudo -v` then writes its
// timestamp under `/var/db/sudo/ts/root/`, not the invoking user's
// directory. Two minutes later install.sh's bare `sudo -v` at line
// 2583 runs AS THE USER, finds a cold cache, and trips
// `fail $MSG_FAIL_NEED_SUDO_ACCESS_DISABLE_SLEEP_INSTALL`.
//
// The fix is to write the user's timestamp file directly while we
// have root. sudo accepts an empty/touched timestamp file as warm
// (sudo(8): "An empty file is interpreted as an updated timestamp
// equal to the file's mtime"), so a single `touch` of
// `/var/db/sudo/ts/$ORIGINAL_USER` does the job. We also keep the
// `sudo -v` call so root's cache is warm for any helper sub-process
// install.sh might spawn under root (belt-and-braces).
//
// $ORIGINAL_USER is read from `stat -f %Su /dev/console` -- the user
// who owns the active GUI session is the user who launched the .app
// from Finder, by definition.
//
// On a sandboxed app this would fail outright; we ship unsandboxed
// with hardened runtime (see project.yml entitlements).

import Foundation
import AppKit
import os

/// Escape a string for embedding inside an AppleScript double-quoted
/// literal. AppleScript strings accept `\"` for an embedded double
/// quote and `\\` for a literal backslash; everything else passes
/// through. Exposed at file scope so the test target can pin the
/// escape behaviour against future regressions.
internal func escapeForAppleScriptLiteral(_ value: String) -> String {
    value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
}

/// Build the AppleScript that drives the macOS admin password
/// prompt. Both `innerShell` and `prompt` are escaped for the
/// AppleScript string literal before interpolation so any embedded
/// double quote (e.g. shell-expanded paths like
/// `"/var/db/sudo/ts/$ORIG_USER"`) does not close the string early.
/// Exposed at file scope for unit testing.
internal func buildAuthorizationAppleScript(innerShell: String, prompt: String) -> String {
    let escapedInnerShell = escapeForAppleScriptLiteral(innerShell)
    let escapedPrompt = escapeForAppleScriptLiteral(prompt)
    return """
    do shell script "\(escapedInnerShell)" with prompt "\(escapedPrompt)" with administrator privileges
    """
}

actor AuthorizationHelper {
    static let shared = AuthorizationHelper()

    private var grantedAt: Date? = nil
    private var inFlight: Bool = false

    /// Triggers the macOS admin prompt via AppleScript + uses the
    /// resulting root shell to seed the original user's sudo
    /// timestamp file. install.sh's bare `sudo -v` at line 2583
    /// then finds it warm and proceeds silently; the keepalive loop
    /// refreshes it every 60s for the rest of the install.
    ///
    /// Returns true if the user granted, false if cancelled or if
    /// a recent grant is still warm.
    @discardableResult
    func requestAdminAuthorization(reason: String) async -> Bool {
        // De-dupe: if we asked in the last 4 minutes, the cached
        // sudo timestamp is still valid (default 5 min).
        if let granted = grantedAt, Date().timeIntervalSince(granted) < 240 {
            return true
        }
        if inFlight { return false }
        inFlight = true
        defer { inFlight = false }

        let prompt = "Ostler needs administrator access. \(reason)"
        // Inner shell. Runs as root via `with administrator privileges`.
        // Script construction (and its escape rules) live in
        // `buildAuthorizationAppleScript` so the test target can pin
        // the escape behaviour.
        //
        // 2026-05-21 Studio retest #8 silent-bail root cause: the
        // pre-fix build interpolated `innerShell` raw, so the inner
        // shell's double-quoted paths broke out of the AppleScript
        // string. osascript exited with parse error -2741 ("Expected
        // expression but found unknown token") instantly, with no
        // password prompt. The Swift code read
        // `task.terminationStatus != 0`, returned false, and the
        // coordinator surfaced "admin authorisation declined or
        // failed" with no further detail. The pre-fix code also
        // discarded the captured stderr; the diagnostic-logging
        // hunk below makes future failures of this shape visible
        // through the `ai.ostler.installer` os_log subsystem.
        //
        //   1. /usr/bin/sudo -v
        //        Belt: refreshes root's own timestamp. Cheap insurance
        //        for any helper invoked under the privileged shell.
        //
        //   2. ORIG_USER=$(stat -f %Su /dev/console)
        //        The user who owns the active GUI session. On a
        //        single-user macOS install (the only Ostler-supported
        //        topology) this is the user who launched the .app.
        //
        //   3. mkdir -p /var/db/sudo/ts && chmod 700 /var/db/sudo/ts
        //        Defensive: directory exists by default on macOS but
        //        not on a freshly imaged Mac before any sudo run.
        //
        //   4. touch /var/db/sudo/ts/$ORIG_USER
        //      chmod 600 /var/db/sudo/ts/$ORIG_USER
        //      chown root:wheel /var/db/sudo/ts/$ORIG_USER
        //        sudo(8) accepts a fresh-mtime file in this directory
        //        as a warm timestamp. No binary format required. The
        //        chmod / chown bring permissions into line with sudo's
        //        own writes so a later real sudo run does not refuse
        //        the file as "tampered" (sudo checks 0600 + root:wheel
        //        on each access).
        let innerShell =
            "/usr/bin/sudo -v ; " +
            "ORIG_USER=$(/usr/bin/stat -f %Su /dev/console) ; " +
            "/bin/mkdir -p /var/db/sudo/ts ; " +
            "/bin/chmod 700 /var/db/sudo/ts ; " +
            "/usr/bin/touch \"/var/db/sudo/ts/$ORIG_USER\" ; " +
            "/bin/chmod 600 \"/var/db/sudo/ts/$ORIG_USER\" ; " +
            "/usr/sbin/chown root:wheel \"/var/db/sudo/ts/$ORIG_USER\""

        let script = buildAuthorizationAppleScript(innerShell: innerShell, prompt: prompt)

        let result: Bool = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                task.arguments = ["-e", script]
                let stderrPipe = Pipe()
                let stdoutPipe = Pipe()
                task.standardError = stderrPipe
                task.standardOutput = stdoutPipe
                do {
                    try task.run()
                    task.waitUntilExit()
                    let exitCode = task.terminationStatus
                    if exitCode != 0 {
                        // Capture stderr so the next failure mode of
                        // this shape (parse error, TCC denial,
                        // entitlement regression) is visible in the
                        // unified log under `ai.ostler.installer`,
                        // not just in NSLog under the default
                        // subsystem. Truncate to keep large
                        // AppleScript dumps from spamming the log
                        // pipeline. User-cancel produces exit 1 with
                        // a benign "User canceled" stderr message;
                        // we log at debug level for that case and
                        // error level for everything else.
                        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                        let stderr = String(data: stderrData, encoding: .utf8)?
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            ?? ""
                        let stderrExcerpt = stderr.count > 512
                            ? String(stderr.prefix(512)) + "...(truncated)"
                            : stderr
                        let isUserCancel = stderr.contains("User canceled")
                            || stderr.contains("User cancelled")
                            || stderr.contains("(-128)")
                        if isUserCancel {
                            OstlerLog.lifecycle.debug("osascript admin prompt cancelled by user (exit \(exitCode, privacy: .public))")
                        } else {
                            OstlerLog.lifecycle.error("osascript admin prompt failed: exit=\(exitCode, privacy: .public) stderr=\(stderrExcerpt, privacy: .public)")
                        }
                    }
                    continuation.resume(returning: exitCode == 0)
                } catch {
                    OstlerLog.lifecycle.error("osascript spawn failed before run: \(error.localizedDescription, privacy: .public)")
                    continuation.resume(returning: false)
                }
            }
        }

        if result {
            grantedAt = Date()
        }
        return result
    }

    /// Open the System Settings deep-link for the Privacy > Full Disk
    /// Access pane. Used by the FDA orchestration sheet.
    nonisolated func openFullDiskAccessPane() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
        DispatchQueue.main.async {
            NSWorkspace.shared.open(url)
        }
    }
}
