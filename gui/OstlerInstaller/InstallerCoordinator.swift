// InstallerCoordinator.swift
//
// Owns the install.sh subprocess and exposes the install state to
// the SwiftUI views. Three responsibilities:
//
//   1. Spawn install.sh with OSTLER_GUI=1 and an OSTLER_GUI_FD
//      pointing at a writable pipe – the GUI sends prompt answers
//      back to install.sh via that fd.
//   2. Parse stdout/stderr for #OSTLER marker lines via
//      ProgressDecoder and update @Published state.
//   3. Expose hooks for the views: dismissPrompt, requestSudo,
//      cancel, etc.
//
// Phase 1 keeps everything in a single ObservableObject – no
// separate state machine class. If the install state grows past
// ~10 cases this should split out.

import SwiftUI
import Foundation

@MainActor
final class InstallerCoordinator: ObservableObject {
    // ── Published state ──────────────────────────────────────────
    @Published var phase: String = "Preparing"
    @Published var phaseId: String = "boot"
    @Published var currentStepId: String? = nil
    @Published var currentStepTitle: String = "Starting..."
    @Published var currentStepPercent: Int = 0
    @Published var totalSteps: Int = 11
    @Published var currentStepIdx: Int = 0
    @Published var completedSteps: [CompletedStep] = []
    @Published var logLines: [LogLine] = []
    @Published var pendingPrompt: PendingPrompt? = nil
    @Published var needsFDA: NeedsFDA? = nil
    @Published var needsSudo: String? = nil
    @Published var finished: StepStatus? = nil
    @Published var devModeRawLog: Bool = false
    @Published var error: String? = nil

    // ── Process plumbing ─────────────────────────────────────────
    private var process: Process? = nil
    private var stdoutPipe: Pipe? = nil
    private var stderrPipe: Pipe? = nil
    /// Path to the FIFO we feed user prompt answers into. install.sh
    /// reads from fd 4, and a wrapper script `exec 4<"$FIFO"` connects
    /// the two. Lives under $TMPDIR for the duration of the process.
    private var promptFifoPath: String? = nil
    private var promptPipeWriteHandle: FileHandle? = nil
    private var stdoutBuffer = ""
    private var startedAt: Date? = nil

    struct CompletedStep: Identifiable, Equatable {
        let id: String
        let title: String
        let status: StepStatus
        let elapsed: Int
    }

    struct LogLine: Identifiable, Equatable {
        let id = UUID()
        let level: String
        let text: String
        let timestamp: Date
    }

    struct PendingPrompt: Identifiable, Equatable {
        let id: String
        let kind: PromptKind
        let title: String
        let defaultValue: String?
        let help: String?
        let choices: [String]
    }

    struct NeedsFDA: Identifiable, Equatable {
        let id = UUID()
        let probe: String
        let reason: String
    }

    // ── Lifecycle ────────────────────────────────────────────────

    /// Called once when the main window appears.
    func bootstrap() {
        guard process == nil else { return }
        appendLog(level: "info", msg: "Bootstrapping installer subprocess")
        do {
            try launchInstaller()
        } catch {
            self.error = "Failed to launch installer: \(error.localizedDescription)"
        }
    }

    func cancel() {
        guard let process = process, process.isRunning else { return }
        process.terminate()
        appendLog(level: "warn", msg: "Cancelled by user")
    }

    // ── Prompt response (called by views) ────────────────────────

    func respond(to prompt: PendingPrompt, with answer: String) {
        guard let handle = promptPipeWriteHandle else {
            appendLog(level: "error", msg: "No prompt pipe available; answer dropped")
            return
        }
        // Strip embedded newlines so we don't desync the read on the
        // shell side. install.sh's gui_read uses `IFS= read -r` which
        // stops at the first newline.
        let sanitised = answer.replacingOccurrences(of: "\n", with: " ")
        let line = sanitised + "\n"
        handle.write(Data(line.utf8))
        appendLog(level: "info", msg: "Sent answer for \(prompt.id) (\(prompt.kind.rawValue))")
        pendingPrompt = nil
    }

    // ── Process launch ───────────────────────────────────────────

