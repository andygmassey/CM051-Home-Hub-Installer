// WhatsAppLink.swift
//
// v1.0.103: link WhatsApp from the installer, not from Terminal.
//
// BEFORE THIS FILE the installer's last word on WhatsApp was a Terminal
// command (`ostler-assistant setup channels --interactive whatsapp`) printed
// into the log. The pair code the daemon had ALREADY requested at first boot
// lived for 180 s and was gone long before a customer read that far, so the
// first real attempt was always a dead code.
//
// WHAT THE DAEMON ACTUALLY OFFERS, measured on the daemon source (oa 887796b6)
// and on macstudio, 2026-09-26:
//
//   * A pair code is requested ONCE per start of the WhatsApp Web channel,
//     when `pair_phone` is configured and the session DB holds no linked
//     device (wa-rs Bot::run -> pair_with_code). There is no "new code" API.
//     So a new code means restarting the channel, and the channel lives in
//     the assistant daemon: `launchctl kickstart -k` of its LaunchAgent.
//     Measured: code file written 3 s after the kickstart.
//   * The code is published to `${OSTLER_HOME}/state/whatsapp_pair.json`
//     (0600, temp-then-rename) with a MEASURED `expires_at`. This is the
//     same file Doctor's /whatsapp-pair panel reads (whatsapp_pair.py); the
//     taxonomy and the 5 s "about to die" floor are mirrored from there so
//     the two surfaces cannot disagree about whether a code is usable.
//   * "Linked" is NOT the gateway health component. `channel:WhatsApp` is
//     absent from /health while unpaired, and when present its health_check
//     is `client.is_some()`, which is set BEFORE pairing. The durable fact is
//     the session DB: wa-rs writes the phone JID into `device.pn` only when
//     the phone confirms the link. So linked == a device row with a pn.
//
// Nothing here logs or returns the customer's phone number, and the pair
// code is only ever handed to the view that shows it.

import Foundation
import SQLite3

// MARK: - Config

/// What install.sh wrote into the assistant config for WhatsApp.
enum WhatsAppConfig: Equatable {
    /// No `[channels.whatsapp]` block, or `enabled` is not true. The customer
    /// did not choose WhatsApp; the section is not shown at all.
    case notEnabled
    /// Enabled in Web mode but with no `pair_phone`: wa-rs falls back to QR
    /// linking and never publishes a code. We cannot show a code.
    case enabledWithoutPhone(sessionPath: String)
    /// Enabled with a pair phone: the in-app code flow works.
    case pairCode(sessionPath: String)

    var sessionPath: String? {
        switch self {
        case .notEnabled: return nil
        case .enabledWithoutPhone(let p), .pairCode(let p): return p
        }
    }

    /// Read the `[channels.whatsapp]` table out of config.toml.
    ///
    /// A deliberately narrow line reader, not a TOML parser: install.sh emits
    /// this block itself (install.sh, "[channels.whatsapp]" writer) as flat
    /// `key = value` lines. A table header ends the block. Values are never
    /// returned for `pair_phone`; only its presence matters here.
    static func parse(configTOML: String) -> WhatsAppConfig {
        var inBlock = false
        var enabled = false
        var sessionPath: String? = nil
        var hasPhone = false
        for rawLine in configTOML.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inBlock = (line == "[channels.whatsapp]")
                continue
            }
            guard inBlock, !line.hasPrefix("#"),
                  let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if let hash = value.range(of: " #") { value = String(value[..<hash.lowerBound]) }
            value = value.trimmingCharacters(in: .whitespaces)
            let unquoted = value.count >= 2 && value.hasPrefix("\"") && value.hasSuffix("\"")
                ? String(value.dropFirst().dropLast()) : value
            switch key {
            case "enabled":      enabled = (value == "true")
            case "session_path": sessionPath = unquoted.isEmpty ? nil : unquoted
            case "pair_phone":   hasPhone = unquoted.contains { $0.isNumber }
            default: break
            }
        }
        guard enabled, let path = sessionPath else { return .notEnabled }
        return hasPhone ? .pairCode(sessionPath: path) : .enabledWithoutPhone(sessionPath: path)
    }
}

// MARK: - Pair code file

/// The daemon's pair-code file, read with the same taxonomy as Doctor's
/// `whatsapp_pair.fetch_pair_status`.
enum WhatsAppPairCode: Equatable {
    case notRequested
    case unreadable
    case expired(requestedAt: Int)
    case live(code: String, requestedAt: Int, expiresAt: Int)

    /// Below this many seconds a code is reported expired rather than shown.
    /// Same floor as Doctor (`_MIN_USEFUL_SECONDS`).
    static let minUsefulSeconds = 5

    var requestedAt: Int? {
        switch self {
        case .expired(let r): return r
        case .live(_, let r, _): return r
        default: return nil
        }
    }

    static func parse(data: Data?, now: Int) -> WhatsAppPairCode {
        guard let data = data else { return .notRequested }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawCode = obj["code"] as? String,
              !rawCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let expiresNum = obj["expires_at"] as? NSNumber,
              CFGetTypeID(expiresNum) != CFBooleanGetTypeID()
        else { return .unreadable }
        let expiresAt = expiresNum.intValue
        let requestedAt = (obj["requested_at"] as? NSNumber)?.intValue ?? 0
        if expiresAt - now < minUsefulSeconds {
            return .expired(requestedAt: requestedAt)
        }
        return .live(code: rawCode.trimmingCharacters(in: .whitespacesAndNewlines),
                     requestedAt: requestedAt, expiresAt: expiresAt)
    }

