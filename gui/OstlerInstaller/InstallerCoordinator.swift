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

    // ── Licence gating ────────────────────────────────────────────
    /// Flips true once `verifyLicense` accepts a customer-supplied
    /// licence (or once an existing on-disk licence verifies at
    /// app launch). `bootstrap()` is a no-op until this flips true,
    /// so the installer subprocess never launches without a
    /// signature-verified licence.
    @Published var licenseVerified: Bool = false
    /// The verified claims, for display + future audit hooks.
    @Published var verifiedLicense: LicenseClaims? = nil
    /// Second-stage gate. Once the licence verifies, we still need to
    /// register this Mac's fingerprint with the CM050 Worker so the
    /// three-device cap is honoured. While the gate is `.registering`
    /// the install layout shows a "Checking your licence" hint; on
    /// `.limitReached` / `.fatal` ContentView replaces the install
    /// layout with a hard-stop view. `bootstrap()` only fires once
    /// the gate reaches `.ready`. `.ready` covers both "Worker said
    /// ok" and "network failure, queued for deferred retry" -- the
    /// latter is the deliberate fail-open behaviour from the brief.
    @Published var registrationGate: RegistrationGate = .idle
    /// Lazy so the verifier doesn't try to parse the embedded
    /// public key until we actually need it; that way the unit-
    /// test target's injected verifier short-circuits init.
    private lazy var licenseVerifier: LicenseVerifier? = LicenseVerifier()
    /// Lazy so tests can swap it via `setRegistrationClient(_:)`
    /// before the first verify call.
    private var registrationClient: DeviceRegistrationClient =
        DeviceRegistrationClient()

    enum RegistrationGate: Equatable {
        case idle
        case registering
        case ready
        case limitReached(maxFingerprints: Int, registeredCount: Int)
        case fatal(reason: String)
    }

    /// Test hook: inject a client with a mock transport.
    func setRegistrationClient(_ client: DeviceRegistrationClient) {
        self.registrationClient = client
    }

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

    // ── No-output watchdog ───────────────────────────────────────
    //
    // Mac Studio retest 2026-05-12 PM HKT showed `~/.ostler/` was
    // never created and install.sh + a child bash were both
    // wedged for 8+ hours -- no stdout reached the GUI at all.
    // The watchdog escalates the Log drawer with timestamped
    // warnings at 15s / 30s / 60s + every 60s afterwards so a
    // future hang is visibly different from "running normally
    // but quiet" without requiring TNM to attach a debugger.
    /// Time of the most recent stdout/stderr byte from the
    /// subprocess. Initialised when `launchInstaller` runs.
    private var lastSubprocessOutputAt: Date? = nil
    /// True once we have logged the first-output milestone (so
    /// the "first bytes received" line is emitted exactly once).
    private var firstOutputLogged: Bool = false
    /// Count of `gui_emit`-derived events apply()'d so far, by
    /// type. Surfaced when the watchdog fires so we know whether
    /// it is "no stdout at all" or "stdout flowing but no
    /// markers" (which usually means a stdio buffering issue).
    private var eventCounts: [String: Int] = [:]
    /// Timer that fires the no-output checks.
    private var watchdogTask: Task<Void, Never>? = nil
    /// Tracks how many warning thresholds we have already
    /// surfaced so we do not spam the log drawer on every tick.
    private var watchdogStage: Int = 0

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

    /// Called once when the main window appears. Refuses to launch
    /// install.sh until `licenseVerified` is true (set either by
    /// the on-disk re-verification in `verifyExistingLicenseOnLaunch`
    /// or by a successful drag/paste in `LicenseEntryView`).
    func bootstrap() {
        guard process == nil else {
            OstlerLog.lifecycle.debug("bootstrap: subprocess already running (pid=\(self.process?.processIdentifier ?? -1, privacy: .public))")
            return
        }
        guard licenseVerified else {
            appendLog(level: "info", msg: "Bootstrap deferred -- waiting for licence")
            OstlerLog.lifecycle.info("bootstrap deferred: licenseVerified=false")
            return
        }
        guard registrationGate == .ready else {
            appendLog(level: "info",
                      msg: "Bootstrap deferred -- waiting for device registration gate")
            OstlerLog.lifecycle.info("bootstrap deferred: registrationGate=\(String(describing: self.registrationGate), privacy: .public)")
            return
        }
        appendLog(level: "info", msg: "Bootstrapping installer subprocess")
        OstlerLog.lifecycle.info("bootstrap: launching installer subprocess")
        do {
            try launchInstaller()
        } catch {
            self.error = "Failed to launch installer: \(error.localizedDescription)"
            OstlerLog.lifecycle.error("bootstrap: launch failed -- \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Called from the app's `onAppear`. Tries to re-verify any
    /// existing licence on disk; on success, flips the gate
    /// straight through so returning customers do not re-enter.
    /// Failure (including absence) is silent -- the view falls
    /// through to `LicenseEntryView`.
    func verifyExistingLicenseOnLaunch() {
        guard !licenseVerified else { return }
        guard let data = LicensePersistence.readExisting() else { return }
        _ = verifyLicense(data: data, source: "on-disk")
    }

    /// Verifies a licence document and -- on success -- flips
    /// the gate and persists the bytes to disk. Returns the raw
    /// result so the view can render an inline error.
    @discardableResult
    func verifyLicense(data: Data, source: String) -> LicenseVerificationResult {
        guard let verifier = licenseVerifier else {
            appendLog(level: "error", msg: "Licence verifier unavailable -- production public key not embedded")
            return .malformed(reason: "verifier not initialised (production public key missing or invalid)")
        }
        let result = verifier.verify(licenseData: data)
        switch result {
        case .valid(let claims):
            appendLog(level: "info", msg: "Licence accepted (\(source), licence_id=\(claims.licenseId))")
            OstlerLog.lifecycle.info("verifyLicense: valid source=\(source, privacy: .public) license=\(claims.licenseId, privacy: .public)")
            do {
                try LicensePersistence.write(licenseData: data)
                appendLog(level: "info", msg: "Licence persisted to \(LicensePersistence.defaultLicensePath.path)")
            } catch {
                appendLog(level: "warn", msg: "Licence verified but persistence failed: \(error.localizedDescription)")
                OstlerLog.lifecycle.error("verifyLicense: persistence failed -- \(error.localizedDescription, privacy: .public)")
            }
            verifiedLicense = claims
            licenseVerified = true
            // Kick off the second-stage gate. We do not block the
            // view-thread on it -- the LicenseEntryView dismisses
            // synchronously on .valid; the install layout shows the
            // "Checking your licence" state while we POST.
            registrationGate = .registering
            Task { await self.runDeviceRegistration(claims: claims) }
        case .invalidSignature:
            appendLog(level: "warn", msg: "Licence signature check failed (\(source))")
            OstlerLog.lifecycle.warning("verifyLicense: invalidSignature source=\(source, privacy: .public)")
        case .expired(let expiresAt):
            appendLog(level: "warn", msg: "Licence expired \(expiresAt) (\(source))")
            OstlerLog.lifecycle.warning("verifyLicense: expired source=\(source, privacy: .public) expiresAt=\(expiresAt, privacy: .public)")
        case .malformed(let reason):
            appendLog(level: "warn", msg: "Licence malformed (\(source)): \(reason)")
            OstlerLog.lifecycle.warning("verifyLicense: malformed source=\(source, privacy: .public) reason=\(reason, privacy: .public)")
        }
        return result
    }

    /// Second-stage gate: derive a hardware fingerprint, register it
    /// with the CM050 Worker, and either open the install gate or
    /// surface the limit-reached / revoked / fatal state to the user.
    ///
    /// The brief mandates a fail-open policy on network failure: if
    /// the Worker is briefly unreachable, the install proceeds and
    /// the Hub-side scheduler (deferred-register-device.sh) closes
    /// the loop later. A hard refusal at install time when the
    /// Worker is down would be worse for the customer than the
    /// licence-sharing it prevents.
    private func runDeviceRegistration(claims: LicenseClaims) async {
        guard let fingerprint = HardwareFingerprint.compute() else {
            appendLog(
                level: "error",
                msg: "Hardware fingerprint could not be derived -- IOPlatformUUID/serial unavailable. Aborting install."
            )
            OstlerLog.fingerprint.error("compute returned nil -- IOPlatformUUID/serial unavailable")
            registrationGate = .fatal(
                reason: "This Mac could not be uniquely identified. Please email hello@ostler.ai for help."
            )
            return
        }
        appendLog(
            level: "info",
            msg: "Registering device fingerprint with appcast.ostler.ai"
        )
        // Prefix only -- the hex itself is private; logging it wholesale
        // would defeat the point of the SHA. Length is enough to
        // confirm the encoder produced what we expected.
        OstlerLog.fingerprint.info("register POST license=\(claims.licenseId, privacy: .public) fingerprint=sha256:<64hex>")

        let result = await registrationClient.register(
            licenseId: claims.licenseId,
            fingerprint: fingerprint
        )

        switch result {
        case .ok(let max, let count):
            appendLog(
                level: "info",
                msg: "Device registered (\(count)/\(max == -1 ? "?" : String(max)) Macs)"
            )
            OstlerLog.fingerprint.info("result=ok max=\(max, privacy: .public) count=\(count, privacy: .public)")
            persistFingerprintCache(fingerprint: fingerprint)
            FingerprintState.clearPending()
            registrationGate = .ready
            bootstrap()
        case .limitReached(let max, let count):
            appendLog(
                level: "warn",
                msg: "Device limit reached (\(count)/\(max == 0 ? "?" : String(max)) Macs). Refusing install."
            )
            OstlerLog.fingerprint.warning("result=limitReached max=\(max, privacy: .public) count=\(count, privacy: .public)")
            registrationGate = .limitReached(
                maxFingerprints: max,
                registeredCount: count
            )
        case .licenceNotFound:
            appendLog(level: "error", msg: "Worker reports licence not found.")
            OstlerLog.fingerprint.error("result=licenceNotFound")
            registrationGate = .fatal(
                reason: "Your licence is not recognised by our server. Please email hello@ostler.ai."
            )
        case .revoked:
            appendLog(level: "error", msg: "Worker reports licence revoked / refunded.")
            OstlerLog.fingerprint.error("result=revoked")
            registrationGate = .fatal(
                reason: "Your licence is no longer valid. Please email hello@ostler.ai."
            )
        case .badRequest(let reason):
            appendLog(level: "error", msg: "Worker rejected the registration: \(reason)")
            OstlerLog.fingerprint.error("result=badRequest reason=\(reason, privacy: .public)")
            registrationGate = .fatal(
                reason: "Your licence file was rejected by our server (\(reason)). Please email hello@ostler.ai."
            )
        case .networkFailure(let message):
            appendLog(
                level: "warn",
                msg: "Device registration deferred (network: \(message)). Proceeding with install -- Hub will retry."
            )
            OstlerLog.fingerprint.warning("result=networkFailure message=\(message, privacy: .public) -- queuing for deferred retry")
            do {
                try FingerprintState.writePending(
                    licenseId: claims.licenseId,
                    fingerprint: fingerprint
                )
            } catch {
                appendLog(
                    level: "warn",
                    msg: "Could not write pending-registration queue: \(error.localizedDescription)"
                )
                OstlerLog.fingerprint.error("writePending failed: \(error.localizedDescription, privacy: .public)")
            }
            registrationGate = .ready
            bootstrap()
        }
    }

    private func persistFingerprintCache(fingerprint: String) {
        do {
            try FingerprintState.writeCachedFingerprint(fingerprint)
        } catch {
            appendLog(
                level: "warn",
                msg: "Could not write fingerprint cache: \(error.localizedDescription)"
            )
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
            OstlerLog.subprocess.error("respond: prompt pipe absent -- dropping answer for \(prompt.id, privacy: .public)")
            return
        }
        // Strip embedded newlines so we don't desync the read on the
        // shell side. install.sh's gui_read uses `IFS= read -r` which
        // stops at the first newline.
        let sanitised = answer.replacingOccurrences(of: "\n", with: " ")
        let line = sanitised + "\n"
        handle.write(Data(line.utf8))
        appendLog(level: "info", msg: "Sent answer for \(prompt.id) (\(prompt.kind.rawValue))")
        // Secrets never reach the log -- byte-length only. For non-secret
        // prompts we log the answer at .debug so `log show --debug` can
        // reconstruct the full session; .info stays clean.
        let answerBytes = sanitised.utf8.count
        if prompt.kind == .secret {
            OstlerLog.subprocess.info("respond: id=\(prompt.id, privacy: .public) kind=secret bytes=\(answerBytes)")
        } else {
            OstlerLog.subprocess.info("respond: id=\(prompt.id, privacy: .public) kind=\(prompt.kind.rawValue, privacy: .public) bytes=\(answerBytes)")
            OstlerLog.subprocess.debug("respond:   answer=\(sanitised, privacy: .public)")
        }
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

        // ── Subprocess env ───────────────────────────────────────
        //
        // install.sh line 43 has a TTY-redirect gate:
        //   if [[ ... && ! -t 0 && "${OSTLER_GUI:-0}" != "1" ]]; then
        //       exec < /dev/tty
        //   fi
        //
        // A GUI subprocess has no controlling terminal, so the
        // `exec < /dev/tty` redirect on a missing-OSTLER_GUI path
        // wedges forever waiting for a tty that does not exist
        // -- which is exactly the "Starting..." hang Andy hit on
        // his Mac Studio fresh-install retest. The merge below is
        // idempotent + explicit so the OSTLER_GUI=1 wiring is
        // visible at code-review time and cannot drift.
        //
        // OSTLER_GUI_FD points install.sh's gui_read at the FIFO
        // we set up above; OSTLER_BOOTSTRAP_SCRIPT_DIR short-
        // circuits the tarball-bootstrap branch so install.sh
        // uses the resources bundled in the .app instead.
        let overrides: [String: String] = [
            "OSTLER_GUI": "1",
            "OSTLER_GUI_FD": "4",
            "OSTLER_BOOTSTRAP_SCRIPT_DIR": (scriptPath as NSString).deletingLastPathComponent,
            // Disable colours so the log drawer renders cleanly.
            // install.sh already strips colours when stdout is
            // not a tty, but the bash subshell can keep ansi for
            // some sub-tools (mkdocs, pip).
            "TERM": "dumb",
            "NO_COLOR": "1",
        ]
        let env = ProcessInfo.processInfo.environment
            .merging(overrides) { _, new in new }
        proc.environment = env
        // Surface the gate-relevant env values up-front so a
        // wedged install can be diagnosed from the Log drawer
        // alone (no need to attach a debugger).
        let envSnapshot = overrides
            .keys
            .sorted()
            .map { "\($0)=\(overrides[$0] ?? "")" }
            .joined(separator: " ")
        appendLog(level: "info", msg: "Subprocess env overrides: \(envSnapshot)")

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
        lastSubprocessOutputAt = Date()
        firstOutputLogged = false
        watchdogStage = 0
        eventCounts = [:]
        appendLog(
            level: "info",
            msg: "Installer launched: pid=\(proc.processIdentifier) script=\(scriptPath)"
        )
        OstlerLog.lifecycle.info("launchInstaller: pid=\(proc.processIdentifier, privacy: .public) script=\(scriptPath, privacy: .public) fifo=\(fifoPath, privacy: .public)")
        startWatchdog()
    }

    // MARK: - No-output watchdog

    private func startWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = Task { @MainActor [weak self] in
            // 5-second polling cadence keeps the warning latency
            // tight without flooding the run loop. The escalation
            // ladder caps at 60s of silence; after that we emit
            // an "..."-style heartbeat once per minute.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self else { return }
                if self.finished != nil { return }
                self.tickWatchdog()
            }
        }
    }

    private func tickWatchdog() {
        guard let last = lastSubprocessOutputAt else { return }
        let elapsed = Date().timeIntervalSince(last)

        // First-output milestone is logged separately in
        // handleIncoming. Watchdog only surfaces silence.
        let thresholds: [(seconds: Double, stage: Int, level: String)] = [
            (15,  1, "warn"),
            (30,  2, "warn"),
            (60,  3, "error"),
        ]
        for t in thresholds where watchdogStage < t.stage && elapsed >= t.seconds {
            let summary = eventCounts.isEmpty
                ? "no stdout/stderr received at all"
                : "stdout flowing but no progress markers parsed (counts: \(eventSummary()))"
            appendLog(
                level: t.level,
                msg: "Watchdog: \(Int(elapsed))s since last subprocess output -- \(summary)"
            )
            OstlerLog.subprocess.warning("watchdog: stage=\(t.stage, privacy: .public) elapsed=\(Int(elapsed), privacy: .public)s pid=\(self.process?.processIdentifier ?? -1, privacy: .public) summary=\(summary, privacy: .public)")
            watchdogStage = t.stage
        }
        // After the 60s threshold, heartbeat once per minute.
        if watchdogStage >= 3 && elapsed >= Double(60 * (watchdogStage - 1)) {
            appendLog(
                level: "error",
                msg: "Watchdog: subprocess still silent after \(Int(elapsed))s. PID=\(process?.processIdentifier ?? -1). Consider Cancel + retry."
            )
            OstlerLog.subprocess.error("watchdog: heartbeat elapsed=\(Int(elapsed), privacy: .public)s pid=\(self.process?.processIdentifier ?? -1, privacy: .public)")
            watchdogStage += 1
        }
    }

    private func eventSummary() -> String {
        eventCounts
            .sorted(by: { $0.key < $1.key })
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ",")
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
        // Watchdog bookkeeping. Doing this on every byte (even
        // if utf8 decode fails -- we get here via Data already)
        // is the cheapest path that guarantees we never miss
        // input. firstOutputLogged is a one-shot.
        lastSubprocessOutputAt = Date()
        if !firstOutputLogged {
            firstOutputLogged = true
            let elapsed = startedAt.map { Date().timeIntervalSince($0) } ?? 0
            let preview = chunk
                .replacingOccurrences(of: "\n", with: "\\n")
                .prefix(120)
            appendLog(
                level: "info",
                msg: "First subprocess output after \(String(format: "%.1f", elapsed))s "
                    + "(\(fromStderr ? "stderr" : "stdout"), \(data.count)B): \(preview)"
            )
        }
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
        // Track marker counts so the watchdog can distinguish
        // "no stdout at all" from "stdout flowing but no
        // markers parsed" (which usually means stdio buffering
        // or a missing OSTLER_GUI gate).
        let key: String
        switch event {
        case .stepBegin:  key = "stepBegin"
        case .pct:        key = "pct"
        case .log:        key = "log"
        case .warn:       key = "warn"
        case .prompt:     key = "prompt"
        case .stepEnd:    key = "stepEnd"
        case .phase:      key = "phase"
        case .needsFDA:   key = "needsFDA"
        case .needsSudo:  key = "needsSudo"
        case .done:       key = "done"
        case .rawLine:    key = "rawLine"
        case .unknown:    key = "unknown"
        }
        eventCounts[key, default: 0] += 1

        switch event {
        case .stepBegin(let id, let title, _, let idx, let total):
            currentStepId = id
            currentStepTitle = title
            currentStepPercent = 0
            currentStepIdx = idx ?? currentStepIdx
            totalSteps = total ?? totalSteps
            appendLog(level: "info", msg: "→ \(title) [\(id)]")
            OstlerLog.subprocess.info("event STEP_BEGIN id=\(id, privacy: .public) idx=\(idx ?? -1, privacy: .public)/\(total ?? -1, privacy: .public) title=\(title, privacy: .public)")
        case .pct(_, let pct):
            currentStepPercent = pct
        case .log(let level, let msg):
            // Structured LOG markers always surface -- these are the
            // curated install.sh -> GUI messages. The Verbose toggle
            // only gates rawLine events below.
            appendLog(level: level, msg: msg)
        case .warn(_, let msg):
            appendLog(level: "warn", msg: msg)
            OstlerLog.subprocess.warning("event WARN msg=\(msg, privacy: .public)")
        case .prompt(let id, let kind, let title, let defaultValue, let help, let choices):
            pendingPrompt = PendingPrompt(
                id: id, kind: kind, title: title,
                defaultValue: defaultValue, help: help, choices: choices
            )
            OstlerLog.subprocess.info("event PROMPT id=\(id, privacy: .public) kind=\(kind.rawValue, privacy: .public) title=\(title, privacy: .public) hasDefault=\(defaultValue != nil, privacy: .public) choices=\(choices.count, privacy: .public)")
        case .stepEnd(let id, let status, let elapsed):
            completedSteps.append(CompletedStep(
                id: id,
                title: currentStepTitle,
                status: status,
                elapsed: elapsed
            ))
            appendLog(level: status == .ok ? "info" : "warn",
                      msg: "← \(id) (\(status.rawValue), \(elapsed)s)")
            OstlerLog.subprocess.info("event STEP_END id=\(id, privacy: .public) status=\(status.rawValue, privacy: .public) elapsed=\(elapsed, privacy: .public)s")
        case .phase(let id, let title):
            phase = title
            phaseId = id
            appendLog(level: "info", msg: "Phase: \(title)")
            OstlerLog.subprocess.info("event PHASE id=\(id, privacy: .public) title=\(title, privacy: .public)")
        case .needsFDA(let probe, let reason):
            needsFDA = NeedsFDA(probe: probe, reason: reason)
            appendLog(level: "warn", msg: "Needs FDA: \(reason)")
            OstlerLog.subprocess.warning("event NEEDS_FDA probe=\(probe, privacy: .public) reason=\(reason, privacy: .public)")
        case .needsSudo(let reason):
            needsSudo = reason
            OstlerLog.subprocess.info("event NEEDS_SUDO reason=\(reason, privacy: .public)")
            // Forward to the AuthorizationHelper so the user gets the
            // native prompt rather than a hidden bash sudo prompt.
            Task { await AuthorizationHelper.shared.requestAdminAuthorization(reason: reason) }
        case .done(let status):
            finished = status
            appendLog(level: status == .ok ? "info" : "error",
                      msg: "Install finished: \(status.rawValue)")
            OstlerLog.lifecycle.info("event DONE status=\(status.rawValue, privacy: .public)")
        case .rawLine(let msg):
            // Raw subprocess stdout/stderr that did NOT carry an
            // #OSTLER marker. Only surface in the drawer when the
            // Verbose toggle is on -- pre-#348 these always showed
            // and drowned the curated LOG markers in tool chatter.
            // The os_log telemetry from #345 still receives every
            // line via the subprocess category, so `log show` keeps
            // the full stream regardless of toggle.
            if devModeRawLog {
                appendLog(level: "info", msg: msg)
            }
            OstlerLog.subprocess.debug("rawLine: \(msg, privacy: .public)")
        case .unknown(let raw):
            appendLog(level: "warn", msg: "Unrecognised marker: \(raw)")
            OstlerLog.subprocess.warning("event UNKNOWN raw=\(raw, privacy: .public)")
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
        OstlerLog.lifecycle.info("subprocess terminated exit=\(exitCode, privacy: .public) finished=\(String(describing: self.finished), privacy: .public)")
        watchdogTask?.cancel()
        watchdogTask = nil
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

