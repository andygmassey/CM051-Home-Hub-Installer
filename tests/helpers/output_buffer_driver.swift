// output_buffer_driver.swift
//
// Driver for tests/test_installer_output_buffer_is_bounded.sh. Compiled by
// plain `swiftc` alongside gui/OstlerInstaller/OutputLineBuffer.swift -- no
// Xcode project, no signing, no downloads, so the gate runs on any macOS
// runner in seconds.
//
// Two parsers, ONE driver:
//
//   fixed   the shipping OutputLineBuffer
//   legacy  the PRE-FIX loop, transcribed verbatim from
//           InstallerCoordinator.swift as it stood at c9d2f5b
//
// `legacy` is the positive control. If it does not retain the bytes, this
// harness cannot detect the defect it was written for, and a green `fixed`
// result would mean nothing.
//
// Usage: driver <fixed|legacy> <lf|cr|crlf|longline> <megabytes>
// Prints: retained_bytes=<n> lines=<n> dropped=<n> longest_line=<n>

import Foundation

// ── The PRE-FIX parser, verbatim. DO NOT "improve" it. ───────────────
// InstallerCoordinator.swift @ c9d2f5b, lines 1483-1496:
//
//     stdoutBuffer.append(chunk)
//     while let nlIdx = stdoutBuffer.firstIndex(of: "\n") {
//         var line = String(stdoutBuffer[..<nlIdx])
//         stdoutBuffer.removeSubrange(...nlIdx)
//         if line.hasSuffix("\r") { line.removeLast() }
//         if line.isEmpty { continue }
//         ...
//     }
struct LegacyLineBuffer {
    private(set) var buffer = ""
    let droppedBytes = 0

    mutating func ingest(_ chunk: String) -> [String] {
        var out: [String] = []
        buffer.append(chunk)
        while let nlIdx = buffer.firstIndex(of: "\n") {
            var line = String(buffer[..<nlIdx])
            buffer.removeSubrange(...nlIdx)
            if line.hasSuffix("\r") { line.removeLast() }
            if line.isEmpty { continue }
            out.append(line)
        }
        return out
    }
}

let argv = CommandLine.arguments
guard argv.count >= 4,
      let mib = Int(argv[3]) else {
    FileHandle.standardError.write(Data("usage: driver <fixed|legacy> <lf|cr|crlf|longline> <megabytes>\n".utf8))
    exit(2)
}
let parser = argv[1]
let shape = argv[2]

// 60-byte payload shaped like a docker/ollama progress redraw.
let payload = "a1b2c3d4e5f6: Downloading [====>            ]  123.4MB/456.7MB"
let body = String(payload.prefix(60))

/// Build one 64 KiB chunk of the requested shape. 64 KiB is the macOS pipe
/// buffer size, i.e. the size the real readabilityHandler delivers.
func makeChunk() -> String {
    switch shape {
    case "lf":       return String(repeating: body + "\n", count: 1024)
    case "cr":       return String(repeating: body + "\r", count: 1024)
    case "crlf":     return String(repeating: body + "\r\n", count: 1024)
    case "longline": return String(repeating: "x", count: 65536)   // never terminated
    default:
        FileHandle.standardError.write(Data("unknown shape \(shape)\n".utf8))
        exit(2)
    }
}

let chunk = makeChunk()
let chunkBytes = chunk.utf8.count
let totalBytes = mib * 1024 * 1024
let iterations = max(1, totalBytes / chunkBytes)

var lines = 0
var longest = 0
var retained = 0
var dropped = 0

if parser == "fixed" {
    var buf = OutputLineBuffer()
    for _ in 0..<iterations {
        for l in buf.ingest(chunk) {
            lines += 1
            longest = max(longest, l.utf8.count)
        }
    }
    retained = buf.buffer.utf8.count
    dropped = buf.droppedBytes
} else if parser == "legacy" {
    var buf = LegacyLineBuffer()
    for _ in 0..<iterations {
        for l in buf.ingest(chunk) {
            lines += 1
            longest = max(longest, l.utf8.count)
        }
    }
    retained = buf.buffer.utf8.count
    dropped = buf.droppedBytes
} else {
    FileHandle.standardError.write(Data("unknown parser \(parser)\n".utf8))
    exit(2)
}

print("fed_bytes=\(iterations * chunkBytes)")
print("retained_bytes=\(retained)")
print("lines=\(lines)")
print("dropped=\(dropped)")
print("longest_line=\(longest)")
