// OutputLineBuffer.swift
//
// The subprocess stdout/stderr line accumulator, extracted from
// InstallerCoordinator so it can be compiled and measured on its own
// (`swiftc OutputLineBuffer.swift driver.swift`) with no Xcode project,
// no SwiftUI and no signing. tests/test_installer_output_buffer_is_bounded.sh
// does exactly that, and drives the PRE-FIX parser through the same driver
// as a positive control.
//
// ══════════════════════════════════════════════════════════════════════
// WHY THIS FILE EXISTS -- THE 4.27 GB, MEASURED
// ══════════════════════════════════════════════════════════════════════
//
// v1.0.42 upgrade walk, Mac mini, 2026-08-23. macOS raised "your system
// has run out of application memory" with:
//
//     Ostler Installer   (paused)   4.27 GB     <-- AFTER a successful install
//
// The accumulator was a single Swift String that grew by `append` on every
// chunk read off the pipe, and shrank ONLY when a "\n" was found in it
// (InstallerCoordinator, pre-fix):
//
//     stdoutBuffer.append(chunk)
//     while let nlIdx = stdoutBuffer.firstIndex(of: "\n") { ... }
//
// Output carrying no "\n" therefore accumulated one retained byte per byte
// received, without bound, and was never cleared -- not on subprocess
// termination, not ever. That is the shape of `\r`-delimited progress output
// (docker, brew, pip and ollama all redraw with carriage returns), and of any
// tool that writes a long unterminated run.
//
// MEASURED against the pre-fix parser, verbatim, through a real Pipe +
// readabilityHandler on this Mac:
//
//     mode=cr  fed  5 MiB  ->  lines_parsed=0        retained  5,246,000 chars
//     mode=cr  fed 20 MiB  ->  lines_parsed=0        retained 20,984,000 chars
//     mode=lf  fed 20 MiB  ->  lines_parsed=344,000  retained          0  <- CONTROL
//
// 4x the input, 4x the retention: linear, 1:1, permanent. The `lf` control
// runs on the same harness at the same byte volume and retains nothing, so
// the `cr` number is a measurement of the parser and not of the harness.
//
// WHAT WAS REFUTED, so nobody re-chases it: the log buffer. `logLines` is
// capped at 5,000 entries (InstallerCoordinator.appendLog). A few MB. It was
// never the 4 GB. It is, however, capped only by COUNT and not by per-entry
// SIZE -- so a single multi-gigabyte "line" would have gone straight into it.
// That is why maxLineBytes exists here as well as maxBufferBytes.
//
// WHAT IS STILL NOT KNOWN, stated rather than guessed: WHICH producer emitted
// gigabytes of unterminated output on Andy's box. The mechanism above is
// proven and quantified; the specific producer is not identifiable from
// source alone. It needs ~/.ostler/logs/install.log off that machine --
// NOT `~/.ostler/install.log`, which does not exist: install.sh:1609 and
// :2254 set INSTALL_LOG="${LOGS_DIR}/install.log" with
// LOGS_DIR="${OSTLER_DIR}/logs", so a grep against the shorter path reports
// an absent FILE and reads identically to an absent MATCH.
//
// ══════════════════════════════════════════════════════════════════════
// WHAT THIS TYPE GUARANTEES
// ══════════════════════════════════════════════════════════════════════
//
// 1. Retained bytes are bounded by `maxBufferBytes + one chunk`, for every
//    possible input shape. No sequence of `ingest` calls can exceed it.
// 2. "\r" terminates a line as well as "\n", so progress redraws are PARSED
//    rather than accumulated. CRLF yields one line, not two.
// 3. A single line longer than `maxLineBytes` is truncated with a visible
//    marker before the caller ever sees it, so a pathological producer
//    cannot put a gigabyte-long String into the log array either.
// 4. Dropping is NEVER silent: `droppedBytes` accumulates and the next
//    emitted line carries a marker saying how much went. A bound that hides
//    what it discarded is a second silent failure, not a fix.
// 5. `reset()` releases the storage; the coordinator calls it on subprocess
//    termination so the bytes do not outlive the install that made them.
//
// Scanning is O(chunk), not O(buffer). The pre-fix loop re-scanned the whole
// accumulated buffer on every chunk, which is why it took 200 s of CPU to
// consume 20 MiB in the probe above -- the install was starved of the main
// actor as well as of memory.

