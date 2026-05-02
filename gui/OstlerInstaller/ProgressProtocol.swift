// ProgressProtocol.swift
//
// Decoder for the tab-separated #OSTLER marker lines emitted by
// install.sh when OSTLER_GUI=1. Mirrored against
// lib/progress_emitter.sh – keep changes in lockstep.
//
// Wire format (one marker per line):
//   #OSTLER<TAB>EVENT<TAB>k=v<TAB>k=v...
//
// Events:
//   STEP_BEGIN  id title phase idx total
//   PCT         step pct
//   LOG         level msg
//   WARN        step msg
//   PROMPT      id kind title default help choices
//   STEP_END    id status elapsed_s
//   PHASE       id title
//   NEEDS_FDA   probe reason
//   NEEDS_SUDO  reason
//   DONE        status

import Foundation

/// One decoded marker, plus a fallback `.unknown` case so a typo or
/// schema drift doesn't crash the GUI – we still surface the raw
/// line in the log drawer.
enum InstallerEvent: Equatable {
    case stepBegin(id: String, title: String, phase: Int?, idx: Int?, total: Int?)
    case pct(step: String, pct: Int)
    case log(level: String, msg: String)
    case warn(step: String, msg: String)
    case prompt(id: String, kind: PromptKind, title: String, defaultValue: String?, help: String?, choices: [String])
    case stepEnd(id: String, status: StepStatus, elapsedSeconds: Int)
    case phase(id: String, title: String)
    case needsFDA(probe: String, reason: String)
    case needsSudo(reason: String)
    case done(status: StepStatus)
    case unknown(raw: String)
}

enum PromptKind: String, Equatable {
    case text, secret, yesno, choice
}

enum StepStatus: String, Equatable {
    case ok, warn, fail
}

/// Stateful line buffer that pulls #OSTLER markers out of a stream
/// and yields one `InstallerEvent` per complete line. Anything that
/// isn't a marker gets re-emitted verbatim as a `.log(.info, raw)`
/// so the log drawer never silently drops install.sh's TTY chatter.
struct ProgressDecoder {
    private static let marker = "#OSTLER"

    static func decode(line raw: String) -> InstallerEvent {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.hasPrefix(marker) else {
            // Not a marker – return as plain log so the drawer can show it.
            return .log(level: "info", msg: raw)
        }

        // Tab-split. First field is `#OSTLER`, second is event, rest
        // are k=v pairs.
        let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2 else {
            return .unknown(raw: raw)
        }
        let event = parts[1]
        var kv: [String: String] = [:]
        for pair in parts.dropFirst(2) {
            if let eq = pair.firstIndex(of: "=") {
                let k = String(pair[..<eq])
                let v = String(pair[pair.index(after: eq)...])
                kv[k] = v
            }
        }

        switch event {
        case "STEP_BEGIN":
            return .stepBegin(
                id: kv["id"] ?? "?",
                title: kv["title"] ?? "?",
                phase: kv["phase"].flatMap(Int.init),
                idx: kv["idx"].flatMap(Int.init),
                total: kv["total"].flatMap(Int.init)
            )
        case "PCT":
            return .pct(
                step: kv["step"] ?? "?",
                pct: max(0, min(100, Int(kv["pct"] ?? "0") ?? 0))
            )
        case "LOG":
            return .log(level: kv["level"] ?? "info", msg: kv["msg"] ?? "")
        case "WARN":
            return .warn(step: kv["step"] ?? "?", msg: kv["msg"] ?? "")
        case "PROMPT":
            let kind = PromptKind(rawValue: kv["kind"] ?? "text") ?? .text
            let choices = (kv["choices"] ?? "")
                .split(separator: ",")
                .map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            return .prompt(
                id: kv["id"] ?? "prompt",
                kind: kind,
                title: kv["title"] ?? "?",
                defaultValue: kv["default"],
                help: kv["help"],
                choices: choices
            )
        case "STEP_END":
            return .stepEnd(
                id: kv["id"] ?? "?",
                status: StepStatus(rawValue: kv["status"] ?? "ok") ?? .ok,
                elapsedSeconds: Int(kv["elapsed_s"] ?? "0") ?? 0
            )
        case "PHASE":
            return .phase(id: kv["id"] ?? "?", title: kv["title"] ?? "?")
        case "NEEDS_FDA":
            return .needsFDA(probe: kv["probe"] ?? "", reason: kv["reason"] ?? "")
        case "NEEDS_SUDO":
            return .needsSudo(reason: kv["reason"] ?? "")
        case "DONE":
            return .done(status: StepStatus(rawValue: kv["status"] ?? "ok") ?? .ok)
        default:
            return .unknown(raw: raw)
        }
    }
}

// MARK: - Tests
#if DEBUG
enum ProgressDecoderSelfTest {
    static func runOnce() {
        let cases: [(String, String)] = [
            ("#OSTLER\tSTEP_BEGIN\tid=foo\ttitle=Hello", "stepBegin"),
            ("#OSTLER\tPCT\tstep=foo\tpct=50",           "pct"),
            ("#OSTLER\tLOG\tlevel=info\tmsg=hi",          "log"),
            ("#OSTLER\tDONE\tstatus=ok",                  "done"),
            ("plain log line",                             "log"),
            ("#OSTLER\tBOGUS\tx=y",                       "unknown"),
        ]
        for (raw, want) in cases {
            let got = ProgressDecoder.decode(line: raw)
            switch (got, want) {
            case (.stepBegin, "stepBegin"), (.pct, "pct"),
                 (.log, "log"), (.done, "done"), (.unknown, "unknown"):
                continue
            default:
                assertionFailure("decode mismatch: \(raw) -> \(got), wanted \(want)")
            }
        }
    }
}
#endif
