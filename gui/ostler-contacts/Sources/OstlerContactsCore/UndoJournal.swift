import Foundation

/// Per-merge undo journal (spec §6, contract rule 6).
///
/// JOURNAL-FIRST ordering is the core crash-safety property: the helper
/// appends the undo entry BEFORE issuing the CNSaveRequest. The save is then
/// the only thing that can be lost; the undo record is durable first. If the
/// process dies between the journal append and the save, the worst case is
/// an undo entry for a merge that never happened (harmless: undo restores
/// the survivor to a value it already has and re-creates victims that were
/// never deleted, which a re-run's group_hash check detects). The
/// catastrophic case the ordering eliminates is a completed delete with no
/// undo record.
///
/// This type is PURE (Codable + file append); it does not touch
/// CNContactStore and is fully unit-testable.
public struct UndoEntry: Codable, Equatable {
    /// ISO-8601 instant the entry was written.
    public let ts: String
    /// Full pre-merge vCard of the survivor, so undo can restore it exactly.
    public let survivorBeforeVcard: String
    /// Full pre-merge vCards of each victim, so undo can re-create them.
    public let victimsVcards: [String]
    /// The survivor's CNContact identifier.
    public let survivorID: String
    /// The victims' CNContact identifiers (pre-delete; re-created victims get
    /// NEW identifiers on undo, see §6 caveat).
    public let victimIDs: [String]
    /// The confirm-token / group hash this merge was authorised under.
    public let groupHash: String
    /// Path to the session's full-Contacts vCard backup (the coarse floor).
    public let backupPath: String

    public init(
        ts: String,
        survivorBeforeVcard: String,
        victimsVcards: [String],
        survivorID: String,
        victimIDs: [String],
        groupHash: String,
        backupPath: String
    ) {
        self.ts = ts
        self.survivorBeforeVcard = survivorBeforeVcard
        self.victimsVcards = victimsVcards
        self.survivorID = survivorID
        self.victimIDs = victimIDs
        self.groupHash = groupHash
        self.backupPath = backupPath
    }

    enum CodingKeys: String, CodingKey {
        case ts
        case survivorBeforeVcard = "survivor_before_vcard"
        case victimsVcards = "victims_vcards"
        case survivorID = "survivor_id"
        case victimIDs = "victim_ids"
        case groupHash = "group_hash"
        case backupPath = "backup_path"
    }

    /// Encode as a single NDJSON line (no embedded newlines: JSON escapes
    /// any newlines inside the vCard strings, so one entry is exactly one
    /// physical line).
    public func ndjsonLine() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard let line = String(data: data, encoding: .utf8) else {
            throw UndoJournalError.encodingFailed
        }
        return line
    }
}

public enum UndoJournalError: Error, CustomStringConvertible {
    case encodingFailed
    case journalNotFound(String)
    case journalEmpty(String)
    case malformedLine(Int)

    public var description: String {
        switch self {
        case .encodingFailed:
            return "failed to encode undo entry to JSON"
        case .journalNotFound(let p):
            return "undo journal not found at \(p)"
        case .journalEmpty(let p):
            return "undo journal at \(p) has no entries"
        case .malformedLine(let n):
            return "undo journal line \(n) is malformed JSON"
        }
    }
}

/// Append-only NDJSON journal writer/reader.
public enum UndoJournal {

    /// The journal file for a session lives beside the session backup.
    public static func journalFile(in sessionDirectory: URL) -> URL {
        sessionDirectory.appendingPathComponent("journal.ndjson", isDirectory: false)
    }

    /// Append one entry as an NDJSON line, creating the file if needed.
    ///
    /// This uses an atomic-ish append (open-for-append + write + fsync) so a
    /// crash cannot leave a half-written line ahead of the save. The fsync is
    /// what makes "journal-first" a durability guarantee rather than a
    /// best-effort flush.
    public static func append(_ entry: UndoEntry, to journalURL: URL) throws {
        let line = try entry.ndjsonLine() + "\n"
        let data = Data(line.utf8)

        let fm = FileManager.default
        try fm.createDirectory(
            at: journalURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)

        if !fm.fileExists(atPath: journalURL.path) {
            fm.createFile(atPath: journalURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: journalURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        // Force the line to durable storage BEFORE the caller proceeds to
        // the CNSaveRequest. This is the journal-first crash-safety hinge.
        try handle.synchronize()
    }

    /// Read every entry from a journal file (oldest first).
    public static func readAll(from journalURL: URL) throws -> [UndoEntry] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: journalURL.path) else {
            throw UndoJournalError.journalNotFound(journalURL.path)
        }
        let raw = try String(contentsOf: journalURL, encoding: .utf8)
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: true)
        guard !lines.isEmpty else {
            throw UndoJournalError.journalEmpty(journalURL.path)
        }
        let decoder = JSONDecoder()
        var entries: [UndoEntry] = []
        for (i, line) in lines.enumerated() {
            guard let data = line.data(using: .utf8) else {
                throw UndoJournalError.malformedLine(i + 1)
            }
            do {
                entries.append(try decoder.decode(UndoEntry.self, from: data))
            } catch {
                throw UndoJournalError.malformedLine(i + 1)
            }
        }
        return entries
    }
}
