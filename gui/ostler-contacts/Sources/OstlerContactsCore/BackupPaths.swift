import Foundation

/// Pure path / timestamp derivation for the Contacts backup (BW-A §3).
///
/// None of this touches CNContactStore or requires TCC, so it is fully
/// unit-testable. The live read lives in the `ostler-contacts` executable
/// target.
public enum BackupPaths {

    /// The user-facing backups root: `~/Documents/Ostler/Backups/Contacts`.
    ///
    /// Per spec §3 the backup MUST live in the user-facing zone (alongside
    /// the Wiki), NOT in the hidden `~/.ostler`, so the user can find and
    /// double-click it. `homeDirectory` is injectable for tests.
    public static func backupsRoot(homeDirectory: URL) -> URL {
        homeDirectory
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("Ostler", isDirectory: true)
            .appendingPathComponent("Backups", isDirectory: true)
            .appendingPathComponent("Contacts", isDirectory: true)
    }

    /// ISO-8601-ish timestamp safe for use as a directory name.
    ///
    /// A literal ISO-8601 string contains colons, which are legal on APFS
    /// but display as `/` in Finder and are awkward in shells. We keep it
    /// chronologically sortable and filesystem-clean: `2026-06-19T140532Z`.
    /// `date` is injectable so tests are deterministic.
    public static func sessionTimestamp(date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date)
        return String(
            format: "%04d-%02d-%02dT%02d%02d%02dZ",
            c.year ?? 0, c.month ?? 0, c.day ?? 0,
            c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    /// The per-session directory for one Tidy session's backup.
    public static func sessionDirectory(homeDirectory: URL, date: Date) -> URL {
        backupsRoot(homeDirectory: homeDirectory)
            .appendingPathComponent(sessionTimestamp(date: date), isDirectory: true)
    }

    /// Full path of the all-contacts vCard within a session directory.
    ///
    /// Spec §3 names the file `AllContacts.vcf`.
    public static func vcardFile(in sessionDirectory: URL) -> URL {
        sessionDirectory.appendingPathComponent("AllContacts.vcf", isDirectory: false)
    }

    /// Full path of the integrity manifest within a session directory.
    public static func manifestFile(in sessionDirectory: URL) -> URL {
        sessionDirectory.appendingPathComponent("manifest.json", isDirectory: false)
    }
}
