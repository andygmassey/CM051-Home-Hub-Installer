// RecoveryCoordinator.swift
//
// Drives the installed `ostler-unlock` redeemer (vendor/ostler_security/
// passphrase_recovery_cli.py, console script `ostler-unlock`) from the
// three-screen flow: enter key -> working -> done (success or failure).
//
// THE KEY NEVER TOUCHES ARGV, A LOG, OR THE UI AFTER SUBMISSION.
//   - it is written to the child process's stdin and the write end is
//     closed immediately after, exactly as a customer typing it into a
//     terminal prompt would deliver it
//   - `--secret-file -` is the flag that tells the redeemer to read
//     stdin rather than expect a value on the command line
//   - `--install-key-file` writes the unlocked key where the Hub services
//     read it (ostler_security.db_key.resolve_db_key()); this app never
//     reads that file back and never renders its contents
//   - stdout and stderr from the child process are drained and DISCARDED.
//     Nothing the redeemer prints is ever shown, logged, or stored, so a
//     future change to its messages cannot leak a key through this app.
//
// This app must work even when the Ostler services are down -- that is
// the situation it exists for -- so it shells out to the installed
// interpreter directly rather than talking to any running daemon.

import Foundation
import SwiftUI

@MainActor
final class RecoveryCoordinator: ObservableObject {

    enum Screen: Equatable { case enterKey, working, success, failure }

    enum FailureReason: Equatable {
        case wrongKey
        case toolMissing
        case couldNotStart
    }

    @Published var screen: Screen = .enterKey
    @Published var keyInput: String = ""
    @Published var failureReason: FailureReason = .wrongKey

    /// The installed redeemer. Written to ~/.ostler/.venv/bin by install.sh;
    /// this is the exact path the documented recovery hint names
    /// (MSG_INFO_DB_KEY_RECOVER_HINT: "%s/.venv/bin/ostler-unlock").
    /// Overridable for development / testing, same pattern as the
    /// uninstaller app's OSTLER_UNINSTALL_SCRIPT override.
    private var unlockBinaryPath: String {
        if let override = ProcessInfo.processInfo.environment["OSTLER_UNLOCK_BIN"],
           !override.isEmpty {
            return override
        }
        return (NSHomeDirectory() as NSString)
            .appendingPathComponent(".ostler/.venv/bin/ostler-unlock")
    }

    private var toolPresent: Bool {
        FileManager.default.isExecutableFile(atPath: unlockBinaryPath)
    }

    var canSubmit: Bool {
        !keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func submit() {
        guard canSubmit, screen != .working else { return }
        let key = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)

        guard toolPresent else {
            failureReason = .toolMissing
            keyInput = ""
            screen = .failure
            return
        }

        screen = .working

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: unlockBinaryPath)
        // --recovery-key is the default mode, named explicitly for clarity.
        // --install-key-file: back-compat-safe even though the redeemer's
        // own default now also installs the file; naming it keeps this call
        // correct regardless of that CLI's default.
        process.arguments = [
            "--recovery-key",
            "--secret-file", "-",
            "--install-key-file",
        ]
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            keyInput = ""
            failureReason = .couldNotStart
            screen = .failure
            return
        }

        // Hand the key to the child's stdin, then close it. Never argv.
        if let data = (key + "\n").data(using: .utf8) {
            stdinPipe.fileHandleForWriting.write(data)
        }
        stdinPipe.fileHandleForWriting.closeFile()

        // The key has done its job in this view model; drop it immediately
        // rather than holding it in @Published state while the process runs.
        keyInput = ""

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Drain and discard. Never inspected, never logged, never
            // rendered -- see the file header.
            _ = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            _ = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let succeeded = process.terminationStatus == 0
            DispatchQueue.main.async {
                guard let self else { return }
                if succeeded {
                    self.screen = .success
                } else {
                    self.failureReason = .wrongKey
                    self.screen = .failure
                }
            }
        }
    }

    func tryAgain() {
        keyInput = ""
        screen = .enterKey
    }
}
