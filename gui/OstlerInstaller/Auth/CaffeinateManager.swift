// CaffeinateManager.swift
//
// Spawns and supervises a `caffeinate -dimsu` subprocess for the
// duration of the install. Replaces install.sh's `sudo pmset -c sleep 0`
// + `sudo pmset -a womp 1` calls (Option B, 2026-05-21 T-1 Studio
// retest #5 follow-on; carried forward into the 2026-05-22 launch-
// blocker rebase that closes the open #111 conflict against current
// main).
//
// Why caffeinate, not pmset:
//
//   - pmset writes the system-wide sleep policy and requires root.
//     Under the GUI installer that means a downstream sudo prompt
//     fired from install.sh's own pty -- invisible to the user
//     because the log drawer doesn't render TTY password prompts --
//     and that prompt was the Mac Studio retest #5 failure mode and
//     the 2026-05-22 00:42 HKT failure mode that reopened this bug.
//
//   - caffeinate creates a per-process power-assertion via
//     IOPMAssertionCreate. The assertion lives only as long as the
//     calling process. No root required, no system-wide state
//     change, no cleanup on crash beyond the kernel dropping the
//     assertion when the pid exits.
//
// Flags:
//
//   -d   prevent display from sleeping
//   -i   prevent system from idle-sleeping
//   -m   prevent disk from idle-sleeping
//   -s   prevent system from sleeping (AC only; matches install.sh's
//        `pmset -c sleep 0` posture on MacBook hubs where we
//        previously preserved battery sleep)
//   -u   declare user-active, ensuring the screen stays on for the
//        full install window
//
// We deliberately omit -w (wait-for-pid) and -t (timeout) because
// the lifetime is bound to the parent Swift process, which calls
// `stop()` from InstallerCoordinator.handleTermination() on every
// install end path (success, failure, cancel, user quit).
//
// What we lose vs the previous pmset path:
//
//   - Wake-on-network (womp). pmset's `-a womp 1` flag was an
//     install-time nice-to-have that let an asleep machine wake on
//     a magic packet from the iOS Companion's first reach. caffeinate
//     does not configure it. The post-install LaunchAgent + Hub
//     idle-power policy already cover the running case; the
//     install-time gap is bounded (the user is sitting in front
//     of the machine during install, by definition). Documented in
//     PR body so a v1.0.1 follow-on can ship a non-sudo path if
//     customer demand emerges.

import Foundation

/// Manages the lifetime of a single `caffeinate -dimsu` subprocess
/// for the duration of the install. Safe to call `start()` multiple
/// times (idempotent: a running daemon is reused, the second call
/// is a no-op). `stop()` is idempotent and safe to call from a
/// trap handler / deinit / repeated termination notifications.
@MainActor
final class CaffeinateManager {
    static let shared = CaffeinateManager()

    private var process: Process? = nil

    /// Spawn `caffeinate -dimsu` if one is not already running.
    /// Returns the pid on success, nil if launch failed (which is
    /// non-fatal: install.sh will still run, the machine may sleep
    /// mid-install -- we surface a log line so the customer knows).
    @discardableResult
    func start() -> pid_t? {
        if let existing = process, existing.isRunning {
            return existing.processIdentifier
        }

        // Clear out a stale handle from a previous start() that
        // already exited. We do NOT inherit its termination handler
        // because the consumer has either already cleaned up via
        // stop() or is no longer interested.
        process = nil

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        proc.arguments = ["-dimsu"]
        // Detach stdio: caffeinate produces no output on the happy
        // path; we don't want its (empty) pipe sticking around in
        // file-descriptor land for the lifetime of the install.
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        proc.standardInput = FileHandle.nullDevice

        do {
            try proc.run()
            process = proc
            OstlerLog.lifecycle.info("CaffeinateManager: started caffeinate -dimsu pid=\(proc.processIdentifier, privacy: .public)")
            return proc.processIdentifier
        } catch {
            OstlerLog.lifecycle.error("CaffeinateManager: launch failed -- \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Terminate the supervised caffeinate subprocess if running.
    /// Idempotent. Sends SIGTERM, which caffeinate handles cleanly
    /// (its IOPMAssertion is released by the kernel on process
    /// exit either way, so SIGKILL is a non-issue if SIGTERM is
    /// ignored).
    func stop() {
        guard let proc = process else { return }
        if proc.isRunning {
            proc.terminate()
            OstlerLog.lifecycle.info("CaffeinateManager: terminated caffeinate pid=\(proc.processIdentifier, privacy: .public)")
        }
        process = nil
    }

    /// Test seam. Exposes whether a caffeinate subprocess is
    /// currently being supervised. Used by InstallerCoordinator
    /// tests to assert start/stop wiring without spawning a real
    /// caffeinate.
    var isRunning: Bool {
        process?.isRunning ?? false
    }
}
