// AuthorizationHelper.swift
//
// Wrapper around osascript's `do shell script ... with administrator
// privileges` for the ONE privileged window we need during the
// install. install.sh under OSTLER_GUI=1 runs with zero further sudo
// prompts (see InstallerCoordinator + install.sh's OSTLER_GUI=1
// short-circuit of the sudo -v pre-flight); the only root work we do
// is here, in this single AppleScript admin shell, while the user's
// authdb cache is warm from clicking through the macOS native dialog.
//
// HISTORY (Mac Studio retests T-1 to launch):
//
//   retest #2 (2026-05-20 15:30:42): F1 v1 ran `/usr/bin/sudo -v`
//   inside the privileged shell. macOS Sequoia's sudo (1.9.x) uses
//   per-(uid,sid,tty) tickets with tty_tickets default-on. The
//   AppleScript admin shell runs as root with its own sid/tty, so
//   the warmed cache belonged to root's tuple, not the user's. When
//   install.sh later ran `sudo -v` on its own pty, the lookup
//   missed and the install bailed.
//
//   retest #3 + #4 (2026-05-20 ~21:00 + 23:30): F1 v2 tried to
//   write `/var/db/sudo/ts/$ORIG_USER` directly while root. Sequoia
//   sudo binary timestamp records are tuple-keyed (uid + sid + tty
//   + ppid + parent_start) and a zero-byte file is NOT treated as
//   warm on modern sudo. install.sh on its own pty failed the
//   tuple lookup and tripped the gate again.
//
//   retest #5 (2026-05-20 23:42): same gate. The F1 approach is
//   fundamentally unsound on Sequoia + sudo 1.9.x. Option B
//   replaces it: don't try to warm install.sh's sudo cache. Make
//   install.sh not need sudo at all under OSTLER_GUI=1.
//
// OPTION B MECHANICS:
//
//   1. Pre-create the directories root would otherwise need to
//      touch during install.sh. Chown them to the original user so
//      install.sh writes user-side from then on.
//        - /opt/homebrew  -> Homebrew's official installer no
//          longer escalates when the prefix already exists owned
//          by the running user. Combined with NONINTERACTIVE=1
//          on its child invocation, this skips the brew-side
//          sudo dialog too.
//        - /usr/local/bin -> the ostler-knowledge symlink target.
//          Stock macOS leaves /usr/local/bin as root:wheel 755 so
//          `ln -sf` would fail without sudo. Chown moves it to
//          user-writable; we keep the 755 mode so other tools
//          installed there (e.g. Homebrew formulae on Intel) keep
//          working.
//
//   2. The system-wide sleep policy (pmset) is replaced with a
//      per-process `caffeinate -dimsu` started by the Swift
//      parent. caffeinate inherits the user's session and never
//      asks for sudo. See CaffeinateManager.swift.
//
//   3. install.sh's `sudo -v` pre-flight at line 2572 and its 60s
//      keepalive loop at 2625 short-circuit when OSTLER_GUI=1 is
//      set. With Option B (1) + (2) in place, nothing downstream
//      of those calls needs root either.
//
// We still issue `sudo -v` inside the admin shell as belt-and-
// braces in case a future contributor adds a root-needing helper
// that runs DIRECTLY inside this same osascript invocation. That
// cache is root's own and is harmless either way.
//
// $ORIG_USER is read from `stat -f %Su /dev/console` -- the user
// who owns the active GUI session is the user who launched the .app
// from Finder, by definition.
//
// On a sandboxed app this would fail outright; we ship unsandboxed
// with hardened runtime (see project.yml entitlements).

import Foundation
import AppKit

actor AuthorizationHelper {
    static let shared = AuthorizationHelper()

    private var grantedAt: Date? = nil
    private var inFlight: Bool = false

    /// Triggers the macOS admin prompt via AppleScript and uses the
    /// resulting root shell to pre-create + chown the few directories
    /// install.sh would otherwise need sudo to write to (Option B,
    /// see file header). install.sh itself runs un-elevated under
    /// OSTLER_GUI=1 and its sudo pre-flight short-circuits.
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
        // Escape both the prompt and the inner shell command for the
        // AppleScript layer. Single quotes around the inner command
        // are stripped by AppleScript before evaluation.
        let escapedPrompt = prompt
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        // Inner shell. Interpolated into the AppleScript
        // `do shell script "..."` literal below and run as root via
        // `with administrator privileges`.
        //
        // NB: NO double quotes inside this string. Any inner `"`
        // terminates the AppleScript string early and osascript bails
        // silently with no dialog (Studio retest #4 failure
        // 2026-05-20 ~23:30). $ORIG_USER comes from
        // `stat -f %Su /dev/console`, which on supported (single-user,
        // non-corporate-LDAP) macOS installs returns a bare username
        // with no whitespace or shell metachars, so leaving paths
        // unquoted is safe. Every command is pinned to its absolute
        // path so a hostile PATH on the customer's account cannot
        // shadow `chown` etc with a malicious binary.
        //
        // Steps:
        //
        //   1. /usr/bin/sudo -v
        //        Belt-and-braces. Refreshes root's own timestamp so
        //        any helper invoked DIRECTLY inside this osascript
        //        invocation has a warm cache. Option B does not rely
        //        on this for install.sh.
        //
        //   2. ORIG_USER=$(stat -f %Su /dev/console)
        //        The user who owns the active GUI session. On a
        //        single-user macOS install (the only Ostler-supported
        //        topology) this is the user who launched the .app.
        //
        //   3. /opt/homebrew prep
        //        mkdir -p creates the prefix if missing; chown moves
        //        it to the user so Homebrew's own installer skips
        //        its sudo escalation step. Idempotent on re-runs.
        //        Group `admin` matches Homebrew's own default for
        //        /opt/homebrew so formulae installed later see the
        //        expected GID.
        //
        //   4. /usr/local/bin prep
        //        Pre-create + chown for the ostler-knowledge symlink
        //        install.sh creates at line ~4972. Stock macOS leaves
        //        /usr/local/bin as root:wheel 755. We chown it to the
        //        user (keeping 755) so `ln -sf` from install.sh works
        //        without sudo. On Intel Macs where /usr/local is the
        //        Homebrew prefix this matches Homebrew's own chown;
        //        on Apple Silicon /usr/local/bin is otherwise unused
        //        on a fresh Mac so the only consumer is Ostler.
        let innerShell =
            "/usr/bin/sudo -v ; " +
            "ORIG_USER=$(/usr/bin/stat -f %Su /dev/console) ; " +
            "/bin/mkdir -p /opt/homebrew ; " +
            "/usr/sbin/chown $ORIG_USER:admin /opt/homebrew ; " +
            "/bin/chmod 755 /opt/homebrew ; " +
            "/bin/mkdir -p /usr/local/bin ; " +
            "/usr/sbin/chown $ORIG_USER:admin /usr/local/bin ; " +
            "/bin/chmod 755 /usr/local/bin"

        let script = """
        do shell script "\(innerShell)" with prompt "\(escapedPrompt)" with administrator privileges
        """

        let result: Bool = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                task.arguments = ["-e", script]
                task.standardError = Pipe()
                task.standardOutput = Pipe()
                do {
                    try task.run()
                    task.waitUntilExit()
                    continuation.resume(returning: task.terminationStatus == 0)
                } catch {
                    NSLog("osascript launch failed: \(error)")
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
