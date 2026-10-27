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
}
