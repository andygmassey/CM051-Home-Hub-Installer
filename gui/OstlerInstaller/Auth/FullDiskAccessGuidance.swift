// FullDiskAccessGuidance.swift
//
// 118 MUST (F008, F009): two F&F testers on v1.0.117 never saw
// OstlerInstaller in System Settings > Full Disk Access. macOS lists an
// app there only after it has ATTEMPTED a protected read, and the only
// read the gate made before showing the screen was the TCC.db check.
// This helper makes one harmless protected open BEFORE the screen is
// shown (so the app is registered in the list), and carries the pure
// pieces the views use for the fallback (pane URL, translocation test,
// the bundle to reveal in Finder). Every side effect is an injected
// seam so tests never touch real TCC.

import AppKit
import Foundation

enum FullDiskAccessGuidance {

    /// The exact Full Disk Access pane.
    static let paneURLString =
        "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"

    /// Protected path opened (read-only, closed at once, nothing read)
    /// so macOS registers this app in the Full Disk Access list.
    static let registrationProbeRelativePath = "Library/Messages/chat.db"

    /// macOS path randomisation runs a quarantined app from a random read-only
    /// path, so the item the user ticks is not the installed app.
    static func isTranslocated(bundlePath: String) -> Bool {
        bundlePath.contains("/AppTranslocation/")
    }

    /// One protected open, then close. The result is ignored: without
    /// FDA the open fails with EPERM, which is exactly what registers
    /// the app. `open` is the seam (production wraps open(2)).
    static func registerInList(
        home: String,
        open: (String) -> Void = { path in
            let fd = Darwin.open(path, O_RDONLY)
            if fd >= 0 { Darwin.close(fd) }
        }
    ) {
        open((home as NSString).appendingPathComponent(registrationProbeRelativePath))
    }

    /// Gate decision. The registration probe runs BEFORE the access
    /// check and before the caller shows the step. Returns true when
    /// the gate screen must be shown.
    static func gateNeeded(register: () -> Void, hasAccess: () -> Bool) -> Bool {
        register()
        return !hasAccess()
    }

    /// Reveal the running bundle so the user can drag it into the list.
    static func revealRunningBundle(
        bundleURL: URL = Bundle.main.bundleURL,
        reveal: ([URL]) -> Void = { NSWorkspace.shared.activateFileViewerSelecting($0) }
    ) {
        reveal([bundleURL])
    }

    // MARK: - Robust access probe (118 MUST, 117 tester stuck on the gate)
    //
    // The old probe read ONLY TCC.db. If that one read failed for any
    // reason the gate had no way out. Now several FDA-protected paths are
    // tried; ANY successful read is a grant. A path that does not exist
    // is not evidence of denial, and if none exist we say "cannot
    // confirm", never "no access".

    /// Protected paths, relative to the home folder.
    static let accessProbeRelativePaths = [
        "Library/Application Support/com.apple.TCC/TCC.db",
        "Library/Safari/History.db",
        "Library/Mail",
        "Library/Messages/chat.db",
        "Library/Application Support/com.apple.sharedfilelist",
    ]

    enum ProbeResult: Equatable {
        case readable
        case denied(Int32)
        case missing
        case failed(Int32)
    }

    enum AccessVerdict: Equatable {
        case granted
        case denied
        case unverifiable
    }

    struct ProbeFailure: Equatable {
        let relativePath: String
        let errnoValue: Int32
    }

    struct AccessEvaluation: Equatable {
        let verdict: AccessVerdict
        /// Paths that exist but could not be read (path + errno only).
        let failures: [ProbeFailure]
    }