    /// WhatsApp shows the 8 characters as two groups of four. Showing them the
    /// same way means the customer types what they see.
    static func display(_ code: String) -> String {
        guard code.count == 8 else { return code }
        return String(code.prefix(4)) + "-" + String(code.suffix(4))
    }
}

// MARK: - Linked

enum WhatsAppLinkedState: Equatable {
    case linked
    case notLinked
    /// The session DB exists and could not be read. NOT "not linked":
    /// we could not look.
    case cannotTell
}

enum WhatsAppSession {
    /// Is a phone linked to this session DB?
    ///
    /// Opened READ-ONLY through SQLite (the daemon holds it open in WAL
    /// mode; a read-only connection is the supported way to look). Only a
    /// COUNT leaves this function, never the JID itself.
    static func linkedState(sessionPath: String) -> WhatsAppLinkedState {
        guard FileManager.default.fileExists(atPath: sessionPath) else {
            // No session file at all: the channel has not started, so
            // nothing is linked. This is a real absence, not a failed read.
            return .notLinked
        }
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(sessionPath, &db, flags, nil) == SQLITE_OK, let handle = db else {
            sqlite3_close(db)
            return .cannotTell
        }
        defer { sqlite3_close(handle) }
        sqlite3_busy_timeout(handle, 2000)
        var stmt: OpaquePointer?
        let sql = "SELECT COUNT(*) FROM device WHERE pn IS NOT NULL AND pn <> ''"
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else {
            // No `device` table yet is the channel mid-first-boot. Anything
            // else is a read we could not make; both are "cannot tell".
            sqlite3_finalize(stmt)
            return .cannotTell
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return .cannotTell }
        return sqlite3_column_int64(stmt, 0) > 0 ? .linked : .notLinked
    }
}

// MARK: - The whole screen state, as a pure function

/// Everything the Connect WhatsApp section can show. A pure function of what
/// was read off disk plus two bits of view state, so every branch is testable
/// without a daemon.
enum WhatsAppLinkPhase: Equatable {
    case hidden                  // WhatsApp not chosen
    case noPhoneNumber           // enabled without pair_phone
    case linked
    case skipped
    case ready                   // nothing live on screen; offer "Get a code"
    case requesting              // kickstarted, waiting for the new code
    case showing(code: String, secondsLeft: Int)
    case expired                 // a code we showed has aged out
    case failed                  // asked for a code and none came

    static func derive(
        config: WhatsAppConfig,
        linked: WhatsAppLinkedState,
        pair: WhatsAppPairCode,
        now: Int,
        skipped: Bool,
        requestStartedAt: Int?,
        requestTimedOut: Bool
    ) -> WhatsAppLinkPhase {
        switch config {
        case .notEnabled: return .hidden
        case .enabledWithoutPhone: return linked == .linked ? .linked : .noPhoneNumber
        case .pairCode: break
        }
        if linked == .linked { return .linked }
        if skipped { return .skipped }

        if let started = requestStartedAt {
            // Only a code minted AFTER we asked counts. The file on disk may
            // hold the first-boot code from install time, which can still
            // look live for a moment and would be superseded by the restart.
            if case .live(let code, let requestedAt, let expiresAt) = pair, requestedAt >= started {
                return .showing(code: code, secondsLeft: max(0, expiresAt - now))
            }
            if let r = pair.requestedAt, r >= started, case .expired = pair {
                return .expired
            }
            return requestTimedOut ? .failed : .requesting
        }

        // Not asked yet in this session. A code the daemon minted by itself
        // (first boot) is shown if it still has a useful life left.
        if case .live(let code, _, let expiresAt) = pair {
            return .showing(code: code, secondsLeft: max(0, expiresAt - now))
        }
        if case .expired = pair { return .expired }
        return .ready
    }
}

// MARK: - IO

/// The on-disk and launchd surfaces, resolved once. Paths are injectable so
/// the harness can point at a scratch tree.
struct WhatsAppLinkIO {
    var ostlerHome: URL
    var assistantLabel: String = "com.creativemachines.ostler.assistant"

    static func live() -> WhatsAppLinkIO {
        let env = ProcessInfo.processInfo.environment
        let base = env["OSTLER_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ostler")
        return WhatsAppLinkIO(ostlerHome: base)
    }

    var configURL: URL { ostlerHome.appendingPathComponent("assistant-config/config.toml") }
    var pairFileURL: URL { ostlerHome.appendingPathComponent("state/whatsapp_pair.json") }

    func readConfig() -> WhatsAppConfig {
        guard let text = try? String(contentsOf: configURL, encoding: .utf8) else { return .notEnabled }
        return WhatsAppConfig.parse(configTOML: text)
    }

    func readPair(now: Int) -> WhatsAppPairCode {
        WhatsAppPairCode.parse(data: try? Data(contentsOf: pairFileURL), now: now)
    }

    /// Ask for a fresh code by restarting the assistant, which restarts the
    /// WhatsApp channel, which requests a new code. Returns launchctl's exit
    /// status; stderr is logged, never swallowed.
    @discardableResult
    func requestNewCode() -> Int32 {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        proc.arguments = ["kickstart", "-k", "gui/\(getuid())/\(assistantLabel)"]
        let err = Pipe()
        proc.standardError = err
        proc.standardOutput = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            NSLog("whatsapp_link: launchctl could not start: %@", error.localizedDescription)
            return -1
        }
        if proc.terminationStatus != 0 {
            let text = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            NSLog("whatsapp_link: kickstart exited %d: %@", proc.terminationStatus, text)
        }
        return proc.terminationStatus
    }
}