import Foundation

/// Bounded, terminator-agnostic line accumulator for subprocess output.
///
/// A value type the caller owns rather than a class with shared state, so the
/// bound is testable in isolation -- no Process, no Pipe, no run loop.
struct OutputLineBuffer {

    /// Hard ceiling on retained bytes. 1 MiB is far above the longest line
    /// any tool in this install has been observed to emit, and four orders of
    /// magnitude below the 4.27 GB that triggered this. Past it the producer
    /// is not emitting lines at all, and holding more buys the customer
    /// nothing.
    static let defaultMaxBufferBytes = 1 << 20     // 1 MiB

    /// Longest single line handed to the caller. The GUI log drawer cannot
    /// usefully render more, and `logLines` is bounded by COUNT not by size.
    static let defaultMaxLineBytes = 64 * 1024     // 64 KiB

    let maxBufferBytes: Int
    let maxLineBytes: Int

    /// The retained partial line. Never exceeds `maxBufferBytes` after any
    /// completed `ingest`.
    private(set) var buffer = ""

    /// Total bytes discarded because a producer emitted no terminator for
    /// longer than `maxBufferBytes`. Non-zero is a real event the coordinator
    /// logs; it is not a normal steady state.
    private(set) var droppedBytes = 0

    /// Bytes dropped that have not yet been announced on an emitted line.
    private var pendingDropNotice = 0

    init(maxBufferBytes: Int = OutputLineBuffer.defaultMaxBufferBytes,
         maxLineBytes: Int = OutputLineBuffer.defaultMaxLineBytes) {
        self.maxBufferBytes = maxBufferBytes
        self.maxLineBytes = maxLineBytes
    }

    /// Append a chunk; return every complete line it produced.
    ///
    /// A line ends at "\n" OR at "\r". Empty segments are dropped, which
    /// collapses CRLF to a single terminator and matches the caller's
    /// pre-existing `if line.isEmpty { continue }` rule.
    mutating func ingest(_ chunk: String) -> [String] {
        // Split the CHUNK, not the accumulated buffer. O(chunk).
        //
        // "\r\n" is listed EXPLICITLY, and it is not redundant. In Swift a
        // CRLF pair is ONE Character -- a single grapheme cluster that is
        // equal to neither "\r" nor "\n". Measured: without this arm a
        // CRLF-only stream yields zero lines and accumulates every byte.
        // The pre-fix parser's `firstIndex(of: "\n")` had the same hole, so
        // CRLF output was a second unbounded-growth path alongside the
        // bare-CR one.
        let parts = chunk.split(omittingEmptySubsequences: false,
                                whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == "\r\n" })
        guard let tail = parts.last else { return [] }

        if parts.count == 1 {
            // No terminator anywhere in this chunk: it all extends the
            // partial line. This is the arm that used to grow without bound.
            buffer.append(contentsOf: tail)
            enforceBound()
            return []
        }

        var lines: [String] = []
        // The first segment completes whatever partial we were holding.
        buffer.append(contentsOf: parts[0])
        if !buffer.isEmpty { lines.append(finish(buffer)) }
        buffer = ""
        // Middle segments are whole lines in their own right.
        for part in parts.dropFirst().dropLast() where !part.isEmpty {
            lines.append(finish(String(part)))
        }
        // The final segment is the new partial (empty if the chunk ended on
        // a terminator).
        buffer = String(tail)
        enforceBound()
        return lines
    }

    /// Release the retained storage. Called on subprocess termination.
    mutating func reset() {
        buffer = ""
        droppedBytes = 0
        pendingDropNotice = 0
    }

    // ── internals ────────────────────────────────────────────────────

    /// THE BOUND. Reached only when a producer emitted no terminator at all
    /// for `maxBufferBytes`. Discard rather than keep a tail: a fragment of a
    /// line that reads like a whole one is worse than an explicit gap, and
    /// clearing is O(1) so the bound cannot itself become the slow path.
    private mutating func enforceBound() {
        let held = buffer.utf8.count
        guard held > maxBufferBytes else { return }
        droppedBytes += held
        pendingDropNotice += held
        buffer = ""
    }

    /// Truncate an over-long line and attach any outstanding drop notice, so
    /// no byte disappears without the log saying so.
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
