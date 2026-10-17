// MusicRefreshMode.swift
//
// The scheduled Apple Music refresh, app side (CM051, Andy 2026-10-15,
// "please don't let that slip").
//
// WHY THE APP, AND NOT THE HELPER, IS THE LAUNCHD PROGRAM
// -------------------------------------------------------
// "Media & Apple Music" (kTCCServiceMediaLibrary) was granted by the
// customer to THIS app during the permissions step. The bundled
// ostler-music-library helper reads as the app's descendant at install
// time, so the read is attributed to the app. A LaunchAgent whose program
// is the bare helper would be attributed to the helper itself, which
// holds no grant (INFERRED, see docs/APPLE_MUSIC_REFRESH_TCC.md; the
// real-box check is a console-only walk probe). So the agent's program
// is this app's own executable with `--music-refresh`, and the helper
// runs as its child, the same ancestry as at install.
//
// LEAST POWER. This mode runs ONE fixed thing: the bundled helper, from
// Bundle.main's own Resources. It takes no path, command or script from
// arguments, the environment or any file, so launching the app with this
// flag cannot be used to borrow the app's other grants (Contacts,
// Calendar, Photos). It writes the helper's JSON to a fixed file under
// ~/.ostler/state/music_refresh/ and exits. Storing is a separate job
// with no TCC need (vendor/ostler_fda/apple_music_refresh.py).
//
// NEVER PROMPTS IN THE BACKGROUND. macOS has no public status call for
// this service, so the install arms the refresh (writes `armed`) only
// after its own native read succeeded. Not armed: this mode exits at
// once without touching the framework.
//
// FAIL-OPEN. Every outcome exits 0 and logs one line: `could not look`
// with a reason, or the counts-free `read ok`. Runs BEFORE any window or
// SwiftUI scene exists, so nothing appears on screen or in the Dock.

import Foundation

enum MusicRefreshMode {
    static let flag = "--music-refresh"
    static let helperName = "ostler-music-library"
    static let timeoutSeconds: TimeInterval = 180

    /// True only for exactly `OstlerInstaller --music-refresh`.
    static func isRequested(_ arguments: [String]) -> Bool {
        arguments.count == 2 && arguments[1] == flag
    }

    /// Called first thing from the app's init. Returns normally for every
    /// launch except the scheduled one, which never returns.
    static func runIfRequested() {
        guard isRequested(CommandLine.arguments) else { return }
        exit(run(home: NSHomeDirectory(), helper: Bundle.main.resourceURL?
            .appendingPathComponent(helperName)))
    }

    /// Testable core. Always returns 0.
    @discardableResult
    static func run(home: String, helper: URL?, log: (String) -> Void = { print($0) }) -> Int32 {
        let dir = URL(fileURLWithPath: home)
            .appendingPathComponent(".ostler/state/music_refresh", isDirectory: true)
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.appendingPathComponent("armed").path) else {
            log("music-refresh: could not look (not armed; the install has not confirmed the Apple Music permission)")
            return 0
        }
        guard let helper = helper, fm.isExecutableFile(atPath: helper.path) else {
            log("music-refresh: could not look (helper missing)")
            return 0
        }
        let proc = Process()
        proc.executableURL = helper
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        proc.standardInput = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in done.signal() }
        do { try proc.run() } catch {
            log("music-refresh: could not look (helper would not start)")
            return 0
        }
        // Drain stdout while it runs so a large library cannot fill the pipe.
        var data = Data()
        let reader = DispatchQueue(label: "music-refresh.read")
        let readDone = DispatchSemaphore(value: 0)
        reader.async {
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            readDone.signal()
        }
        if done.wait(timeout: .now() + timeoutSeconds) == .timedOut {
            proc.terminate()
            log("music-refresh: could not look (helper did not answer in \(Int(timeoutSeconds))s)")
            return 0
        }
        readDone.wait()
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            let tmp = dir.appendingPathComponent("helper_out.json.tmp")
            try data.write(to: tmp, options: [.atomic])
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
            _ = try fm.replaceItemAt(dir.appendingPathComponent("helper_out.json"), withItemAt: tmp)
            log("music-refresh: helper answered, handed to the store step")
        } catch {
            log("music-refresh: could not look (could not save the answer)")
        }
        return 0
    }
}
