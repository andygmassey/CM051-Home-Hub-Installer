// SpotifyLiveMode.swift
//
// The Spotify listening poll, app side (CM051 "Spotify ongoing").
//
// WHY THE APP IS THE LAUNCHD PROGRAM. macOS Automation consent belongs to the
// process that sends the Apple event. A bare osascript or Python under launchd
// would ask "python3 wants to control Spotify"; run as this signed app's child
// the question, and the answer, is attributed to the Ostler Installer
// (INFERRED, same reasoning as MusicRefreshMode; the real-box check is a
// console-only walk probe).
//
// LEAST POWER. This mode runs ONE fixed osascript script, the same text
// `python -m ostler_fda.spotify_live script` prints and the Python tests pin.
// It takes no path, command or script from arguments, the environment or any
// file, so launching the app with this flag cannot borrow the app's other
// grants. It judges nothing: rc, stdout and stderr go verbatim into a fixed
// file under ~/.ostler/state/spotify_live/ and the no-TCC apply job
// (vendor/ostler_fda/spotify_live.py) reads them.
//
// NEVER LAUNCHES SPOTIFY. Not running means exit at once, no file written.
// The script itself also opens with the `is not running` guard.
//
// FAIL-OPEN. Every outcome exits 0. Runs before any window or scene exists.

import AppKit
import Foundation

enum SpotifyLiveMode {
    static let flag = "--spotify-poll"
    static let bundleID = "com.spotify.client"
    static let timeoutSeconds: TimeInterval = 15
    /// Must equal ostler_fda.spotify_live.APPLESCRIPT (a Python test compares).
    static let script = """
    if application "Spotify" is not running then return "not_running"
    set sep to (ASCII character 31)
    tell application "Spotify"
      set st to (player state as text)
      if st is "stopped" then return "stopped"
      set t to current track
      return st & sep & (id of t) & sep & (name of t) & sep & (artist of t) & sep & (album of t) & sep & (round (player position)) & sep & (duration of t)
    end tell
    """

    static func isRequested(_ arguments: [String]) -> Bool {
        arguments.count == 2 && arguments[1] == flag
    }

    static func runIfRequested() {
        guard isRequested(CommandLine.arguments) else { return }
        exit(run(home: NSHomeDirectory(), spotifyRunning: isSpotifyRunning()))
    }

    static func isSpotifyRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    /// Testable core. Always returns 0.
    @discardableResult
    static func run(home: String, spotifyRunning: Bool,
                    osascript: String = "/usr/bin/osascript",
                    log: (String) -> Void = { print($0) }) -> Int32 {
        guard spotifyRunning else { return 0 }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: osascript)
        proc.arguments = ["-e", script]
        let out = Pipe(), err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        proc.standardInput = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in done.signal() }
        do { try proc.run() } catch {
            log("spotify-live: could not look (osascript would not start)")
            return 0
        }
        var outData = Data(), errData = Data()
        let readers = DispatchGroup()
        for (pipe, isOut) in [(out, true), (err, false)] {
            readers.enter()
            DispatchQueue.global().async {
                let d = pipe.fileHandleForReading.readDataToEndOfFile()
                if isOut { outData = d } else { errData = d }
                readers.leave()
            }
        }
        if done.wait(timeout: .now() + timeoutSeconds) == .timedOut {
            proc.terminate()
            log("spotify-live: could not look (osascript did not answer in \(Int(timeoutSeconds))s)")
            return 0
        }
        readers.wait()
        let doc: [String: Any] = [
            "schema": 1,
            "polled_at": Date().timeIntervalSince1970,
            "rc": Int(proc.terminationStatus),
            "stdout": String(decoding: outData, as: UTF8.self),
            "stderr": String(decoding: errData, as: UTF8.self),
        ]
        let dir = URL(fileURLWithPath: home)
            .appendingPathComponent(".ostler/state/spotify_live", isDirectory: true)
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            let tmp = dir.appendingPathComponent("poll_out.json.tmp")
            try JSONSerialization.data(withJSONObject: doc).write(to: tmp, options: [.atomic])
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
            _ = try fm.replaceItemAt(dir.appendingPathComponent("poll_out.json"), withItemAt: tmp)
            log("spotify-live: poll answered, handed to the store step")
        } catch {
            log("spotify-live: could not look (could not save the answer)")
        }
        return 0
    }
}
