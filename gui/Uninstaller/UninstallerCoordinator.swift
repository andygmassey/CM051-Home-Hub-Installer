// UninstallerCoordinator.swift
//
// The coordinator behind Ostler Uninstaller.app: a three-screen flow (confirm -> running ->
// done) that runs the installed ~/.ostler/bin/ostler-uninstall with the chosen
// flags and OSTLER_GUI=1, and renders its #OSTLER phase markers.
//
// It reuses the installer's ProgressDecoder + OutputLineBuffer verbatim (shared
// via the Xcode target's sources), so the wire format has exactly one decoder.
//
// No interactive FIFO: UninstallFlags always passes explicit content + colima
// decisions, so the uninstaller never reaches a prompt. stdin is detached.

import Foundation
import SwiftUI

@MainActor
final class UninstallerCoordinator: ObservableObject {

    enum Screen: Equatable { case confirm, running, done }

    @Published var screen: Screen = .confirm
    @Published var options = UninstallOptions()

    /// Human-readable label for the phase currently running.
    @Published var currentPhase: String = ""
    /// Curated log of notable lines (warnings + phase transitions).
    @Published var logLines: [String] = []

    // Terminal summary, populated from UNINSTALL_DONE (falling back to the
    // process exit code if the marker never arrived).
    @Published var finished = false
    @Published var succeeded = false
    @Published var storesRemoved = true
    @Published var knowledgeStaging = ""
    @Published var colimaResult = ""
    @Published var contentDecision = ""
    @Published var failureMessage: String? = nil

    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var lineBuffer = OutputLineBuffer()
    private var sawDone = false

    /// The installed uninstaller. It is written to ~/.ostler/bin by install.sh.
    private var uninstallScriptPath: String {
        if let override = ProcessInfo.processInfo.environment["OSTLER_UNINSTALL_SCRIPT"],
           !override.isEmpty {
            return override
        }
        return (NSHomeDirectory() as NSString)
            .appendingPathComponent(".ostler/bin/ostler-uninstall")
    }

    /// Whether the installed uninstaller is present. Surfaced so the confirm
    /// screen can explain rather than fail on click.
    var uninstallerPresent: Bool {
        FileManager.default.isReadableFile(atPath: uninstallScriptPath)
    }

    private func note(_ line: String) {
        logLines.append(line)
        if logLines.count > 500 { logLines.removeFirst(logLines.count - 500) }
    }

    private static func phaseLabel(_ name: String) -> String {
        switch name {
        case "launchagents":     return "Removing background services"
        case "remotecapture":    return "Removing RemoteCapture"
        case "hub_app":          return "Removing the Ostler app"
        case "safari_extension": return "Removing the Safari extension"
        case "colima":           return "Checking the shared Docker VM"
        case "knowledge_staging":return "Handling knowledge data"
        case "user_content":     return "Applying your content choice"
        default:                 return "Working"
        }
    }

    func start() {
        guard screen != .running else { return }
        guard uninstallerPresent else {
            failureMessage = "The Ostler uninstaller was not found at "
                + uninstallScriptPath
                + ". Ostler may already be uninstalled."
            succeeded = false
            finished = true
            screen = .done
            return
        }

        let flags = UninstallFlags.build(options)
        note("Running ostler-uninstall " + flags.joined(separator: " "))
        screen = .running
        currentPhase = "Starting"

        let out = Pipe(); let err = Pipe()
        stdoutPipe = out; stderrPipe = err

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = [uninstallScriptPath] + flags
        proc.standardOutput = out
        proc.standardError = err
        proc.standardInput = FileHandle.nullDevice   // no tty; never prompt

        var env = ProcessInfo.processInfo.environment
        env["OSTLER_GUI"] = "1"
        env["TERM"] = "dumb"
        env["NO_COLOR"] = "1"
        proc.environment = env

        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in self?.ingest(s) }
        }
        err.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in self?.ingest(s) }
        }
        proc.terminationHandler = { [weak self] p in
            let code = p.terminationStatus
            Task { @MainActor in self?.handleTermination(exitCode: code) }
        }

        do {
            try proc.run()
            process = proc
        } catch {
            failureMessage = "Could not start the uninstaller: \(error.localizedDescription)"
            succeeded = false
            finished = true
            screen = .done
        }
    }

    private func ingest(_ chunk: String) {
        for line in lineBuffer.ingest(chunk) where !line.isEmpty {
            apply(ProgressDecoder.decode(line: line))
        }
    }

    private func apply(_ event: InstallerEvent) {
        switch event {
        case .uninstallConsent(let value, let source):
            note("Consent: \(value) (\(source))")
        case .uninstallPhase(let name, let metadata):
            currentPhase = Self.phaseLabel(name)
            note(currentPhase)
            if name == "knowledge_staging", let outcome = metadata["outcome"] {
                knowledgeStaging = outcome
            }
        case .uninstallColima(let result):
            colimaResult = result
        case .uninstallDone(let removed, let content, let staging, let colima):
            sawDone = true
            storesRemoved = removed
            contentDecision = content
            if !staging.isEmpty { knowledgeStaging = staging }
            if !colima.isEmpty { colimaResult = colima }
        case .warn(_, let msg):
            note("Warning: \(msg)")
        case .log(_, let msg):
            note(msg)
        default:
            break
        }
    }

    private func handleTermination(exitCode: Int32) {
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        if let tail = lineBuffer.flush(), !tail.isEmpty {
            apply(ProgressDecoder.decode(line: tail))
        }
        lineBuffer.reset()

        // Truth comes from the DONE marker where present, and from the exit
        // code otherwise. exit 3 = "could not ask" (removed nothing); any
        // non-zero without a DONE is a real failure.
        if sawDone {
            succeeded = (exitCode == 0)
        } else {
            succeeded = false
            if exitCode == 3 {
                failureMessage = "The uninstaller could not confirm consent and removed nothing."
            } else {
                failureMessage = "The uninstaller exited with code \(exitCode) before finishing."
            }
        }
        finished = true
        currentPhase = ""
        screen = .done
    }
}
