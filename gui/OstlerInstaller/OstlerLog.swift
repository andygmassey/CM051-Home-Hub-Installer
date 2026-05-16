// OstlerLog.swift
//
// Centralised os.Logger instance for the installer. Subsystem is
// `ai.ostler.installer` so an operator chasing a hang can run:
//
//   log show --predicate 'subsystem == "ai.ostler.installer"' \
//            --info --debug --last 10m
//
// Categories segment the stream:
//
//   lifecycle  - app boot, licence verify, gate transitions,
//                bootstrap entry/exit, subprocess launch + exit.
//   subprocess - one line per parsed marker received from install.sh,
//                plus a line for every prompt answer written to the
//                FIFO. The watchdog warnings funnel through here too
//                so the silence/escalation ladder is visible to
//                `log show` even when the in-app drawer is closed.
//   fingerprint - device-registration POST attempts + outcomes
//                (no fingerprint hex in plaintext; the prefix only).
//
// We default emission level to .info so the app's normal runtime is
// captured without manual --debug. .debug calls require the explicit
// `--debug` flag to show, so per-byte chatter from the readability
// handler should use .debug.

import Foundation
import os

enum OstlerLog {
    private static let subsystem = "ai.ostler.installer"

    static let lifecycle = Logger(subsystem: subsystem, category: "lifecycle")
    static let subprocess = Logger(subsystem: subsystem, category: "subprocess")
    static let fingerprint = Logger(subsystem: subsystem, category: "fingerprint")
}
