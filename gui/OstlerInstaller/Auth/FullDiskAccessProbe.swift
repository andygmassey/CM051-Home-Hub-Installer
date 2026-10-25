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
    static let relativePaths: [String] = [
        "Library/Application Support/com.apple.TCC/TCC.db",
        "Library/Safari/History.db",
        "Library/Mail",
        "Library/Messages/chat.db",
        "Library/Application Support/com.apple.sharedfilelist",
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
