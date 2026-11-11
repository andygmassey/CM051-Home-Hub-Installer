// FDAFlow.swift
//
// Which Full Disk Access screen the installer shows.
//
// macOS 27.3 and later: apps can no longer add themselves to the Full Disk
// Access list, so the customer is handed the apps to drag in
// (FullDiskAccessDragGateView). On anything earlier the existing gate
// (FullDiskAccessGateView) runs exactly as it always did.

import Foundation

enum FDAFlow {
    /// First macOS release that gets the drag-to-grant screen. The only place
    /// the threshold is written down.
    static let dragScreenMinimum = OperatingSystemVersion(majorVersion: 27, minorVersion: 3, patchVersion: 0)

    /// True when `version` is at or past the threshold.
    static func usesDragScreen(version: OperatingSystemVersion) -> Bool {
        let a = version, b = dragScreenMinimum
        if a.majorVersion != b.majorVersion { return a.majorVersion > b.majorVersion }
        if a.minorVersion != b.minorVersion { return a.minorVersion > b.minorVersion }
        return a.patchVersion >= b.patchVersion
    }

    /// "27.3" or "27.2.1" as a version; nil when it is not numeric.
    static func parse(_ text: String) -> OperatingSystemVersion? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard (1...3).contains(parts.count), !parts.contains(where: { $0 == nil || $0! < 0 }) else { return nil }
        let n = parts.map { $0! }
        return OperatingSystemVersion(majorVersion: n[0], minorVersion: n.count > 1 ? n[1] : 0,
                                      patchVersion: n.count > 2 ? n[2] : 0)
    }

    /// The macOS version the choice is made on. Debug builds only: the
    /// OSTLER_DEBUG_MACOS_VERSION environment variable (e.g. "27.3") stands in
    /// for the real version, so both screens can be tested on any Mac.
    static func currentVersion(environment: [String: String] = ProcessInfo.processInfo.environment,
                               real: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion)
        -> OperatingSystemVersion {
        #if DEBUG
        if let text = environment["OSTLER_DEBUG_MACOS_VERSION"], let v = parse(text) { return v }
        #endif
        return real
    }

    static func usesDragScreen() -> Bool {
        usesDragScreen(version: currentVersion())
    }
}
