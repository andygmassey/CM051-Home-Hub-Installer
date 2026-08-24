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
//    cannot put a gigabyte-long String into the log array either. The
//    truncation keeps BOTH ENDS -- three quarters head, one quarter tail --
//    because a failing producer names its failure LAST. See `finish`.
// 4. Dropping is NEVER silent: `droppedBytes` accumulates and the next
//    emitted line carries a marker saying how much went. A bound that hides
//    what it discarded is a second silent failure, not a fix.
// 5. `reset()` releases the storage; the coordinator calls it on subprocess
//    termination so the bytes do not outlive the install that made them.
// 6. `flush()` surfaces the retained partial line first. A subprocess that
//    hangs or is killed has, by definition, not written its terminator, so
//    the bytes most likely to name the failure are the bytes `reset()` alone
//    deleted unread. The coordinator flushes BEFORE it resets.
//
// The three bounds above are stated in BYTES and enforced in bytes.
// `String.prefix(_:)` counts CHARACTERS, and the version of `finish` that
// used it returned 4,128 bytes against a claimed 1,024 on emoji input. Use
// `clampedPrefix` / `clampedSuffix`, not `prefix` / `suffix`, anywhere a
// limit here is spelled "bytes".
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

    /// Emit whatever partial line is still retained, annotated, and clear it.
    ///
    /// WHY THIS EXISTS. The retained partial used to be thrown away by
    /// `reset()` at teardown without ever reaching the log, and that is exactly
    /// the hang case: a producer that stalls has BY DEFINITION not written its
    /// terminator, so the last thing it said lives here and nowhere else.
    /// Measured on 19bd9a09: `InstallerCoordinator.handleTermination` called
    /// `stdoutBuffer.reset()` and nothing called anything else, so the bytes
    /// most likely to name the failure were the bytes guaranteed to be deleted
    /// unread.
    ///
    /// Returns nil when there is nothing retained and no outstanding drop
    /// notice, so a normal install that ended on a terminator logs nothing.
    mutating func flush() -> String? {
        if buffer.isEmpty && pendingDropNotice == 0 { return nil }
        let out = finish(buffer)
        buffer = ""
        return out
    }

    /// Release the retained storage. Called on subprocess termination.
    mutating func reset() {
        buffer = ""
        droppedBytes = 0
        pendingDropNotice = 0
    }

    // ── internals ────────────────────────────────────────────────────

    /// THE BOUND. Reached only when a producer emitted no terminator at all
    /// for `maxBufferBytes`.
    ///
    /// KEEPS THE TAIL. This used to discard the whole buffer, reasoning that a
    /// fragment of a line reading like a whole one is worse than an explicit
    /// gap. The gap is explicit either way -- `pendingDropNotice` is attached
    /// to the next emitted line and says exactly how many bytes went -- so the
    /// only thing discarding bought was the loss of the bytes a stalled
    /// producer wrote LAST, which are the ones that name the failure. Bounded
    /// at a quarter of the ceiling so the retained tail cannot itself become
    /// the leak, and the post-condition is TIGHTER than before, not looser:
    /// after this returns the buffer holds at most `maxBufferBytes / 4`.
    private mutating func enforceBound() {
        let held = buffer.utf8.count
        guard held > maxBufferBytes else { return }
        let tail = OutputLineBuffer.clampedSuffix(buffer, bytes: maxBufferBytes / 4)
        let lost = held - tail.utf8.count
        droppedBytes += lost
        pendingDropNotice += lost
        buffer = tail
    }

    /// Truncate an over-long line KEEPING BOTH ENDS, and attach any outstanding
    /// drop notice, so no byte disappears without the log saying so.
    ///
    /// v1042-D002 RESIDUAL, measured on the shipped file 2026-08-24. 1.3 MB of
    /// unterminated output ending in "ERROR: no space left on device" emitted
    /// ONE line of 65,571 bytes, correctly annotated with the byte count it had
    /// dropped, that did not contain the error:
    ///
    ///     lines=1  line_bytes=65571  contains_error=false
    ///     head=xxxxxxxxxxxxxxxxxxxxxxxx
    ///     tail=xxxxxxxx [... 1234494 more bytes truncated]
    ///
    /// `prefix(maxLineBytes)` keeps the HEAD, and a failing producer names its
    /// failure LAST. That is `v1018-D032` in a new file: captured output keeps
    /// the head when a hang needs the tail. The notice was honest and the
    /// diagnostic was gone anyway, which is the whole shape of the defect --
    /// an accurate report of a loss is not a substitute for not losing it.
    ///
    /// Three quarters head, one quarter tail. The head carries the context that
    /// says which producer is talking; the tail carries the failure.
    private mutating func finish(_ line: String) -> String {
        var out = line
        let n = out.utf8.count
        if n > maxLineBytes {
            let head = OutputLineBuffer.clampedPrefix(out, bytes: (maxLineBytes / 4) * 3)
            let tail = OutputLineBuffer.clampedSuffix(out, bytes: maxLineBytes / 4)
            let lost = n - head.utf8.count - tail.utf8.count
            out = head
                + " [... \(lost) more bytes truncated, tail follows ...] "
                + tail
        }
        if pendingDropNotice > 0 {
            out += " [... \(pendingDropNotice) bytes of unterminated output dropped before this line]"
            pendingDropNotice = 0
        }
        return out
    }
    /// Longest prefix of `s` that is at most `bytes` UTF-8 bytes and does not
    /// split a scalar.
    ///
    /// `String.prefix(_:)` counts CHARACTERS, not bytes. The line it replaced
    /// therefore did not bound what it claimed to bound: on output carrying
    /// any multi-byte scalar, `String(out.prefix(maxLineBytes))` can be several
    /// times `maxLineBytes` bytes long. ASCII progress output hid it.
    private static func clampedPrefix(_ s: String, bytes: Int) -> String {
        if s.utf8.count <= bytes { return s }
        let u = Array(s.utf8)
        var end = min(bytes, u.count)
        while end > 0 && (u[end] & 0xC0) == 0x80 { end -= 1 }
        return String(decoding: u[0..<end], as: UTF8.self)
    }

    /// Longest suffix of `s` that is at most `bytes` UTF-8 bytes and does not
    /// split a scalar. Slicing forward off a continuation byte rather than
    /// backward keeps the result inside the bound.
    private static func clampedSuffix(_ s: String, bytes: Int) -> String {
        if s.utf8.count <= bytes { return s }
        let u = Array(s.utf8)
        var start = u.count - bytes
        while start < u.count && (u[start] & 0xC0) == 0x80 { start += 1 }
        return String(decoding: u[start...], as: UTF8.self)
    }
}
