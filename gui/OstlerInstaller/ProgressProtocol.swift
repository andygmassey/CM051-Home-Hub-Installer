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
    /// CX-97 (DMG #48g+1, 2026-05-29): `error` field surfaces a
    /// validation-retry banner above the prompt input on the GUI
    /// side. Populated by install.sh's mismatch loops
    /// (recovery_passphrase + email_password) so the customer sees a
    /// clear "didn't match" cue on the re-emitted prompt rather than
    /// the prompt apparently appearing again from nowhere. Nil on
    /// the happy path; tab/CR/LF stripped at emit time by gui_emit.
    case prompt(id: String, kind: PromptKind, title: String, defaultValue: String?, help: String?, choices: [String], error: String?)
    case stepEnd(id: String, status: StepStatus, elapsedSeconds: Int)
    case phase(id: String, title: String)
    case needsFDA(probe: String, reason: String)
    case needsSudo(reason: String)
    /// CX-53 (DMG ship, 2026-05-24): install.sh emits a structured
    /// RECOVERY_KEY marker carrying the value the customer must save
    /// to get back in if they lose both their passphrase AND their
    /// Keychain entry. The coordinator routes the value to a
    /// dedicated @Published property (NOT into logLines, which is
    /// rendered in the Log drawer visible to anyone the customer
    /// hands the Mac to). The RecoveryKeyView sheet renders the
    /// value with Copy / Save PDF / Print buttons + a confirm
    /// checkbox.
    case recoveryKey(value: String)
    /// CX-17 (2026-05-23): when install.sh's `fail_with_code` fires,
    /// the DONE marker carries a `code=ERR-NN-COMPONENT-SHORTREASON`
    /// keyword so the GUI can surface the code on the failure banner
    /// header AND on the auto-copied log header sent to support.
    /// `errorCode` is `nil` for the success path and for any legacy
    /// `fail "..."` callsite that did not pass through fail_with_code.
    case done(status: StepStatus, errorCode: String?)
    /// Non-marker stdout/stderr line from the subprocess. Surfaced in
    /// the Log drawer only when `devModeRawLog` is on; otherwise these
    /// are filtered out so the customer-facing drawer stays curated.
    /// Pre-#348 these came back as `.log(.info, raw)` and were always
    /// shown, which drowned the LOG markers in tool chatter.
    case rawLine(msg: String)
    case unknown(raw: String)
}

enum PromptKind: String, Equatable {
    case text, secret, yesno, choice
    /// Button-only confirmation -- the customer presses Continue to
    /// acknowledge a screen, no typed input. install.sh used to use
    /// `gui_read text` with an empty default for these (e.g.
    /// exports_ack); Studio retest #2 (2026-05-20) flagged that the
    /// resulting "type Continue then press Continue" UX is
    /// confusing, so the v1.0 fix adds this kind and the
    /// OnboardingQuestionView renders it as a single primary button.
    /// install.sh helpers: `gui_acknowledge` in lib/progress_emitter.sh.
    case acknowledge
    /// Folder-picker control -- defaults to a path supplied via the
    /// `default` field, with a "Choose Folder..." button surfacing
    /// NSOpenPanel + a "Skip this step" button for opt-out flows
    /// (manual_exports_path). Replaces the textfield-or-blank UX
    /// that produced the "Please enter a value to continue" error
    /// when the customer pressed Continue with an empty field.
    case folder
    /// Typed-input legal gate -- a text field paired with a Cancel
    /// button. The customer must type a specific sentinel string
    /// (e.g. "INSTALL") to proceed; anything else keeps the Continue
    /// button disabled. Cancel posts the second value in `choices`
    /// back to install.sh (e.g. "CANCEL") for graceful exit.
    ///
    /// The contract is encoded via `choices`:
    ///   - choices[0] = accept sentinel (case-insensitive, trimmed)
    ///   - choices[1] = cancel sentinel (posted on Cancel-button press)
    ///
    /// Studio retest #7 walkthrough (2026-05-22): Q15 install consent
    /// previously rendered as a button pair (Install Ostler / Cancel).
    /// Restored as a typed-input gate per Andy's legal-sign-off
    /// requirement ("user needs to proactively write INSTALL for
    /// Legal reasons"). The typed-INSTALL ceremony reinforces that
    /// the customer is making a deliberate consent decision.
    /// Snake-case raw value so install.sh's `gui_read` call
    /// (`gui_read … text_with_cancel …`) deserialises correctly.
    case textWithCancel = "text_with_cancel"
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
            // Not a marker -- raw subprocess stdout/stderr. The
            // coordinator decides whether to surface this based on
            // the Verbose toggle (`devModeRawLog`).
            return .rawLine(msg: raw)
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
            // CX-97 (DMG #48g+1, 2026-05-29): treat empty error= the
            // same as missing -- install.sh's secret-mismatch loops
            // pass an empty string on the first attempt and a
            // populated string on the retry, so the GUI's banner
            // condition is simply "is the error non-nil and non-empty".
            let rawError = kv["error"]
            let normalisedError: String? = (rawError?.isEmpty ?? true) ? nil : rawError
            return .prompt(
                id: kv["id"] ?? "prompt",
                kind: kind,
                title: kv["title"] ?? "?",
                defaultValue: kv["default"],
                help: kv["help"],
                choices: choices,
                error: normalisedError
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
            let code = kv["code"].flatMap { $0.isEmpty ? nil : $0 }
            return .done(
                status: StepStatus(rawValue: kv["status"] ?? "ok") ?? .ok,
                errorCode: code
            )
        case "RECOVERY_KEY":
            // CX-53: parse the structured recovery-key marker
            // emitted by install.sh after setup_passphrase. The value
            // is single-shot (one fire per install) and surfaces in
            // the GUI as a sheet with Copy / Save PDF / Print
            // controls.
            return .recoveryKey(value: kv["value"] ?? "")
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
            ("plain log line",                             "rawLine"),
            ("#OSTLER\tBOGUS\tx=y",                       "unknown"),
        ]
        for (raw, want) in cases {
            let got = ProgressDecoder.decode(line: raw)
            switch (got, want) {
            case (.stepBegin, "stepBegin"), (.pct, "pct"),
                 (.log, "log"), (.done, "done"),
                 (.rawLine, "rawLine"), (.unknown, "unknown"):
                continue
            default:
                assertionFailure("decode mismatch: \(raw) -> \(got), wanted \(want)")
            }
        }
    }
}
#endif
