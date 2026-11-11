// FullDiskAccessProbe.swift
//
// Full Disk Access detection for the up-front FDA gate.
//
// WHY several probes: the gate used to read ONLY the user TCC.db. On
// macOS 27 that file does not exist, so the probe returned false for every
// customer, FDA granted or not, and the gate had no way out. A missing
// probe file says nothing about access, so each probe reports one of
// three outcomes and only "denied" counts against the customer:
//
//   readable : the protected read worked        -> FDA is on
//   denied   : the path exists, the read failed -> FDA is off (errno kept)
//   missing  : the path is not there            -> no information
//
// FDA is on if ANY probe is readable. If nothing is readable and nothing
// is denied (every probe missing) the result is inconclusive, and the
// gate must not claim the customer lacks access.
//
// Logs carry paths and errno only, never file contents.

import Foundation
import AppKit

enum FDAReadOutcome: Equatable {
    case readable
    case denied(errno: Int32)
    case missing
}

/// File-access seam so the probe logic is testable without touching the
/// real protected folders of the machine running the tests.
protocol FDAFileAccess {
    func readOutcome(atPath path: String) -> FDAReadOutcome
}

/// Real implementation: stat, then open and read one byte (file) or
/// opendir (directory). Reads nothing beyond one byte, keeps nothing.
struct SystemFDAFileAccess: FDAFileAccess {
    func readOutcome(atPath path: String) -> FDAReadOutcome {
        var st = stat()
        if stat(path, &st) != 0 {
            let e = errno
            return e == ENOENT || e == ENOTDIR ? .missing : .denied(errno: e)
        }
        if (st.st_mode & S_IFMT) == S_IFDIR {
            guard let dir = opendir(path) else { return .denied(errno: errno) }
            closedir(dir)
            return .readable
        }
        let fd = open(path, O_RDONLY)
        if fd < 0 {
            let e = errno
            return e == ENOENT ? .missing : .denied(errno: e)
        }
        defer { close(fd) }
        var byte: UInt8 = 0
        // TCC denies the read itself on some paths, not only the open.
        return read(fd, &byte, 1) >= 0 ? .readable : .denied(errno: errno)
    }
}

struct FDAProbeResult: Equatable {
    let path: String
    let outcome: FDAReadOutcome
}

struct FDAProbeReport: Equatable {
    let results: [FDAProbeResult]

    /// FDA is on: at least one protected read succeeded.
    var granted: Bool { results.contains { $0.outcome == .readable } }
    /// At least one probe path exists and refused the read.
    var anyDenied: Bool {
        results.contains { if case .denied = $0.outcome { return true } else { return false } }
    }
    /// Nothing readable and nothing denied: every probe file is absent,
    /// so we know nothing. Must not be reported as "no access".
    var inconclusive: Bool { !granted && !anyDenied }
    /// Probes that did not read, as "path (errno N)" or "path (missing)".
    var failureLines: [String] {
        results.compactMap { r in
            switch r.outcome {
            case .readable: return nil
            case .denied(let e): return "\(r.path) (errno \(e))"
            case .missing: return "\(r.path) (missing)"
            }
        }
    }
}

enum FullDiskAccessProbe {
    /// Paths relative to the home folder. Each is FDA-protected where it exists.
    /// Only known FDA-protected paths belong here: a path that can be read
    /// without FDA (e.g. com.apple.sharedfilelist) would report a false grant.
    static let relativePaths: [String] = [
        "Library/Application Support/com.apple.TCC/TCC.db",
        "Library/Safari/History.db",
        "Library/Mail",
        "Library/Messages/chat.db",
    ]

    static func run(home: String, access: FDAFileAccess) -> FDAProbeReport {
        let results = relativePaths.map { rel -> FDAProbeResult in
            let path = (home as NSString).appendingPathComponent(rel)
            return FDAProbeResult(path: path, outcome: access.readOutcome(atPath: path))
        }
        return FDAProbeReport(results: results)
    }
}

/// Gate state machine, kept free of UI so tests drive it directly.
struct FDAGateState: Equatable {
    /// Rechecks after which "Continue anyway" appears.
    static let rechecksBeforeEscape = 2

