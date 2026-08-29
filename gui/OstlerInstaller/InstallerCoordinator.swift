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
// NSApp.terminate + FileManager.trashItem on the single quit sink.
import AppKit

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
    // CX-87: front-loaded FDA gate. True when the very first launch has
    // no Full Disk Access yet; ContentView shows FullDiskAccessGateView
    // and nothing else runs until the customer grants it and reopens.
    @Published var needsFullDiskAccessUpfront: Bool = false
    @Published var needsSudo: String? = nil
    @Published var finished: StepStatus? = nil
    /// CX-126: set true when install.sh emits `DONE status=cancelled`
    /// on a deliberate user-cancel / consent-decline path. Distinct
    /// from `finished == .fail` so ContentView can render a calm
    /// neutral "Installation cancelled" terminal instead of the red
    /// failure banner. ContentView checks this BEFORE the gated/finished
    /// branches.
    @Published var cancelled: Bool = false

    // ── Post-success auto-quit (v1.0.42 walk, finding 1a) ─────────
    //
    // The installer used to sit open indefinitely after a successful
    // install. On the v1.0.42 walk it sat there holding 4.27 GB until
    // macOS ran the whole box out of application memory. The leak itself
    // is fixed in OutputLineBuffer; this bounds every FUTURE retention
    // path we have not found yet, by making "left open forever after
    // success" impossible.
    //
    // Unconditional and unpromptable BY DECISION: an installer that has
    // finished its job has no reason to hold a process. The countdown is
    // visible so it is never a surprise, and every CTA on the completion
    // screen (Open Ostler, Open your Wiki, the pairing QR, Copy log)
    // stays live for the whole window.

    /// Seconds granted on the completion screen before the app quits.
    /// Long enough to scan the pairing QR, short enough that an idle
    /// installer cannot outlive the session.
    static let autoQuitSeconds = 300

    /// Seconds left before the automatic quit; nil when not armed.
    @Published var autoQuitRemaining: Int? = nil

    /// Set when the memory ceiling has been breached. Surfaced in the GUI
    /// so a customer watching a slow install has an explanation before
    /// macOS gives them one.
    @Published var memoryCeilingBreached: Bool = false

    /// Offer-to-trash, DEFAULTED TO KEEP. Pre-fix the "Done" button trashed
    /// OstlerInstaller.app unconditionally and silently (CX-52). The upgrade
    /// re-run is a legitimate repair route -- we exercised it on the v1.0.42
    /// walk -- and CM031 #637 is the standing example of what "your only
    /// escape is delete and reinstall" costs. So the installer is KEPT unless
    /// the customer asks for it to go.
    @Published var trashInstallerOnQuit: Bool = false

    private var autoQuitTask: Task<Void, Never>? = nil

    /// The terminate sink, injectable. Two reasons, both load-bearing:
    /// a test must be able to drive `finishAndQuit()` without killing its own
    /// host process, and the trash decision must be assertable separately
    /// from the termination it precedes.
    var quitAction: () -> Void = { NSApp.terminate(nil) }

    /// Records whether the bundle was actually moved to the Trash on the way
    /// out, so the keep/trash decision is observable rather than inferred
    /// from a side effect on the filesystem.
    private(set) var didTrashInstaller = false

    @Published var devModeRawLog: Bool = false
    @Published var error: String? = nil
    /// CX-17 (2026-05-23): stable error code carried on the DONE
    /// marker when install.sh fires `fail_with_code`. Surfaces on
    /// the failure banner header + the auto-copied log header sent
    /// to support, so triage can hop from "customer pasted code
    /// ERR-17-DOCTOR-MISSING" straight to the source line. Nil on
    /// the success path; nil on legacy bare-`fail` callsites (the
    /// test harness asserts none remain).
    @Published var lastErrorCode: String? = nil
    /// CX-53 (DMG ship, 2026-05-24): the recovery key produced by
    /// install.sh's setup_passphrase, captured from the structured
    /// `#OSTLER RECOVERY_KEY value=...` marker. RecoveryKeyView (the
    /// sheet shown over InstallCompleteView) reads this value and
    /// renders it in monospace with Copy / Save PDF / Print buttons
    /// + a confirm checkbox. DELIBERATELY kept out of `logLines` --
    /// the Log drawer is visible to anyone the customer hands the
    /// Mac to, so we route the secret through a dedicated property
    /// and let the customer dismiss the sheet once they have saved
    /// it somewhere safe.
    @Published var recoveryKey: String? = nil
    /// CX-53: set to true once the customer ticks "I've saved this
    /// somewhere safe" + clicks Continue on RecoveryKeyView. Drives
    /// the sheet's isPresented binding so the sheet dismisses + the
    /// underlying InstallCompleteView remains usable.
    @Published var recoveryKeyAcknowledged: Bool = false
    /// True when the very first `bootstrap()` attempt asked the user
    /// for admin access via the native macOS AppleScript dialog and
    /// the user clicked Cancel (or the osascript call otherwise
    /// returned non-zero). Surfaces a full-screen retry view in
    /// `ContentView` -- the install subprocess is NOT launched until
    /// this clears. Mac Studio retest 2026-05-19 PM HKT: without
    /// the pre-launch grant install.sh's `sudo -v` at line 2574
    /// exits non-zero on a fresh Mac with no warm sudo timestamp.
    @Published var needsAdminRetry: Bool = false

    /// True between bootstrap's initial gate-pass and the moment the
    /// customer presses "Continue and enter your password". Set by
    /// `bootstrapAsync()` after the licence + registration gates
    /// clear, cleared by `userAcknowledgedAdminRequest()`. While
    /// true, ContentView renders `AdminAccessRequiredView` with the
    /// explanation copy + a single primary button; the macOS
    /// admin dialog does NOT fire until the customer clicks the
    /// button. Studio retest #2 (2026-05-20) found that firing the
    /// dialog on first appear surprised customers who hadn't yet
    /// read the surrounding explanation.
    @Published var needsAdminAcknowledgement: Bool = false

    /// True while the macOS admin authorisation osascript dialog is
    /// in flight. Drives the button's disabled state + suppresses
    /// the duplicate-fire that Studio retest #2 (2026-05-20) flagged
    /// (two `Requesting administrator access via macOS native dialog`
    /// log lines in the same second pre-fix). Both
    /// `bootstrapAsync()` and `retryAdminAuthorization()` short-
    /// circuit when this is true.
    @Published var requestingAdmin: Bool = false

    /// Most-recent install-side status line surfaced as ephemeral
    /// copy on the main content area. Mac Studio retest #2 (2026-05-20)
    /// flagged a 20-second invisible pause after Q1 while install.sh
    /// read the contact card + exported contacts; the log lines were
    /// landing in the LogDrawer (hidden by default) so the customer
    /// thought the installer had hung. This field mirrors the most
    /// recent `info`-level subprocess message so the main view can
    /// render it as a visible status banner during quiet windows.
    @Published var preInstallStatus: String? = nil

    /// CX-14 D5 (2026-05-23): true when the no-output watchdog has
    /// passed the first silence threshold and the subprocess has gone
    /// quiet without finishing. Drives a customer-visible "Still
    /// going, please wait" overlay near the spinner in HintPanelView.
    /// Pre-fix the watchdog only logged into the (hidden by default)
    /// LogDrawer, so a wedged install looked indistinguishable from
    /// a slow one. Cleared as soon as fresh stdout/stderr arrives.
    @Published var watchdogSilent: Bool = false

    // ── Failure-state machine (CX-14 D-section, 2026-05-23) ──────
    //
    // `InstallerCoordinator` already exposes the relevant signals
    // (`finished`, `currentStepId`, `error`) but the CX-14 brief
    // asked for an explicit `.failed(step:)` shape so D1-D6 share a
    // single source of truth.
    //
    // Rather than introduce a parallel state-machine enum (which
    // would require porting every existing branch in
    // SidebarView/ContentView/HintPanelView), the failure state is
    // derived from the existing signals via the `failureState`
    // helper below. The helper IS the contract: anything that wants
    // to render the failure shape (sidebar xmark, banner, error
    // pane, watchdog overlay suppression) goes through it.
    //
    // The contract: `failureState` returns a `.failed(step:)` value
    // EXACTLY WHEN `finished == .fail`. The step id carries the
    // identifier of the step that was active when the install died
    // so the sidebar can pin the xmark to the right row. When the
    // install has not finished or finished okay, `failureState`
    // returns `.running` or `.success` respectively.
    enum InstallerState: Equatable {
        case running
        case success
        case failed(step: String?)
    }

    /// Derives a single failure-state snapshot from `finished` +
    /// `currentStepId`. CX-14 (2026-05-23): D1-D6 all read this
    /// helper instead of duplicating the `finished == .fail` checks
    /// scattered across views.
    var failureState: InstallerState {
        switch finished {
        case .none: return .running
        case .some(.ok): return .success
        case .some(.warn): return .success // warn surfaces in-line; not a failure transition
        // #839: DONE never carries these two today (they are step-level
        // statuses), but the enum is shared, so state the intent rather
        // than leaving it to a default. A run that gave up waiting still
        // reached the end; a run that errored did not.
        case .some(.timeout): return .success
        case .some(.error): return .failed(step: currentStepId)
        case .some(.fail): return .failed(step: currentStepId)
        }
    }

    // ── Onboarding question rendering (in-window, #353) ──────────
    //
    // The Studio retry on 2026-05-16 surfaced that 12+ sheet-style
    // popups during onboarding feel endless to the customer. Route B
    // (per the brief) keeps install.sh's FIFO protocol unchanged and
    // changes only how the GUI renders incoming PROMPT markers: a new
    // `OnboardingQuestionView` is rendered in the main content area
    // instead of `.sheet(item:)`. The view reads from `pendingPrompt`
    // (live) or `answerHistory[backReviewIndex]` (read-only review).
    //
    // X is a monotonic counter incremented on each *unique* PROMPT id
    // so the customer sees "Question 5" rather than guessing how many
    // taps remain. CX-14 D4 fix 2026-05-23: re-emits of the SAME
    // prompt id (install.sh validation retry loops -- e.g.
    // `whatsapp_recipient`, `imessage_allowed`, `assistant_name` each
    // sit in `while [[ -z … ]]; do gui_read … done`) must NOT advance
    // X. Pre-fix, an empty input on Q9 (whatsapp_recipient) would tick
    // the header to Q10 on the retry even though the customer had
    // not committed an answer, drifting the counter for every later
    // question. `seenPromptIds` tracks committed-or-displayed ids so
    // retries are idempotent on X.
    @Published var currentQuestionIndex: Int = 0
    /// Set of prompt ids already counted in `currentQuestionIndex`.
    /// CX-14 D4 fix (2026-05-23): install.sh's validation retry loops
    /// re-emit the same prompt id when the customer enters invalid
    /// input. Without de-dup the X counter advances on each retry
    /// instead of staying pinned to "Question N", producing the
    /// "Q9 off-by-one" Studio retest #8 flagged.
    private var seenPromptIds: Set<String> = []
    /// Map of prompt id -> the X (currentQuestionIndex) value the
    /// prompt was first displayed at. CX-97 fix (DMG #48g+1,
    /// 2026-05-29): when install.sh re-emits an EARLIER prompt
    /// (e.g. recovery_passphrase after recovery_passphrase_confirm
    /// landed a mismatch), the seenPromptIds dedupe correctly stops
    /// X from advancing, but pre-fix X stayed at the LATEST seen
    /// value -- so the customer saw "Question 15: Choose your
    /// passphrase" even though that was originally Q14. The
    /// promptIdToIndex map lets us restore X to the prompt's
    /// original index so the header re-aligns with the prompt body
    /// on re-emit.
    private var promptIdToIndex: [String: Int] = [:]
    @Published var totalQuestionCount: Int? = nil
    @Published var answerHistory: [AnsweredQuestion] = []
    /// When set, the OnboardingQuestionView renders the matching
    /// history entry in read-only review mode rather than the live
    /// `pendingPrompt`. v7.1 keeps Back semantics conservative: the
    /// customer can look at what they typed before, but cannot edit
    /// it (the answer is already on the FIFO and bash has consumed
    /// it). Edit-and-resend is Route A, deferred.
    @Published var backReviewIndex: Int? = nil

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
        // v1.0.10 security lockdown: the bounded offline fail-open
        // grace has been exhausted for this licence on this Mac. We
        // refuse to proceed until the device can reach the Worker and
        // complete a real registration.
        case offlineGraceExhausted(attempts: Int)
    }

    /// Test hook: inject a client with a mock transport.
    func setRegistrationClient(_ client: DeviceRegistrationClient) {
        self.registrationClient = client
    }

    #if DEBUG
    /// Test seam. Routes a synthetic stdout line through the same
    /// ProgressDecoder + apply path the production readability
    /// handler uses, so unit tests can drive sidebar / phase / step
    /// state transitions without standing up a real subprocess.
    /// Marked DEBUG so it cannot accidentally ship to customers.
    func simulateLineForTests(_ line: String) {
        let event = ProgressDecoder.decode(line: line)
        apply(event: event, fromStderr: false)
    }

    /// Test seam for the no-output watchdog (CX-14 D5). Lets unit
    /// tests rewind `lastSubprocessOutputAt` past the silence
    /// threshold + drive `tickWatchdog()` deterministically without
    /// waiting on the real 5-second Task.sleep cadence.
    func simulateWatchdogSilenceForTests(elapsedSeconds: Double) {
        lastSubprocessOutputAt = Date(timeIntervalSinceNow: -elapsedSeconds)
        tickWatchdog()
    }

    /// Test seam for the failure-state machine (CX-14 D1/D2). Sets
    /// the underlying signals without running install.sh so unit
    /// tests can assert that `failureState` returns
    /// `.failed(step: <expected>)` and that the sidebar / banner
    /// derivations stay aligned.
    func simulateFailureForTests(step: String?, errorMessage: String? = nil) {
        currentStepId = step
        finished = .fail
        error = errorMessage
    }

    /// Test seam. Simulates the answer-side of a prompt commit
    /// without requiring the real promptPipeWriteHandle to be open
    /// -- exercises the answer-history append + total-question
    /// recompute path that `respond(to:with:)` shares. The FIFO
    /// write is intentionally skipped (no subprocess to receive it).
    func applyAnswerForTests(promptId: String, answer: String) {
        guard let prompt = pendingPrompt, prompt.id == promptId else {
            assertionFailure("applyAnswerForTests: pendingPrompt missing or id mismatch")
            return
        }
        let stored: String = prompt.kind == .secret ? "(hidden)" : answer
        answerHistory.append(AnsweredQuestion(
            index: currentQuestionIndex,
            prompt: prompt,
            answer: stored
        ))
        recomputeTotalQuestionCount(committedPromptId: prompt.id, answer: answer)
        pendingPrompt = nil
        backReviewIndex = nil
    }
    #endif

    // ── Process plumbing ─────────────────────────────────────────
    private var process: Process? = nil
    private var stdoutPipe: Pipe? = nil
    private var stderrPipe: Pipe? = nil
    /// Path to the FIFO we feed user prompt answers into. install.sh
    /// reads from fd 4, and a wrapper script `exec 4<"$FIFO"` connects
    /// the two. Lives under $TMPDIR for the duration of the process.
    private var promptFifoPath: String? = nil
    private var promptPipeWriteHandle: FileHandle? = nil
    /// Bounded line accumulator. Was a bare `String` that grew by one
    /// retained byte per byte received whenever the producer emitted no
    /// "\n" -- 20 MiB of `\r`-delimited progress measured 20,984,000 chars
    /// retained and 0 lines parsed, permanently. See OutputLineBuffer.swift
    /// for the measurement and its control.
    private var stdoutBuffer = OutputLineBuffer()
    private var startedAt: Date? = nil
    /// One-shot latch so the "output was dropped" notice is logged once per
    /// install rather than on every subsequent chunk.
    private var droppedOutputReported: Bool = false

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
        /// CX-97 (DMG #48g+1, 2026-05-29): validation-retry error
        /// surfaced as an oxblood banner above the prompt input on
        /// the re-emitted prompt (e.g. "Passphrases don't match.
        /// Try again."). install.sh's secret-confirm loops populate
        /// this via gui_read's $7 error_text arg. Nil on the happy
        /// path / first display.
        let error: String?

        /// v1.0.11 (blank-prompt-title fix): the heading actually
        /// rendered in the onboarding modal. A PROMPT is a blocking
        /// modal; install.sh occasionally emits one without a
        /// `title=` (secret-mismatch retry loops, custom questions),
        /// which the decoder now surfaces as an empty string rather
        /// than a literal "?". Fall back to the prompt `id` so the
        /// modal never renders "?" as its heading.
        var displayTitle: String {
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            return (trimmed.isEmpty || trimmed == "?") ? id : trimmed
        }
    }

    /// One committed answer in the onboarding flow. Captured when
    /// `respond(to:with:)` writes to the FIFO so Back can re-show
    /// the prompt + answer for review.
    struct AnsweredQuestion: Identifiable, Equatable {
        /// The X value at the time of commit (1-based).
        let index: Int
        let prompt: PendingPrompt
        /// Stored answer. Secret prompts persist a placeholder marker
        /// rather than plaintext so the review state can render
        /// safely without leaking the secret.
        let answer: String
        var id: String { "\(index)_\(prompt.id)" }
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
    ///
    /// Public surface is sync (SwiftUI `onAppear`/`onChange` calls
    /// it without `await`); the body hops to an async task so it
    /// can await `AuthorizationHelper` for the pre-launch sudo grant.
    /// See `bootstrapAsync()` for the actual sequencing.
    func bootstrap() {
        Task { @MainActor in await self.bootstrapAsync() }
    }

    /// The real bootstrap body. Two-phase per F3 (Studio retest #2
    /// 2026-05-20): phase 1 confirms the licence + registration
    /// gates and parks at `needsAdminAcknowledgement = true` so the
    /// AdminAccessRequiredView can render its explanation copy and
    /// wait for the customer to press Continue. Phase 2 (see
    /// `userAcknowledgedAdminRequest()`) actually fires the osascript
    /// dialog + launches the subprocess.
    ///
    /// Two reentrancy guards:
    ///   - `requestingAdmin` short-circuits a second call while the
    ///     dialog or launch is in flight (the duplicate-fire Studio
    ///     retest #2 caught).
    ///   - `needsAdminAcknowledgement` short-circuits a second call
    ///     while we are parked waiting for the customer.
    private func bootstrapAsync() async {
        guard process == nil else {
            OstlerLog.lifecycle.debug("bootstrap: subprocess already running (pid=\(self.process?.processIdentifier ?? -1, privacy: .public))")
            return
        }
        guard !requestingAdmin else {
            OstlerLog.lifecycle.debug("bootstrap: admin authorisation already in flight -- short-circuit")
            return
        }
        guard !needsAdminAcknowledgement else {
            OstlerLog.lifecycle.debug("bootstrap: already parked waiting for user acknowledgement -- short-circuit")
            return
        }
        guard permissionsPrewarmFinished else {
            appendLog(level: "info", msg: "Bootstrap deferred -- waiting for permissions intro to complete")
            OstlerLog.lifecycle.info("bootstrap deferred: permissionsPrewarmFinished=false state=\(String(describing: self.permissionsIntroState), privacy: .public)")
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
        // Sidebar tick for the GUI-only `license_entry` step. The
        // step has no install.sh-side STEP_BEGIN/END counterpart, so
        // the sidebar must mark it complete itself when we leave the
        // licence gate. Idempotent -- duplicate completions for the
        // same id are deduped by markStepCompletedIfMissing.
        markStepCompletedIfMissing(id: "license_entry", status: .ok)

        // ── Phase 1: park for user acknowledgement ───────────────
        // ContentView renders AdminAccessRequiredView when
        // `needsAdminAcknowledgement` is true; the customer reads
        // the explanation copy and clicks the primary button to
        // proceed. That click calls userAcknowledgedAdminRequest()
        // which runs the real osascript + launch sequence (phase 2).
        needsAdminAcknowledgement = true
        OstlerLog.lifecycle.info("bootstrap: parked at admin-acknowledgement gate")
    }

    /// Phase 2 of the bootstrap. Fired by the AdminAccessRequiredView
    /// primary button. Drives the osascript admin dialog -- on
    /// success seeds the sudo timestamp + launches install.sh; on
    /// cancel surfaces the retry UI.
    func userAcknowledgedAdminRequest() {
        Task { @MainActor in await self.requestAdminAndLaunch() }
    }

    private func requestAdminAndLaunch() async {
        // Single-fire guard. F2 root cause: `bootstrap()` was called
        // from BOTH the registrationGate `.onChange` AND the direct
        // call inside `runDeviceRegistration` on the .ok path. Both
        // got a Task hop on the main actor, and by the time either
        // body awaited the AuthorizationHelper, the `process == nil`
        // guard still let the second one through. Two osascript
        // dialogs stacked on screen. The user-acknowledgement gate
        // (`needsAdminAcknowledgement`) already prevents that today
        // because only one button-press can land, but we keep the
        // `requestingAdmin` latch as belt-and-braces against any
        // future re-entry path (e.g. a Retry tap landing on top of
        // an in-flight dialog).
        guard !requestingAdmin else {
            OstlerLog.lifecycle.debug("requestAdminAndLaunch: already in flight -- ignoring re-entry")
            return
        }
        guard process == nil else {
            OstlerLog.lifecycle.debug("requestAdminAndLaunch: subprocess already running -- ignoring")
            return
        }
        requestingAdmin = true
        needsAdminAcknowledgement = false
        // CX-126: light the HintPanel spinner the instant the customer
        // taps Continue. Clearing needsAdminAcknowledgement flips the
        // view from AdminAccessRequiredView to installLayout, whose
        // HintPanel only renders its spinner+status when preInstallStatus
        // is non-empty. The osascript admin dialog has a visible spin-up
        // wait (longest on the post-FDA Quit&Reopen relaunch path), and
        // without this only the easily-missed footer dot spins, so the
        // tap reads as ignored. Subprocess LOG markers overwrite this on
        // the granted path; the not-granted path clears it below.
        preInstallStatus = ViewCopy.shared.string(for: "admin_access_required.requesting_status")
        defer { requestingAdmin = false }

        let reason = ViewCopy.shared.string(for: "admin_access_required.prompt_reason")
        appendLog(level: "info", msg: "Requesting administrator access via macOS native dialog")
        OstlerLog.lifecycle.info("requestAdminAndLaunch: requesting admin authorisation before subprocess launch")
        let granted = await adminAuthorizationProvider(reason)
        if !granted {
            preInstallStatus = nil
            needsAdminRetry = true
            error = ViewCopy.shared.string(for: "admin_access_required.retry_message")
            appendLog(level: "warn", msg: "Administrator access not granted -- holding install at retry gate")
            OstlerLog.lifecycle.warning("requestAdminAndLaunch: admin authorisation declined or failed -- not launching subprocess")
            return
        }
        // Clear any retry state left over from a prior cancel.
        needsAdminRetry = false
        if error == ViewCopy.shared.string(for: "admin_access_required.retry_message") {
            error = nil
        }

        appendLog(level: "info", msg: "Bootstrapping installer subprocess")
        OstlerLog.lifecycle.info("requestAdminAndLaunch: launching installer subprocess")
        do {
            if let override = launchInstallerOverride {
                try override()
            } else {
                try launchInstaller()
            }
        } catch {
            self.error = "Failed to launch installer: \(error.localizedDescription)"
            OstlerLog.lifecycle.error("requestAdminAndLaunch: launch failed -- \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Triggered by the Retry button on the admin-access-required
    /// screen. Clears the retry latch and re-runs the admin
    /// authorisation directly, which will re-invoke
    /// `AuthorizationHelper` and re-prompt the user. The helper's
    /// internal 240s grant-cache avoids a duplicate dialog if a
    /// previous attempt actually succeeded and the customer hit
    /// Retry by mistake.
    ///
    /// 2026-05-20: Retry goes straight to `requestAdminAndLaunch()`
    /// (phase 2) rather than back through `bootstrap()` (phase 1).
    /// The customer has already seen the explanation copy; making
    /// them tap Continue again would feel like a loop.
    func retryAdminAuthorization() {
        needsAdminRetry = false
        error = nil
        userAcknowledgedAdminRequest()
    }

    /// Provider closure for the pre-launch admin authorisation.
    /// Defaults to the production `AuthorizationHelper.shared`
    /// actor; tests inject a stub via `setAdminAuthorizationProvider(_:)`.
    /// The closure receives the prompt reason and returns `true`
    /// on success, `false` on user-cancel or osascript failure.
    private var adminAuthorizationProvider: (String) async -> Bool = { reason in
        await AuthorizationHelper.shared.requestAdminAuthorization(reason: reason)
    }

    #if DEBUG
    /// Test seam. Replaces the admin-authorisation provider with a
    /// stub so unit tests can drive both the happy path and the
    /// user-cancel path without standing up the macOS osascript
    /// dialog. Marked DEBUG so it cannot accidentally ship.
    func setAdminAuthorizationProvider(_ provider: @escaping (String) async -> Bool) {
        self.adminAuthorizationProvider = provider
    }

    /// Test seam. Overrides the launch step so unit tests can verify
    /// that `bootstrapAsync()` proceeds to attempt the subprocess
    /// launch on the happy path, without actually spawning install.sh.
    /// Replaces the production `launchInstaller()` call inside the
    /// async bootstrap body when set.
    func setLaunchInstallerOverride(_ override: @escaping () throws -> Void) {
        self.launchInstallerOverride = override
    }
    private var launchInstallerOverride: (() throws -> Void)? = nil
    #else
    private let launchInstallerOverride: (() throws -> Void)? = nil
    #endif

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

    // ── Permissions intro + pre-warm state machine (CX-17) ──────────
    //
    // CX-14 Section E1 (2026-05-23) introduced the pre-warm. CX-17
    // (2026-05-23) layered an intro screen + serial sequencing on
    // top after the Studio retest log showed all four TCC dialogs
    // firing AND grants/denies landing in the same second. Andy did
    // not see two of the four popups and ended up with silent
    // denies he would have allowed.
    //
    // Surface contract:
    //   - `permissionsIntroState` drives the view layer. ContentView
    //     renders PermissionsIntroView while the state is .intro /
    //     .requesting / .summary. Once it flips to .complete or
    //     .skipped, ContentView falls through to the licence + admin
    //     gates.
    //   - `bootstrap()` already guards on `licenseVerified` +
    //     `registrationGate == .ready`. CX-17 adds an additional
    //     guard via `permissionsPrewarmFinished` so the install
    //     subprocess cannot launch with the intro screen still up.
    //     Belt-and-braces: the view layer also gates the licence
    //     entry on the intro state, so the licence-verify path
    //     never runs in parallel with the pre-warm popups.
    //
    /// Drives the intro / pre-warm flow. The view layer (ContentView)
    /// gates the licence entry + every downstream surface on this.
    /// `permissionsIntroVisible` returns true while the customer
    /// has not yet finished with the intro flow.
    @Published var permissionsIntroState: PermissionsIntroState = .intro

    /// Per-permission results from the most recent prewarm() call.
    /// Set when prewarm() returns; consumed by the summary screen
    /// AND by any future telemetry path that wants to know which
    /// permissions the customer ended up granting.
    @Published var permissionsPrewarmResults: [PermissionsPrewarmer.Result] = []

    /// True when the intro flow has produced a terminal outcome
    /// (complete or skipped). bootstrap() refuses to launch while
    /// this is false. The view layer also reads this to know when
    /// to fall through to LicenseEntryView.
    var permissionsPrewarmFinished: Bool {
        switch permissionsIntroState {
        case .complete, .skipped: return true
        case .intro, .requesting, .summary: return false
        }
    }

    /// Override hook for tests: lets unit tests inject a stub
    /// `PermissionRequester` + a zero gapMillis so the sequencing
    /// path runs deterministically without sleeping in real time.
    /// Production code leaves this nil and the production defaults
    /// from `PermissionsPrewarmer.init` apply.
    private var permissionsPrewarmerFactory: (@MainActor () -> PermissionsPrewarmer)? = nil

    #if DEBUG
    /// Test seam. Installs a custom `PermissionsPrewarmer` factory
    /// so the sequencing test can drive `beginPermissionsPrewarm()`
    /// against a spy without spinning up the real CNContactStore /
    /// EKEventStore / PHPhotoLibrary. Marked DEBUG so it cannot
    /// accidentally ship.
    func setPermissionsPrewarmerFactory(_ factory: @escaping @MainActor () -> PermissionsPrewarmer) {
        self.permissionsPrewarmerFactory = factory
    }
    #endif

    /// CX-14 Section E1 (2026-05-23) + CX-17 (2026-05-23). Mid-install
    /// auth pre-warm with intro screen + sequenced requests.
    ///
    /// Fires the Contacts/Calendar/Reminders/Photos TCC requests at
    /// app launch, BEFORE install.sh spawns. The intro screen lands
    /// FIRST and explains what is about to happen; the customer
    /// taps Grant permissions to fire the actual requests serially
    /// with an 800ms gap between each (CX-17 fix for Andy missing
    /// two of the four popups on Studio retest 2026-05-23).
    /// install.sh then inherits the resulting TCC state via
    /// parent-bundle attribution.
    ///
    /// This closes:
    ///   - C4 (TCC subprocess attribution): install.sh's children
    ///     no longer need to coax their own TCC grants out of a
    ///     detached subprocess context; the .app already has them.
    ///   - E1 (mid-install pop-ups): the customer is no longer
    ///     surprised by Contacts/Calendar prompts surfacing 10
    ///     minutes into the install while they have walked away.
    ///   - CX-17 (concurrent burst): the customer sees one popup
    ///     at a time with a beat between them.
    ///
    /// FDA is NOT pre-warmed here -- it has no requestAccess API
    /// and is granted manually via System Settings. The existing
    /// FullDiskAccessSheet flow handles that.
    ///
    /// Idempotency: macOS short-circuits subsequent requestAccess
    /// calls (returning the already-decided status without re-
    /// prompting), so this method can be safely called from
    /// onAppear without worrying about re-prompting on a re-launch.
    /// We still log per-call to surface state in the LogDrawer.
    /// CX-87: the FIRST thing the app does on launch (after the
    /// self-relocator). If the bundle already has Full Disk Access we
    /// fall straight through to the normal permissions/licence/install
    /// flow. If not, we raise the up-front FDA gate and stop -- the
    /// customer switches FDA on, macOS makes them quit, and on reopen
    /// this runs again, the probe passes, and the entire setup runs
    /// once with FDA in place. This is what stops the mid-install
    /// quit-and-reopen that used to drop the app onto the reuse path.
    func gateFullDiskAccessThenStart() {
        if AuthorizationHelper.shared.hasFullDiskAccess() {
            needsFullDiskAccessUpfront = false
            OstlerLog.lifecycle.info("FDA gate: access present -- continuing to permissions/licence flow")
            requestPermissionsThenStart()
        } else {
            needsFullDiskAccessUpfront = true
            OstlerLog.lifecycle.info("FDA gate: access NOT granted -- showing up-front Full Disk Access screen")
        }
    }

    /// CX-87: bound to the "I've switched it on" button on the FDA gate,
    /// as a fallback for the case where macOS did not force-quit the app
    /// after the grant. Re-probes; if FDA is now present, drops the gate
    /// and proceeds, otherwise leaves the gate up.
    func recheckFullDiskAccessAndProceed() {
        if AuthorizationHelper.shared.hasFullDiskAccess() {
            OstlerLog.lifecycle.info("FDA gate: re-check passed -- continuing")
            needsFullDiskAccessUpfront = false
            requestPermissionsThenStart()
        } else {
            OstlerLog.lifecycle.info("FDA gate: re-check still without access -- holding on gate")
        }
    }

    func requestPermissionsThenStart() {
        // CX-17: this method now ONLY puts the intro screen on
        // screen. The actual prewarm() fires when the customer
        // taps the Grant permissions button -> beginPermissionsPrewarm().
        // The previous (CX-14) shape fired prewarm() directly here,
        // which produced the concurrent-burst regression.
        guard permissionsIntroState == .intro else {
            // Idempotent: a re-fire from onAppear (window restored,
            // etc.) must not reset the customer's progress through
            // the flow.
            return
        }
        OstlerLog.lifecycle.info("permissionsPrewarm: intro screen presented")
    }

    /// Triggered by the Grant permissions button in PermissionsIntroView.
    /// Runs the SERIAL request loop in PermissionsPrewarmer, captures
    /// per-permission results, then either advances to .complete (all
    /// granted) or .summary(denials:) (one or more denied).
    func beginPermissionsPrewarm() {
        guard permissionsIntroState == .intro else {
            OstlerLog.lifecycle.debug("beginPermissionsPrewarm: ignored -- state=\(String(describing: self.permissionsIntroState), privacy: .public)")
            return
        }
        permissionsIntroState = .requesting
        OstlerLog.lifecycle.info("permissionsPrewarm: customer tapped Grant permissions -- starting serial request loop")
        Task { @MainActor in
            let prewarmer = makePrewarmer()
            let results = await prewarmer.prewarm()
            self.permissionsPrewarmResults = results
            let denials = results.filter { !$0.granted }.map(\.permission)
            if denials.isEmpty {
                self.permissionsIntroState = .complete
                OstlerLog.lifecycle.info("permissionsPrewarm: all four permissions granted -- advancing")
            } else {
                self.permissionsIntroState = .summary(denials: denials)
                OstlerLog.lifecycle.info("permissionsPrewarm: \(denials.count, privacy: .public) permission(s) not granted -- showing summary")
            }
        }
    }

    /// Triggered by the Skip for now button in PermissionsIntroView.
    /// The customer can grant later via System Settings; install.sh
    /// has skip-on-deny fallbacks everywhere.
    func skipPermissionsPrewarm() {
        guard permissionsIntroState == .intro else { return }
        permissionsIntroState = .skipped
        appendLog(level: "info", msg: "Permissions pre-warm skipped by user. Grants can be added later in System Settings > Privacy & Security.")
        OstlerLog.lifecycle.info("permissionsPrewarm: customer tapped Skip for now")
    }

    /// Triggered by the Continue install button on the denial
    /// summary screen. Advances the state machine to .complete so
    /// the licence + bootstrap flow can proceed.
    func acknowledgePermissionsDenialSummary() {
        guard case .summary = permissionsIntroState else { return }
        permissionsIntroState = .complete
        OstlerLog.lifecycle.info("permissionsPrewarm: customer acknowledged denial summary -- continuing to install")
    }

    private func makePrewarmer() -> PermissionsPrewarmer {
        if let factory = permissionsPrewarmerFactory {
            return factory()
        }
        return PermissionsPrewarmer(emitLog: { [weak self] level, msg in
            self?.appendLog(level: level, msg: msg)
        })
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
            // v1.0.10: a real registration resolved -- reset the
            // bounded offline fail-open ledger.
            FingerprintState.clearOfflineGrace()
            registrationGate = .ready
            bootstrap()
        case .limitReached(let max, let count):
            appendLog(
                level: "warn",
                msg: "Device limit reached (\(count)/\(max == 0 ? "?" : String(max)) Macs). Refusing install."
            )
            OstlerLog.fingerprint.warning("result=limitReached max=\(max, privacy: .public) count=\(count, privacy: .public)")
            // v1.0.10: a definitive cap answer resolves the bounded
            // offline fail-open ledger.
            FingerprintState.clearOfflineGrace()
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
            // v1.0.10 security lockdown: BOUNDED fail-open. Pre-fix
            // this unconditionally set `.ready` + bootstrapped, so a
            // blocked appcast.ostler.ai let one licence install on
            // unlimited Macs. We now consult a per-licence, per-Mac
            // bounded grace: proceed a small, time-boxed number of
            // times (each queuing a deferred hard re-check), then
            // refuse. The cross-Mac case is only fully closable
            // Hub-side (the deferred re-check must DEACTIVATE, not
            // just warn, on a 409) -- see the PR body tradeoff note.
            switch FingerprintState.evaluateOfflineGrace(licenseId: claims.licenseId) {
            case .proceed(let attempt):
                appendLog(
                    level: "warn",
                    msg: "Device registration deferred (network: \(message)). Proceeding offline (grace \(attempt)/\(FingerprintState.maxOfflineProceeds)) -- Hub will hard re-check."
                )
                OstlerLog.fingerprint.warning("result=networkFailure message=\(message, privacy: .public) -- offline grace attempt=\(attempt, privacy: .public) queuing for deferred retry")
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
            case .exhausted(let attempts):
                appendLog(
                    level: "error",
                    msg: "Device registration keeps failing offline (\(attempts) attempts). Refusing to proceed until this Mac can reach our server."
                )
                OstlerLog.fingerprint.error("result=networkFailure offline grace EXHAUSTED attempts=\(attempts, privacy: .public) -- blocking install")
                // Keep the pending queue so a later online run / the
                // Hub-side deferred script can still resolve it, but do
                // NOT bootstrap: the install is blocked.
                registrationGate = .offlineGraceExhausted(attempts: attempts)
            }
        }
    }

    /// Drives the sidebar tick state from PHASE events.
    ///
    /// install.sh emits coarse PHASE markers via its `step()` helper
    /// (Checking prerequisites, Setup..., Installing, ...) AND fine
    /// STEP_BEGIN/STEP_END markers via its `progress()` helper for the
    /// individual install lines. The fine markers update
    /// `currentStepId` + append to `completedSteps` directly. The
    /// coarse markers do NOT -- the early phases (`prereq_check`,
    /// `setup_questions`) never get a STEP_BEGIN, so pre-#347 the
    /// sidebar stayed unticked through Check-Mac + the 12-popup
    /// onboarding.
    ///
    /// This helper bridges the gap. When a PHASE arrives whose id is
    /// present in StepCatalog.canonicalOrder, every earlier entry in
    /// the canonical order is back-filled as completed (status=ok),
    /// and the active row moves to the phase id.
    ///
    /// PHASE ids that are NOT in canonicalOrder (e.g. `install`,
    /// `finish` which are wrappers rather than steps) leave the
    /// sidebar alone -- the subsequent STEP_BEGIN markers will
    /// drive the tick state from there.
    private func advanceSidebarFromPhase(id: String) {
        guard StepCatalog.canonicalOrder.contains(id) else { return }
        backfillCanonicalEntriesBefore(id: id)
        currentStepId = id
    }

    /// Mark every canonical-order entry before `id` as completed (if
    /// not already). Shared by `.phase` and `.stepBegin` so a sidebar
    /// row never gets stranded as "active forever" when the phase or
    /// step chain jumps past it without an explicit STEP_END.
    private func backfillCanonicalEntriesBefore(id: String) {
        let order = StepCatalog.canonicalOrder
        guard let index = order.firstIndex(of: id), index > 0 else { return }
        for earlierId in order.prefix(index) {
            markStepCompletedIfMissing(id: earlierId, status: .ok)
        }
    }

    /// Append a `CompletedStep` for `id` if one is not already
    /// present. Idempotent so phases that are seen multiple times
    /// (e.g. a re-run from a checkpoint) do not produce duplicate
    /// sidebar entries.
    private func markStepCompletedIfMissing(id: String, status: StepStatus) {
        guard !completedSteps.contains(where: { $0.id == id }) else { return }
        let title = StepCatalog.shared.meta(for: id)?.title ?? id
        completedSteps.append(CompletedStep(
            id: id,
            title: title,
            status: status,
            elapsed: 0
        ))
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
        // Record this answer so Back can re-show it for review.
        // Secrets are never persisted in plaintext -- store a marker
        // so the review state can render "(hidden)" without leaking.
        let storedAnswer: String = prompt.kind == .secret
            ? "(hidden)"
            : sanitised
        answerHistory.append(AnsweredQuestion(
            index: currentQuestionIndex,
            prompt: prompt,
            answer: storedAnswer
        ))
        // Compute / refine Y as branch decisions reveal themselves.
        recomputeTotalQuestionCount(committedPromptId: prompt.id, answer: sanitised)
        pendingPrompt = nil
        backReviewIndex = nil
    }

    /// Estimates the total number of onboarding prompts the customer
    /// will see. Called after each prompt commits because some
    /// answers reveal new branches (e.g. opting into a custom IMAP
    /// server adds ~7 follow-up prompts). v7.1 ships approximate
    /// numbers -- the header gracefully degrades to "Question X" if
    /// X ever exceeds the current Y estimate, so over-shooting is
    /// the worst-case (the customer sees the suffix vanish, no
    /// false-precision is shown). Route A (v2) replaces this with
    /// install.sh emitting an explicit total alongside each PROMPT.
    fileprivate func recomputeTotalQuestionCount(committedPromptId id: String, answer: String) {
        switch id {
        case "channel_choice":
            // install.sh choices: 1=iMessage only, 2=email only,
            // 3=both, 4=skip. The baseline path (pre channels +
            // post-channels system prompts) is ~12 prompts. Channel
            // sub-flows add the per-channel question counts below.
            let trimmed = answer.trimmingCharacters(in: .whitespaces)
            let baseline = 12
            let channelAddend: Int
            switch trimmed {
            case "1": channelAddend = 1   // iMessage allowed contacts only
            case "2": channelAddend = 3   // Apple Mail (Y/n) + IMAP (Y/n) + folder
            case "3": channelAddend = 4   // iMessage allowlist + email triplet
            case "4": channelAddend = 0   // skip all channels
            default:  channelAddend = 2
            }
            totalQuestionCount = baseline + channelAddend
        case "email_custom_imap":
            // A "Y" on the custom IMAP question commits the customer
            // to host / port / smtp-host / smtp-port / username /
            // password / password-confirm -- about 7 extra prompts.
            // "N" / blank means we already counted the lightweight
            // path; leave the total alone.
            if answer.lowercased().hasPrefix("y"), let existing = totalQuestionCount {
                totalQuestionCount = existing + 7
            }
        default:
            break
        }
    }

    /// Step backwards into the answer history to review what the
    /// customer typed previously. v7.1 ships review-only Back: the
    /// previous answer is read-only because bash has already
    /// consumed it off the FIFO and a re-submit would land against
    /// the next pending read. Route A (full edit-and-resend) is the
    /// next iteration.
    func enterBackReview() {
        guard !answerHistory.isEmpty else { return }
        let target = (backReviewIndex ?? answerHistory.count) - 1
        backReviewIndex = max(0, target)
    }

    /// Step forward inside review mode (towards the live prompt). If
    /// we are already at the most-recent entry, exit review entirely.
    func exitBackReview() {
        guard let idx = backReviewIndex else { return }
        let next = idx + 1
        if next >= answerHistory.count {
            backReviewIndex = nil
        } else {
            backReviewIndex = next
        }
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
            // KEEP PYTHON BYTECODE OUT OF THE SIGNED BUNDLE.
            //
            // install.sh runs the Python interpreter shipped at
            // Contents/Resources/python. CPython writes __pycache__/*.pyc NEXT
            // TO the source it imports, and that source is inside the notarised
            // app, so every run breaks the code seal.
            //
            // MEASURED on the v1.0.36 box, 2026-08-18, after the walk:
            //   codesign --verify --deep --strict  rc=1
            //   spctl -a -t exec -vv               rc=1, Gatekeeper REFUSES
            //   239 .pyc inside the bundle (plus 17 egg-info, fixed separately
            //   by routing the ostler_fda pip install through
            //   _ostler_pip_install_pkg)
            //
            // PYTHONPYCACHEPREFIX rather than PYTHONDONTWRITEBYTECODE: the
            // prefix REDIRECTS the cache to a writable dir, so repeat runs keep
            // the startup benefit. DONTWRITEBYTECODE would suppress caching
            // entirely and would also be silently defeated if anything later
            // sets the prefix. One mechanism, not two fighting.
            "PYTHONPYCACHEPREFIX": (NSHomeDirectory() as NSString)
                .appendingPathComponent(".ostler/cache/pycache"),
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

        // Option B replacement for install.sh's `sudo pmset` calls:
        // a per-process caffeinate assertion that lives for the
        // duration of the install. No sudo, no system-wide state
        // change, no cleanup-on-crash debt. See CaffeinateManager.
        if let caffeinatePid = CaffeinateManager.shared.start() {
            appendLog(level: "info", msg: "Sleep prevention armed (caffeinate pid=\(caffeinatePid))")
            OstlerLog.lifecycle.info("caffeinate started pid=\(caffeinatePid, privacy: .public)")
        } else {
            appendLog(level: "warn",
                      msg: "Could not start caffeinate -- machine may sleep during install. Keep the lid open / mouse moving.")
            OstlerLog.lifecycle.warning("caffeinate failed to start; install will proceed without sleep prevention")
        }

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
        // Memory ceiling first: it must fire whether or not the subprocess is
        // producing output. Unbounded growth with output still flowing is the
        // exact case the silence watchdog cannot see.
        tickMemoryCeiling()

        guard let last = lastSubprocessOutputAt else { return }
        let elapsed = Date().timeIntervalSince(last)

        // CX-14 D5 (2026-05-23): expose the watchdog state to the
        // main content area so HintPanelView can render a visible
        // "Still going, please wait" overlay near the spinner.
        // Threshold at 15s matches the first warning threshold below;
        // pre-fix the watchdog only logged into the (hidden) drawer.
        // Skip while a prompt is pending -- the customer is the slow
        // path then, not the installer.
        let shouldSurface = elapsed >= 15
            && pendingPrompt == nil
            && backReviewIndex == nil
            && finished == nil
        if shouldSurface != watchdogSilent {
            watchdogSilent = shouldSurface
        }

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

    // MARK: - Memory ceiling
    //
    // Runs on the same 5s cadence as the silence watchdog. See
    // MemoryCeiling.swift for why this is not a kill switch.

    /// Highest severity already announced, so the log drawer gets one line
    /// per escalation rather than one every five seconds.
    private var memoryCeilingStage: Int = 0

    private func tickMemoryCeiling() {
        // nil means the kernel refused the query. That is NOT zero, and it
        // must not be classified as healthy -- skip the tick instead.
        guard let footprint = MemoryCeiling.currentFootprint() else { return }
        switch MemoryCeiling.verdict(footprint: footprint) {
        case .ok:
            return
        case .warn(let bytes):
            guard memoryCeilingStage < 1 else { return }
            memoryCeilingStage = 1
            appendLog(
                level: "warn",
                msg: "Installer memory footprint is \(MemoryCeiling.megabytes(bytes)) MB "
                    + "(warning threshold \(MemoryCeiling.megabytes(MemoryCeiling.warnBytes)) MB). "
                    + "This is not normal for an install; the log below is the record."
            )
            OstlerLog.lifecycle.warning("memory ceiling WARN footprint=\(bytes, privacy: .public)B")
        case .critical(let bytes):
            guard memoryCeilingStage < 2 else { return }
            memoryCeilingStage = 2
            let mb = MemoryCeiling.megabytes(bytes)
            appendLog(
                level: "error",
                msg: "Installer memory footprint is \(mb) MB, past the "
                    + "\(MemoryCeiling.megabytes(MemoryCeiling.criticalBytes)) MB ceiling. "
                    + "The install is still running. If macOS warns that the system has run out "
                    + "of application memory, quit the installer and run it again -- re-running is "
                    + "safe and picks up where this left off."
            )
            OstlerLog.lifecycle.error("memory ceiling CRITICAL footprint=\(bytes, privacy: .public)B")
            memoryCeilingBreached = true
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
        // CX-14 D5 (2026-05-23): clear the visible "Still going"
        // overlay as soon as fresh output arrives. The tick handler
        // re-arms it if silence continues, but the customer needs
        // the immediate signal that the installer is moving again.
        if watchdogSilent { watchdogSilent = false }
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
        // Bounded, terminator-agnostic. "\r" ends a line as well as "\n", so
        // progress redraws are PARSED instead of accumulated, and retention
        // is capped regardless of what the producer emits.
        for line in stdoutBuffer.ingest(chunk) {
            if line.isEmpty { continue }
            let event = ProgressDecoder.decode(line: line)
            apply(event: event, fromStderr: fromStderr)
        }

        // A drop is a real event, not a normal steady state. Say so once, so
        // a truncated log is never mistaken for a complete one.
        if stdoutBuffer.droppedBytes > 0 && !droppedOutputReported {
            droppedOutputReported = true
            appendLog(
                level: "warn",
                msg: "Subprocess emitted more than \(OutputLineBuffer.defaultMaxBufferBytes / 1024) KiB "
                    + "with no line terminator; that run was discarded to bound memory. "
                    + "The full text is in the install log on disk."
            )
            OstlerLog.subprocess.warning("output line buffer hit its ceiling; dropped=\(self.stdoutBuffer.droppedBytes, privacy: .public)B")
        }
    }

    private func apply(event: InstallerEvent, fromStderr: Bool) {
        // Track marker counts so the watchdog can distinguish
        // "no stdout at all" from "stdout flowing but no
        // markers parsed" (which usually means stdio buffering
        // or a missing OSTLER_GUI gate).
        let key: String
        switch event {
        case .stepBegin:   key = "stepBegin"
        case .step:        key = "step"
        case .pct:         key = "pct"
        case .log:         key = "log"
        case .warn:        key = "warn"
        case .prompt:      key = "prompt"
        case .stepEnd:     key = "stepEnd"
        case .phase:       key = "phase"
        case .needsFDA:    key = "needsFDA"
        case .needsSudo:   key = "needsSudo"
        case .done:        key = "done"
        case .cancelled:   key = "cancelled"
        case .recoveryKey: key = "recoveryKey"
        case .rawLine:     key = "rawLine"
        case .unknown:     key = "unknown"
        }
        eventCounts[key, default: 0] += 1

        switch event {
        case .stepBegin(let id, let title, _, let idx, let total):
            // Back-fill any earlier canonical-order entries that
            // never received their own marker. This covers the
            // PHASE -> STEP_BEGIN transition where the phase id
            // (e.g. `setup_questions`) was a coarse marker without a
            // STEP_BEGIN counterpart; the first STEP_BEGIN ticks
            // the phase row complete.
            backfillCanonicalEntriesBefore(id: id)
            currentStepId = id
            // v1.0.11 (blank-step-title fix): RETAIN the last known step
            // title when a STEP_BEGIN arrives without a usable one. On
            // the late settling/enrichment stream a title-less STEP_BEGIN
            // decoded to the "?" sentinel (now ""), which this used to
            // slam straight into the H1 -- Andy's "weird new '?' titled
            // page". Only overwrite the displayed title when the incoming
            // marker actually carries a non-empty title; never blank it.
            // (Belt-and-braces on "?" too, in case an older emitter or a
            // pre-fix decoder is ever in the loop.)
            let incomingTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !incomingTitle.isEmpty && incomingTitle != "?" {
                currentStepTitle = incomingTitle
            }
            currentStepPercent = 0
            currentStepIdx = idx ?? currentStepIdx
            totalSteps = total ?? totalSteps
            appendLog(level: "info", msg: "→ \(currentStepTitle) [\(id)]")
            OstlerLog.subprocess.info("event STEP_BEGIN id=\(id, privacy: .public) idx=\(idx ?? -1, privacy: .public)/\(total ?? -1, privacy: .public) title=\(self.currentStepTitle, privacy: .public) rawTitle=\(title, privacy: .public)")
        case .step(let id, let metadata):
            // #201 (v1.0.13.1 box-walk, 2026-08-01): bare STEP marker.
            // install.sh emits `#OSTLER STEP name=<id> [k=v ...]` for
            // out-of-band screens that don't fit the stepBegin/stepEnd
            // cadence (the original callsite is permissions_briefing --
            // the "10 macOS popups coming up" walk-through slotted
            // between the setup_questions PHASE and the first install
            // stepBegin). Route through the same backfill +
            // currentStepId path stepBegin uses so the sidebar advances
            // rather than stranding "A few questions" as active for the
            // duration of the briefing. Title falls back to the
            // StepCatalog entry when one exists, otherwise a formatted
            // version of the id -- matches the fallback pattern in
            // markStepCompletedIfMissing so out-of-band ids get a
            // readable label without needing a HintCopy.json entry.
            backfillCanonicalEntriesBefore(id: id)
            currentStepId = id
            currentStepTitle = StepCatalog.shared.meta(for: id)?.title
                ?? id.replacingOccurrences(of: "_", with: " ").capitalized
            currentStepPercent = 0
            appendLog(level: "info", msg: "→ \(currentStepTitle) [\(id)]")
            // Sort metadata by key so the os_log line is stable across
            // runs (dict ordering is unspecified; a stable line makes
            // log-diffing across box-walks tractable).
            let metaSuffix = metadata.isEmpty
                ? ""
                : " " + metadata.keys.sorted().map { "\($0)=\(metadata[$0] ?? "")" }.joined(separator: " ")
            OstlerLog.subprocess.info("event STEP id=\(id, privacy: .public)\(metaSuffix, privacy: .public)")
        case .pct(_, let pct):
            currentStepPercent = pct
        case .log(let level, let msg):
            // Structured LOG markers always surface -- these are the
            // curated install.sh -> GUI messages. The Verbose toggle
            // only gates rawLine events below.
            appendLog(level: level, msg: msg)
            // F4 (Studio retest #2 2026-05-20): mirror the most-recent
            // info-level message onto `preInstallStatus` so the main
            // content area can render it as a visible status banner
            // during the 20-second contact-card pre-fill + export
            // window. We only mirror info/ok-style messages so warn
            // and error stay in the LogDrawer (where the failed
            // banner picks them up).
            if level == "info" {
                preInstallStatus = msg
            }
        case .warn(_, let msg):
            appendLog(level: "warn", msg: msg)
            OstlerLog.subprocess.warning("event WARN msg=\(msg, privacy: .public)")
        case .prompt(let id, let kind, let title, let defaultValue, let help, let choices, let error):
            pendingPrompt = PendingPrompt(
                id: id, kind: kind, title: title,
                defaultValue: defaultValue, help: help, choices: choices,
                error: error
            )
            // CX-14 D4 fix (2026-05-23): only advance X for the
            // FIRST appearance of a given prompt id. install.sh's
            // validation retry loops (`while [[ -z … ]]; do gui_read
            // … done`) re-emit the same id when the customer types
            // empty input; without the dedupe, X drifts ahead of the
            // questions the customer has actually committed to,
            // surfacing as Studio retest #8's "Q9 off-by-one". Back
            // review tracking remains untouched (its own index).
            //
            // CX-97 fix (DMG #48g+1, 2026-05-29): on FIRST display
            // record the prompt's index in promptIdToIndex; on a
            // re-emit RESTORE X to that recorded index. Pre-fix, X
            // stayed pinned at the latest-seen value, so re-emitting
            // an EARLIER prompt (e.g. recovery_passphrase after
            // recovery_passphrase_confirm fired a mismatch) left the
            // header showing the LATER question number with the
            // EARLIER prompt's title -- the "adds +1 to the question
            // number" complaint Andy filed on the DMG #48g retest.
            if !seenPromptIds.contains(id) {
                seenPromptIds.insert(id)
                currentQuestionIndex += 1
                promptIdToIndex[id] = currentQuestionIndex
            } else if let originalIndex = promptIdToIndex[id] {
                currentQuestionIndex = originalIndex
            }
            // If the customer is in a Back review when a new prompt
            // arrives, drop them back into the live view -- the
            // previous prompt is now stale.
            backReviewIndex = nil
            // Clear the F4 status banner; we are about to render a
            // prompt and the stale "Reading your contacts..." copy
            // would just clutter the screen.
            preInstallStatus = nil
            OstlerLog.subprocess.info("event PROMPT id=\(id, privacy: .public) kind=\(kind.rawValue, privacy: .public) title=\(title, privacy: .public) hasDefault=\(defaultValue != nil, privacy: .public) choices=\(choices.count, privacy: .public) hasError=\(error != nil, privacy: .public) x=\(self.currentQuestionIndex, privacy: .public) y=\(self.totalQuestionCount ?? -1, privacy: .public)")
        case .stepEnd(let id, let status, let elapsed):
            completedSteps.append(CompletedStep(
                id: id,
                title: currentStepTitle,
                status: status,
                elapsed: elapsed
            ))
            // #839: `isProblem` rather than `!= .ok` so a status added
            // later is logged as a problem by default. The rc that
            // produced a timeout/error is on the STEP_END marker itself
            // and reaches the Log drawer through the raw line.
            appendLog(level: status.isProblem ? "warn" : "info",
                      msg: "← \(id) (\(status.rawValue), \(elapsed)s)")
            OstlerLog.subprocess.info("event STEP_END id=\(id, privacy: .public) status=\(status.rawValue, privacy: .public) elapsed=\(elapsed, privacy: .public)s")
        case .phase(let id, let title):
            // v1.0.11 (blank-step-title fix): retain the current phase
            // strap when a PHASE arrives without a usable title so the
            // strap above the H1 never flashes "?"/blank. The sidebar
            // advance keys off `id`, so it still fires regardless.
            let incomingPhase = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !incomingPhase.isEmpty && incomingPhase != "?" {
                phase = incomingPhase
            }
            phaseId = id
            appendLog(level: "info", msg: "Phase: \(phase)")
            OstlerLog.subprocess.info("event PHASE id=\(id, privacy: .public) title=\(self.phase, privacy: .public) rawTitle=\(title, privacy: .public)")
            advanceSidebarFromPhase(id: id)
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
        case .done(let status, let code):
            finished = status
            // CX-17 (2026-05-23): when install.sh emits a stable
            // error code via fail_with_code, store it on the
            // coordinator so InstallFailedBannerView can render it
            // on the failure-banner header AND the SupportMailtoBuilder
            // can attach a Reference: ERR-NN-* line to the log
            // header sent to support. A nil code (success path, or
            // a legacy bare `fail "..."` callsite) leaves the field
            // untouched -- the test harness asserts every fail call
            // is wrapped with a code so this should never happen on
            // the failure path in practice.
            if let code, status == .fail {
                lastErrorCode = code
            }
            let suffix = code.map { " [\($0)]" } ?? ""
            appendLog(level: status == .ok ? "info" : "error",
                      msg: "Install finished: \(status.rawValue)\(suffix)")
            OstlerLog.lifecycle.info("event DONE status=\(status.rawValue, privacy: .public) code=\(code ?? "", privacy: .public)")
        case .cancelled:
            // CX-126: the customer deliberately cancelled / declined a
            // consent gate; install.sh exited cleanly having written
            // nothing. NOT a failure -- render the calm neutral
            // terminal. Set BEFORE finished stays nil so handleTermination
            // does not re-interpret the no-`finished` state as a crash.
            cancelled = true
            appendLog(level: "info", msg: "Installation cancelled by the user. Nothing was installed.")
            OstlerLog.lifecycle.info("event DONE status=cancelled -- user cancelled, neutral terminal (CX-126)")
        case .recoveryKey(let value):
            // CX-53 (DMG ship, 2026-05-24): capture the recovery key
            // from install.sh into a dedicated @Published property.
            // We DO NOT call appendLog with the value -- the Log
            // drawer is visible to anyone the customer hands the Mac
            // to, and a recovery key in the drawer would be a
            // significant secret leak. We DO log a non-secret marker
            // line so the support log header carries evidence the
            // sheet was surfaced, just without the value itself.
            if !value.isEmpty {
                recoveryKey = value
                recoveryKeyAcknowledged = false
                appendLog(level: "info", msg: "Recovery key ready -- shown in the GUI sheet")
                OstlerLog.lifecycle.info("event RECOVERY_KEY received (value redacted)")
            } else {
                OstlerLog.lifecycle.warning("event RECOVERY_KEY received with empty value")
            }
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

    /// Outcome of reconciling the two completion signals install.sh
    /// hands the GUI: the protocol DONE marker (parsed into `finished`)
    /// AND the OS process exit code. CX-454 made both load-bearing so a
    /// disagreement can never be papered over as success.
    enum TerminationOutcome: Equatable {
        /// Clean success: a `DONE status=ok` marker AND exit 0. Nothing
        /// to change; the existing `.ok` terminal stands.
        case confirmedSuccess
        /// Clean failure already signalled by a `DONE status=fail`
        /// marker (whatever the exit code). Nothing to override.
        case confirmedFailure
        /// User cancel / consent-decline. Neutral terminal stands.
        case cancelled
        /// The two signals disagree, or there was no DONE marker at all.
        /// MUST be surfaced as a loud failure with `message`, even if
        /// the OS exit code was 0. Covers: (a) no DONE marker (script
        /// died mid-flight, e.g. a `set -u` abort) -- CX-126; and
        /// (b) a `DONE status=ok` marker that is contradicted by a
        /// non-zero exit code (a tail command after the marker, or the
        /// bash wrapper itself, died) -- CX-454.
        case failure(message: String)
    }

    /// Pure reconciliation of the DONE marker against the OS exit code.
    /// Extracted as a static function so the status-mapping logic has a
    /// unit-testable seam that does not require standing up a real
    /// `Process` (whose `terminationStatus` cannot be mocked).
    ///
    /// Contract (CX-454): success requires BOTH signals to agree --
    /// a `DONE status=ok` marker AND a zero exit code. Any disagreement
    /// (ok marker + non-zero exit, or exit 0 + no marker) is a loud
    /// failure, never a silent success. The legacy `set -u`-dies-with-
    /// no-marker path (CX-126) is the `donedMarker == nil` arm here.
    static func reconcileTermination(
        donedMarker finished: StepStatus?,
        cancelled: Bool,
        exitCode: Int32
    ) -> TerminationOutcome {
        if cancelled {
            return .cancelled
        }
        switch finished {
        case .none:
            // No DONE marker ever arrived -- the script died mid-flight.
            // Failure regardless of the reported exit code (a `set -u`
            // abort can surface as exit 0 through pipeline / wrapper
            // masking). CX-126.
            if exitCode == 0 {
                return .failure(message: "The installer stopped before it finished. Some steps did not run. Use Copy log and Try again, or contact support@ostler.ai.")
            }
            return .failure(message: "The installer stopped before it finished (exit \(exitCode)). Some steps did not run. Use Copy log and Try again, or contact support@ostler.ai.")
        case .fail, .error:
            // install.sh already told us it failed. Honour it.
            return .confirmedFailure
        case .timeout, .warn:
            // A terminal `warn` finish is treated as a (non-fatal)
            // completion; require a clean exit to call it success.
            if exitCode == 0 {
                return .confirmedSuccess
            }
            return .failure(message: "The installer reported it finished but the process exited with an error (exit \(exitCode)). Some steps may not have completed. Use Copy log and Try again, or contact support@ostler.ai.")
        case .ok:
            // CX-454: a success marker is only trustworthy if the OS
            // exit code agrees. A `DONE status=ok` followed by a
            // non-zero exit (a post-marker tail command, or the bash
            // wrapper, dying) previously rendered the green "all set"
            // screen over a broken install. Fail loud on disagreement.
            if exitCode == 0 {
                return .confirmedSuccess
            }
            return .failure(message: "The installer reported it finished but the process exited with an error (exit \(exitCode)). Some steps may not have completed. Use Copy log and Try again, or contact support@ostler.ai.")
        }
    }

    private func handleTermination() {
        let exitCode = process?.terminationStatus ?? -1
        let outcome = Self.reconcileTermination(
            donedMarker: finished,
            cancelled: cancelled,
            exitCode: exitCode
        )
        switch outcome {
        case .confirmedSuccess:
            // The marker and the exit code agree. Arm the auto-quit: this is
            // the only place in the app where success is CONFIRMED, so it is
            // the only honest place to start the clock.
            armAutoQuit()
        case .confirmedFailure, .cancelled:
            // The marker and exit code agree (or the user cancelled);
            // the terminal state set during marker handling stands. NOT
            // auto-quit: a failed install is exactly when the customer needs
            // the log drawer and the Copy log button.
            break
        case .failure(let message):
            // The two completion signals disagree, or no DONE marker
            // arrived. Override any optimistic `.ok` and surface a loud
            // failure -- never a silent success. Covers CX-126 (no
            // marker, e.g. a `set -u` abort) AND CX-454 (ok marker
            // contradicted by a non-zero exit code).
            let wasFalseSuccess = (finished == .ok)
            finished = .fail
            if error == nil {
                error = message
            }
            if wasFalseSuccess {
                OstlerLog.lifecycle.error("handleTermination: DONE status=ok contradicted by non-zero exit \(exitCode, privacy: .public) -- overriding to failure (CX-454)")
            } else {
                OstlerLog.lifecycle.error("handleTermination: subprocess ended with NO DONE marker (exit \(exitCode, privacy: .public)) -- treating as failure (CX-126)")
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

        // Emit whatever the producer never terminated, BEFORE releasing the
        // accumulator. A stalled or killed subprocess has by definition not
        // written its terminator, so its last words are held here and nowhere
        // else, and reset() alone deleted them unread. Silent on a normal
        // install: flush() returns nil when nothing is retained.
        if let tail = stdoutBuffer.flush(), !tail.isEmpty {
            appendLog(
                level: "warn",
                msg: "Subprocess ended mid-line. Last unterminated output: \(tail)"
            )
        }

        // Release the line accumulator. Pre-fix it was never cleared at all,
        // so whatever it had swallowed stayed resident for as long as the app
        // was open -- which is why the 4.27 GB was still there AFTER a
        // successful install rather than only during one.
        stdoutBuffer.reset()

        // Release the caffeinate power assertion. Idempotent; safe to
        // call even when start() failed earlier. Single sink so a
        // success / failure / cancel / quit path all release the
        // assertion identically.
        CaffeinateManager.shared.stop()
    }

    // ── Post-success auto-quit ───────────────────────────────────

    /// m:ss for the countdown label. Pure + static so the format is asserted
    /// directly rather than through a rendered view.
    static func mmss(_ seconds: Int) -> String {
        let s = max(0, seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// Start the visible countdown to termination. Idempotent: a second
    /// DONE marker (or a re-entrant terminationHandler) must not stack two
    /// timers and halve the customer's window.
    func armAutoQuit() {
        guard autoQuitTask == nil else { return }
        autoQuitRemaining = Self.autoQuitSeconds
        appendLog(
            level: "info",
            msg: "Install complete. This installer will close automatically in "
                + "\(Self.autoQuitSeconds / 60) minutes so it does not keep holding memory."
        )
        OstlerLog.lifecycle.info("auto-quit armed seconds=\(Self.autoQuitSeconds, privacy: .public)")
        autoQuitTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                guard let left = self.autoQuitRemaining else { return }
                if left <= 1 {
                    self.autoQuitRemaining = 0
                    self.finishAndQuit()
                    return
                }
                self.autoQuitRemaining = left - 1
            }
        }
    }

    /// The single exit sink for a successful install: honours the
    /// offer-to-trash choice, then terminates. Used by the Done button AND
    /// by the auto-quit, so the two can never disagree about what happens
    /// to the installer bundle.
    func finishAndQuit() {
        autoQuitTask?.cancel()
        autoQuitTask = nil
        if trashInstallerOnQuit {
            // Best-effort: a failure here (path missing, permissions, running
            // from a read-only DMG) must not stop the quit.
            let bundleURL = Bundle.main.bundleURL
            if bundleURL.path.hasPrefix("/Applications/") {
                var trashedURL: NSURL?
                try? FileManager.default.trashItem(at: bundleURL, resultingItemURL: &trashedURL)
                didTrashInstaller = true
                OstlerLog.lifecycle.info("installer bundle moved to Trash at customer request")
            }
        } else {
            OstlerLog.lifecycle.info("installer bundle KEPT (offer-to-trash default)")
        }
        quitAction()
    }

    /// Stop the countdown without quitting. Only used to tear a coordinator
    /// down cleanly; there is no customer-facing cancel, by decision.
    func cancelAutoQuit() {
        autoQuitTask?.cancel()
        autoQuitTask = nil
        autoQuitRemaining = nil
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