    /// `read` is the seam: given an absolute path, report what a read did.
    static func evaluateAccess(
        home: String,
        read: (String) -> ProbeResult = FullDiskAccessGuidance.readProbe
    ) -> AccessEvaluation {
        var failures: [ProbeFailure] = []
        var anyExisted = false
        for rel in accessProbeRelativePaths {
            switch read((home as NSString).appendingPathComponent(rel)) {
            case .readable:
                return AccessEvaluation(verdict: .granted, failures: [])
            case .denied(let e), .failed(let e):
                anyExisted = true
                failures.append(ProbeFailure(relativePath: rel, errnoValue: e))
            case .missing:
                break
            }
        }
        return AccessEvaluation(verdict: anyExisted ? .denied : .unverifiable, failures: failures)
    }

    private static func classify(_ e: Int32) -> ProbeResult {
        if e == ENOENT || e == ENOTDIR { return .missing }
        return (e == EPERM || e == EACCES) ? .denied(e) : .failed(e)
    }

    /// Production read: stat first (ENOENT = missing), then read one byte
    /// of a file or list one entry of a directory. Nothing is kept.
    static func readProbe(path: String) -> ProbeResult {
        var st = stat()
        if stat(path, &st) != 0 { return classify(errno) }
        if (st.st_mode & S_IFMT) == S_IFDIR {
            guard let dir = opendir(path) else { return classify(errno) }
            defer { closedir(dir) }
            errno = 0
            _ = readdir(dir)
            return errno == 0 ? .readable : classify(errno)
        }
        let fd = Darwin.open(path, O_RDONLY)
        if fd < 0 { return classify(errno) }
        defer { Darwin.close(fd) }
        var byte: UInt8 = 0
        // Without FDA TCC denies the read, not only the open.
        if Darwin.read(fd, &byte, 1) < 0 { return classify(errno) }
        return .readable
    }

    /// Failed rechecks after which the gate offers "Continue anyway".
    static let recheckFailuresBeforeEscape = 2

    /// The escape is offered when access cannot be confirmed at all
    /// (no probe file exists) or after two failed rechecks.
    static func escapeAvailable(verdict: AccessVerdict, failedRechecks: Int) -> Bool {
        switch verdict {
        case .granted: return false
        case .unverifiable: return true
        case .denied: return failedRechecks >= recheckFailuresBeforeEscape
        }
    }

    /// Gate state machine (pure, so tests drive it without the app).
    struct GateState: Equatable {
        private(set) var failedRechecks = 0
        private(set) var offersContinueAnyway = false

        /// Fold in one evaluation. Returns true when access is granted.
        /// `isRecheck` is false for the first check on launch.
        mutating func record(_ evaluation: AccessEvaluation, isRecheck: Bool) -> Bool {
            if evaluation.verdict == .granted { return true }
            if isRecheck { failedRechecks += 1 }
            offersContinueAnyway = FullDiskAccessGuidance.escapeAvailable(
                verdict: evaluation.verdict, failedRechecks: failedRechecks)
            return false
        }
    }

    /// Log line for failed probes: relative paths and errno only.
    static func failureLogLine(_ failures: [ProbeFailure]) -> String {
        failures.map { "\($0.relativePath)=errno\($0.errnoValue)" }.joined(separator: ", ")
    }

    /// Quit and reopen: launch a fresh instance of the installed bundle
    /// (falls back to the running bundle when /Applications has none),
    /// then quit this one. The relaunched app runs the FDA gate on
    /// start, so it resumes at the gate. Returns the URL it launched.
    @discardableResult
    static func quitAndReopen(
        installedURL: URL = URL(fileURLWithPath: "/Applications/OstlerInstaller.app"),
        runningURL: URL = Bundle.main.bundleURL,
        exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) },
        launch: (URL, @escaping () -> Void) -> Void = { url, done in
            let config = NSWorkspace.OpenConfiguration()
            config.createsNewApplicationInstance = true
            NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in done() }
        },
        terminate: @escaping () -> Void = { NSApp.terminate(nil) }
    ) -> URL {
        let target = exists(installedURL) ? installedURL : runningURL
        launch(target, terminate)
        return target
    }
}