    private(set) var failedRechecks = 0
    var showContinueAnyway: Bool { failedRechecks >= Self.rechecksBeforeEscape }

    enum Decision: Equatable { case proceed, hold }

    /// First probe at launch. Granted or inconclusive proceeds; only a
    /// positive denial holds the gate.
    func launchDecision(_ report: FDAProbeReport) -> Decision {
        report.granted || report.inconclusive ? .proceed : .hold
    }

    /// The "I've switched it on" button. Counts a failure only for a
    /// positive denial.
    mutating func recheck(_ report: FDAProbeReport) -> Decision {
        if launchDecision(report) == .proceed { return .proceed }
        failedRechecks += 1
        return .hold
    }
}

/// Auto-advance on grant. The gate polls the probe every 2 seconds and
/// feeds each report here. Returns true exactly once: on the first tick
/// where a protected read succeeds. A denial or an inconclusive report
/// (every probe file absent) never advances.
struct FDAGrantWatch: Equatable {
    private(set) var fired = false

    mutating func tick(_ report: FDAProbeReport) -> Bool {
        guard !fired, report.granted else { return false }
        fired = true
        return true
    }
}

/// The app the customer must add to Full Disk Access. The probe reads
/// from this process, so the bundle that owns this process's executable
/// is the one macOS needs listed. The gate drags exactly this bundle.
enum FDAHandoff {
    static func appBundleURL(_ bundle: Bundle = .main) -> URL {
        bundle.bundleURL
    }

    /// The customer-facing name, as System Settings lists the app: the
    /// display name ("Ostler Installer"), then the bundle name, then the
    /// file name without ".app".
    static func displayName(_ bundle: Bundle = .main) -> String {
        if let shown = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String, !shown.isEmpty {
            return shown
        }
        if let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String, !name.isEmpty {
            return name
        }
        return appBundleURL(bundle).deletingPathExtension().lastPathComponent
    }

    /// Ostler itself (OstlerAssistant.app): the program that reads Messages,
    /// Mail and the rest at runtime. It travels inside this installer; nil when
    /// the installer was built without it. macOS grants Full Disk Access to the
    /// app's code identity, so the copy install.sh later stages under ~/.ostler
    /// is the same program to macOS as this one.
    static func assistantBundleURL(_ bundle: Bundle = .main) -> URL? {
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["OSTLER_DEBUG_FDA_ASSISTANT_APP"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        #endif
        let url = bundle.bundleURL.appendingPathComponent("Contents/Resources/ostler-payload/assistant-agent/OstlerAssistant.app")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Customer-facing name of the app at `url` ("Ostler"), read from its own
    /// Info.plist, falling back to the file name.
    static func displayName(ofAppAt url: URL) -> String {
        if let b = Bundle(url: url) { return displayName(b) }
        return url.deletingPathExtension().lastPathComponent
    }

    /// The app's icon as a bitmap with `pixels` x `pixels` real pixels, shown
    /// at `points` x `points`. `NSWorkspace.icon(forFile:)` returns a
    /// multi-representation image whose 32pt-ish default size is then scaled
    /// up by SwiftUI, which is what made the tile soft on Retina. Drawing it
    /// once into a bitmap at 4x the largest size it is shown at lets every
    /// use scale DOWN, which stays sharp.
    static func icon(forFile path: String, points: CGFloat, pixels: Int) -> NSImage {
        let source = NSWorkspace.shared.icon(forFile: path)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return source }
        rep.size = NSSize(width: points, height: points)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return source }
        NSGraphicsContext.current = ctx
        ctx.imageInterpolation = .high
        source.draw(in: NSRect(x: 0, y: 0, width: points, height: points),
                    from: .zero, operation: .sourceOver, fraction: 1,
                    respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
        let out = NSImage(size: NSSize(width: points, height: points))
        out.addRepresentation(rep)
        return out
    }

    /// A drag source that carries the bundle's file URL, so dropping it on
    /// the Full Disk Access list adds this app and nothing else.
    static func dragProvider(for url: URL) -> NSItemProvider {
        NSItemProvider(contentsOf: url) ?? NSItemProvider(object: url as NSURL)
    }
}
