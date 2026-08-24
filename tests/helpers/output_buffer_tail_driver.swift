// output_buffer_tail_driver.swift
//
// Driver for tests/test_installer_output_keeps_the_tail.sh. Compiled by plain
// `swiftc` alongside gui/OstlerInstaller/OutputLineBuffer.swift -- no Xcode
// project, no signing, no downloads.
//
// Two accumulators, ONE driver:
//
//   fixed     the shipping OutputLineBuffer
//   headonly  the PRE-FIX truncation and bound, transcribed verbatim from
//             OutputLineBuffer.swift as it stood at 19bd9a09
//
// `headonly` is the positive control, and it is not decoration. The property
// under test is "the failure text survives", and a harness that cannot show a
// build in which it does NOT survive is a harness that would go green against
// the defect. Every assertion in the shell test is run against BOTH.
//
// Usage: driver <fixed|headonly> <longline_err|bound_then_err|wide|hang>
// Prints: lines=<n> line_bytes=<n> contains_error=<bool> dropped=<n>
//         retained=<n> notice=<bool>

import Foundation

// ── The PRE-FIX truncation and bound, verbatim. DO NOT "improve" it. ──
// OutputLineBuffer.swift @ 19bd9a09:
//
//     private mutating func enforceBound() {
//         let held = buffer.utf8.count
//         guard held > maxBufferBytes else { return }
//         droppedBytes += held
//         pendingDropNotice += held
//         buffer = ""
//     }
//
//     private mutating func finish(_ line: String) -> String {
//         var out = line
//         let n = out.utf8.count
//         if n > maxLineBytes {
//             out = String(out.prefix(maxLineBytes))
//                 + " [... \(n - maxLineBytes) more bytes truncated]"
//         }
//         ...
//     }
struct HeadOnlyLineBuffer {
    let maxBufferBytes: Int
    let maxLineBytes: Int
    private(set) var buffer = ""
    private(set) var droppedBytes = 0
    private var pendingDropNotice = 0

    init(maxBufferBytes: Int = 1 << 20, maxLineBytes: Int = 64 * 1024) {
        self.maxBufferBytes = maxBufferBytes
        self.maxLineBytes = maxLineBytes
    }

    mutating func ingest(_ chunk: String) -> [String] {
        let parts = chunk.split(omittingEmptySubsequences: false,
                                whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == "\r\n" })
        guard let tail = parts.last else { return [] }
        if parts.count == 1 {
            buffer.append(contentsOf: tail)
            enforceBound()
            return []
        }
        var lines: [String] = []
        buffer.append(contentsOf: parts[0])
        if !buffer.isEmpty { lines.append(finish(buffer)) }
        buffer = ""
        for part in parts.dropFirst().dropLast() where !part.isEmpty {
            lines.append(finish(String(part)))
        }
        buffer = String(tail)
        enforceBound()
        return lines
    }

    private mutating func enforceBound() {
        let held = buffer.utf8.count
        guard held > maxBufferBytes else { return }
        droppedBytes += held
        pendingDropNotice += held
        buffer = ""
    }

    private mutating func finish(_ line: String) -> String {
        var out = line
        let n = out.utf8.count
        if n > maxLineBytes {
            out = String(out.prefix(maxLineBytes))
                + " [... \(n - maxLineBytes) more bytes truncated]"
        }
        if pendingDropNotice > 0 {
            out += " [... \(pendingDropNotice) bytes of unterminated output dropped before this line]"
            pendingDropNotice = 0
        }
        return out
    }
}

// ── the cases ────────────────────────────────────────────────────────

/// The exact string v1042-D002 lost. Kept as one literal so the driver and the
/// shell test cannot drift apart on it.
let errorText = "ERROR: no space left on device"

let argv = CommandLine.arguments
guard argv.count >= 3 else {
    FileHandle.standardError.write(Data(
        "usage: driver <fixed|headonly> <longline_err|bound_then_err|wide>\n".utf8))
    exit(2)
}
let which = argv[1]
let shape = argv[2]

/// 1.3 MB with no terminator, then the failure text, then a newline. The whole
/// thing is ONE line, so the bound never fires and truncation decides whether
/// the diagnostic survives. This is the measured v1042-D002 residual.
let longlineErr = String(repeating: "x", count: 1_300_000) + errorText + "\n"

/// 2 MB with no terminator at all -- which DOES trip the bound -- then the
/// failure text on its own terminated line. Exercises the other half.
let boundPrefix = String(repeating: "y", count: 2_000_000)

/// 2,000 emoji then a newline. Every scalar is 4 UTF-8 bytes, so a truncation
/// that counts CHARACTERS returns roughly 4x the byte bound it claims.
let wide = String(repeating: "\u{1F600}", count: 2000) + "\n"

/// The HANG. 2 MB with no terminator ending in the failure text, and the
/// terminator NEVER arrives -- the subprocess stalls or is killed. Nothing is
/// emitted by ingest at all; whatever the accumulator still holds at teardown
/// is the only record. `fixed` flushes it; the pre-fix path called reset() and
/// deleted it unread, which the headonly arm models by emitting nothing.
let hang = String(repeating: "y", count: 2_000_000) + errorText

var lines: [String] = []
var retained = 0
var dropped = 0

switch (which, shape) {
case ("fixed", "longline_err"):
    var b = OutputLineBuffer()
    lines = b.ingest(longlineErr); retained = b.buffer.utf8.count; dropped = b.droppedBytes
case ("headonly", "longline_err"):
    var b = HeadOnlyLineBuffer()
    lines = b.ingest(longlineErr); retained = b.buffer.utf8.count; dropped = b.droppedBytes
case ("fixed", "bound_then_err"):
    var b = OutputLineBuffer()
    _ = b.ingest(boundPrefix)
    lines = b.ingest(errorText + "\n"); retained = b.buffer.utf8.count; dropped = b.droppedBytes
case ("headonly", "bound_then_err"):
    var b = HeadOnlyLineBuffer()
    _ = b.ingest(boundPrefix)
    lines = b.ingest(errorText + "\n"); retained = b.buffer.utf8.count; dropped = b.droppedBytes
case ("fixed", "wide"):
    var b = OutputLineBuffer(maxBufferBytes: 4096, maxLineBytes: 1024)
    lines = b.ingest(wide); retained = b.buffer.utf8.count; dropped = b.droppedBytes
case ("headonly", "wide"):
    var b = HeadOnlyLineBuffer(maxBufferBytes: 4096, maxLineBytes: 1024)
    lines = b.ingest(wide); retained = b.buffer.utf8.count; dropped = b.droppedBytes
case ("fixed", "hang"):
    var b = OutputLineBuffer()
    _ = b.ingest(hang)
    if let t = b.flush() { lines = [t] }
    retained = b.buffer.utf8.count; dropped = b.droppedBytes
case ("headonly", "hang"):
    var b = HeadOnlyLineBuffer()
    _ = b.ingest(hang)
    // No flush. InstallerCoordinator.handleTermination called reset() and
    // nothing else, so the retained partial reached no log. Emitting nothing
    // is not a simplification, it is what the shipped path did.
    retained = b.buffer.utf8.count; dropped = b.droppedBytes
default:
    FileHandle.standardError.write(Data("unknown pair \(which)/\(shape)\n".utf8))
    exit(2)
}

let first = lines.first ?? ""
print("lines=\(lines.count)")
print("line_bytes=\(first.utf8.count)")
print("contains_error=\(first.contains(errorText))")
print("notice=\(first.contains("truncated") || first.contains("dropped"))")
print("retained=\(retained)")
print("dropped=\(dropped)")
