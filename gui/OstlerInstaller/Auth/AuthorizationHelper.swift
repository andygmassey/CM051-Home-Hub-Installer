// AuthorizationHelper.swift
//
// Wrapper around osascript's `do shell script ... with administrator
// privileges` for the FIRST sudo grant. install.sh's existing
// keepalive loop (line 1553) refreshes the timestamp every 60s so we
// only need to seed it once.
//
// Why osascript and not AuthorizationServices? AuthorizationServices
// gives a tighter sheet but requires the helper to either be set-uid
// or use SMJobBless (which is itself a notarisation pit and was
// deprecated for SMAppService). For Phase 1 the goal is a working
// admin grant with the smallest signing/entitlements surface.
//
// On a sandboxed app this would fail outright; we ship unsandboxed
// with hardened runtime (see project.yml entitlements).

import Foundation
import AppKit

actor AuthorizationHelper {
    static let shared = AuthorizationHelper()

    private var grantedAt: Date? = nil
    private var inFlight: Bool = false

    /// Triggers the macOS admin prompt by running a no-op `sudo -v`
    /// inside an AppleScript shell. install.sh's keepalive loop
    /// then refreshes the sudo timestamp every 60s.
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

        let script = """
        do shell script "/usr/bin/sudo -v" with prompt "\(escapedPrompt)" with administrator privileges
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