    private func launchInstaller() throws {
        // Resolve install.sh path. Search order:
        //   1. App bundle Resources/install.sh        (productised .app, primary)
        //   2. ../../install.sh relative to the .app  (running from
        //      gui/build/ during dev)
        //   3. OSTLER_INSTALL_SH env var override     (last-resort dev hook)
        //
        // Bundle-first protects customer installs: a stale or hostile
        // OSTLER_INSTALL_SH cannot redirect the installer to an
        // arbitrary script when the .app ships a copy of install.sh.
        let scriptPath = resolveInstallScriptPath()
        guard FileManager.default.isExecutableFile(atPath: scriptPath) else {
            throw NSError(domain: "OstlerInstaller", code: 1,
                          userInfo: [NSLocalizedDescriptionKey:
                                        "install.sh not found or not executable at \(scriptPath)"])
        }

        // ── Prompt FIFO ──────────────────────────────────────────
        // install.sh reads user prompt answers from fd 4 (set via
        // OSTLER_GUI_FD). Foundation's Process doesn't expose
        // arbitrary fd plumbing, so we use a named pipe + a tiny
        // wrapper that does `exec 4<"$FIFO"` before invoking install.sh.
        // The GUI keeps the write end open via FileHandle.
        let tmpDir = NSTemporaryDirectory()
        let fifoPath = (tmpDir as NSString).appendingPathComponent(
            "ostler-installer-prompt-\(getpid()).fifo"
        )
        unlink(fifoPath) // clear any stale fifo
        guard mkfifo(fifoPath, 0o600) == 0 else {
            throw NSError(domain: "OstlerInstaller", code: 2,
                          userInfo: [NSLocalizedDescriptionKey:
                                        "mkfifo failed at \(fifoPath) (errno \(errno))"])
        }
        promptFifoPath = fifoPath

        // Open the write end. O_RDWR avoids ENXIO (mkfifo write-only
        // open blocks until a reader appears) and lets us write
        // before the shell side has finished its `exec 4<"$FIFO"`.
        let writeFD = open(fifoPath, O_RDWR)
        guard writeFD >= 0 else {
            throw NSError(domain: "OstlerInstaller", code: 3,
                          userInfo: [NSLocalizedDescriptionKey:
                                        "fifo write-open failed (errno \(errno))"])
        }
        // closeOnDealloc:true so the fd auto-closes when we drop the
        // handle (we also explicitly closeFile() in handleTermination).
        promptPipeWriteHandle = FileHandle(fileDescriptor: writeFD, closeOnDealloc: true)
        // Sanity: the write side stays alive until the GUI exits.

        // ── Wrapper script ───────────────────────────────────────
        // /bin/bash -c 'exec 4<"$FIFO"; exec install.sh'
        // The leading `exec 4<"$FIFO"` connects fd 4 to the fifo so
        // install.sh's `gui_read` can read from it. The second exec
        // replaces the wrapper shell with install.sh, preserving the
        // process group so the SwiftUI `cancel()` reaches the right pid.
        let wrapper = """
        exec 4<"\(fifoPath)"
        exec "\(scriptPath)"
        """

        let stdout = Pipe()
        let stderr = Pipe()
        stdoutPipe = stdout
        stderrPipe = stderr

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = ["-c", wrapper]
        proc.standardOutput = stdout
        proc.standardError = stderr

        // Detach standardInput from the GUI process so install.sh's
        // `exec < /dev/tty` at line 41 doesn't fire (it only fires
        // when stdin is not a tty AND not a real fd, which our pipe
        // satisfies – but it's still trying to redirect to a tty
        // that doesn't exist for an .app, which would error).
        let inputDevNull = Pipe()
        proc.standardInput = inputDevNull

        var env = ProcessInfo.processInfo.environment
        env["OSTLER_GUI"] = "1"
        env["OSTLER_GUI_FD"] = "4"
        env["OSTLER_BOOTSTRAP_SCRIPT_DIR"] = (scriptPath as NSString).deletingLastPathComponent
        // Disable colours so the log drawer renders cleanly. install.sh
        // already disables colours when stdout is not a tty, but the
        // bash subshell may keep ansi for some sub-tools (mkdocs, pip).
        env["TERM"] = "dumb"
        env["NO_COLOR"] = "1"
        proc.environment = env

        proc.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.handleTermination() }
        }

        // Wire stdout/stderr handlers BEFORE launch so we don't miss
        // early lines. The readabilityHandler closure runs on a
        // background queue; we hop to the main actor before mutating
        // @Published state.
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in
                self?.handleIncoming(data: data, fromStderr: false)
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in
                self?.handleIncoming(data: data, fromStderr: true)
            }
        }

        try proc.run()
        process = proc
        startedAt = Date()
        appendLog(level: "info", msg: "Installer launched (pid \(proc.processIdentifier))")
    }

    private func resolveInstallScriptPath() -> String {
        // 1. App bundle Resources/install.sh (productised .app).
        if let bundled = Bundle.main.path(forResource: "install", ofType: "sh") {
            return bundled
        }
        // 2. Dev fallback: walk up from the app bundle to find
        //    install.sh sitting next to gui/.
        let appPath = Bundle.main.bundlePath
        let candidates = [
            (appPath as NSString).deletingLastPathComponent + "/install.sh",
            (appPath as NSString).deletingLastPathComponent + "/../install.sh",
            (appPath as NSString).deletingLastPathComponent + "/../../install.sh",
            (appPath as NSString).deletingLastPathComponent + "/../../../install.sh",
        ]
        for c in candidates where FileManager.default.fileExists(atPath: (c as NSString).expandingTildeInPath) {
            return (c as NSString).expandingTildeInPath
        }
        // 3. OSTLER_INSTALL_SH env var (last-resort dev hook).
        if let env = ProcessInfo.processInfo.environment["OSTLER_INSTALL_SH"], !env.isEmpty {
            return env
        }
        // Sentinel: returns a path that the caller's executability
        // check will reject with a clear error.
        return "(install.sh not bundled and no dev copy found)"
    }

    // ── Incoming data parsing ────────────────────────────────────

    private func handleIncoming(data: Data, fromStderr: Bool) {
        guard let chunk = String(data: data, encoding: .utf8) else { return }
        stdoutBuffer.append(chunk)

        while let nlIdx = stdoutBuffer.firstIndex(of: "\n") {
            var line = String(stdoutBuffer[..<nlIdx])
            stdoutBuffer.removeSubrange(...nlIdx)
            // Strip stray CR (a handful of tool outputs put CRLF
            // even into pipes; harmless to be defensive).
            if line.hasSuffix("\r") {
                line.removeLast()
            }
            if line.isEmpty { continue }
            let event = ProgressDecoder.decode(line: line)
            apply(event: event, fromStderr: fromStderr)
        }
    }

    private func apply(event: InstallerEvent, fromStderr: Bool) {
        switch event {
        case .stepBegin(let id, let title, _, let idx, let total):
            currentStepId = id
            currentStepTitle = title
            currentStepPercent = 0
            currentStepIdx = idx ?? currentStepIdx
            totalSteps = total ?? totalSteps
            appendLog(level: "info", msg: "→ \(title) [\(id)]")
        case .pct(_, let pct):
            currentStepPercent = pct
        case .log(let level, let msg):
            // Don't double-log raw markers when devModeRawLog is off.
            if !devModeRawLog && msg.hasPrefix("#OSTLER\t") { return }
            appendLog(level: level, msg: msg)
        case .warn(_, let msg):
            appendLog(level: "warn", msg: msg)
        case .prompt(let id, let kind, let title, let defaultValue, let help, let choices):
            pendingPrompt = PendingPrompt(
                id: id, kind: kind, title: title,
                defaultValue: defaultValue, help: help, choices: choices
            )
        case .stepEnd(let id, let status, let elapsed):
            completedSteps.append(CompletedStep(
                id: id,
                title: currentStepTitle,
                status: status,
                elapsed: elapsed
            ))
            appendLog(level: status == .ok ? "info" : "warn",
                      msg: "← \(id) (\(status.rawValue), \(elapsed)s)")
        case .phase(let id, let title):
            phase = title
            phaseId = id
            appendLog(level: "info", msg: "Phase: \(title)")
        case .needsFDA(let probe, let reason):
            needsFDA = NeedsFDA(probe: probe, reason: reason)
            appendLog(level: "warn", msg: "Needs FDA: \(reason)")
        case .needsSudo(let reason):
            needsSudo = reason
            // Forward to the AuthorizationHelper so the user gets the
            // native prompt rather than a hidden bash sudo prompt.
            Task { await AuthorizationHelper.shared.requestAdminAuthorization(reason: reason) }
        case .done(let status):
            finished = status
            appendLog(level: status == .ok ? "info" : "error",
                      msg: "Install finished: \(status.rawValue)")
        case .unknown(let raw):
            appendLog(level: "warn", msg: "Unrecognised marker: \(raw)")
        }
    }

    private func handleTermination() {
        let exitCode = process?.terminationStatus ?? -1
        if finished == nil {
            // Process ended without a DONE marker – surface an error.
            finished = exitCode == 0 ? .ok : .fail
            if exitCode != 0 {
                error = "Installer exited with code \(exitCode) before signalling DONE."
            }
        }
        appendLog(level: "info", msg: "Subprocess terminated (exit \(exitCode))")
        promptPipeWriteHandle?.closeFile()
        promptPipeWriteHandle = nil
        if let path = promptFifoPath {
            unlink(path)
            promptFifoPath = nil
        }
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
    }

    // ── Logging ──────────────────────────────────────────────────

    private func appendLog(level: String, msg: String) {
        logLines.append(LogLine(level: level, text: msg, timestamp: Date()))
        // Keep the in-memory log bounded – Phase 3 will spool older
        // lines to disk for the crash reporter.
        if logLines.count > 5_000 {
            logLines.removeFirst(logLines.count - 5_000)
        }
    }
}

// MARK: - Notes on fd plumbing
//
// We considered dup2'ing a pipe read-end onto fd 4 in the parent
// before launch + relying on inheritance, but Foundation's Process
// uses posix_spawn under the hood and doesn't propagate parent fds
// other than 0/1/2 reliably. Using a named pipe (FIFO) + a
// `bash -c 'exec 4<"$FIFO"; exec install.sh'` wrapper sidesteps the
// whole issue: the kernel handles the fifo, fd 4 is set up by bash,
// and the GUI just needs the file path.

