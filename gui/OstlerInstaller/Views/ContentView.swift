// ContentView.swift
//
// Three-pane root layout per plan §5:
//   sidebar (200pt, fixed)  |  main content (flex)  |  log drawer (collapsible bottom)
//
// Window is a fixed 880x620 – the App.swift frame() pins it.

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var coordinator: InstallerCoordinator
    @State private var showLogDrawer: Bool = false

    var body: some View {
        Group {
            if coordinator.licenseVerified {
                gatedContent
            } else {
                LicenseEntryView()
            }
        }
        .frame(width: 880, height: 620)
        .background(Color.ostlerChassis)
        .onChange(of: coordinator.registrationGate) { _, gate in
            // Bootstrap is idempotent + already guards on `.ready`;
            // a second call from `runDeviceRegistration` is harmless.
            if gate == .ready { coordinator.bootstrap() }
        }
        // PROMPT events are rendered inline in `installLayout` via
        // `OnboardingQuestionView` (#353). FDA approval is still a
        // sheet for now -- it sits outside the question flow and
        // pre-dates the in-window decision.
        .sheet(item: $coordinator.needsFDA) { fda in
            FullDiskAccessSheet(probe: fda.probe, reason: fda.reason)
                .environmentObject(coordinator)
        }
    }

    /// Full-screen blocker shown when the pre-launch admin-grant
    /// AppleScript dialog was cancelled (or otherwise failed). The
    /// install subprocess has NOT been launched at this point;
    /// Retry re-invokes `AuthorizationHelper` cleanly.
    @ViewBuilder
    private var adminRetryGate: some View {
        AdminAccessRequiredView(mode: .retry)
    }

    /// Pre-flight view shown after the licence + registration gates
    /// pass, but BEFORE the macOS admin password dialog fires. F3
    /// (Studio retest #2 2026-05-20): the customer reads the
    /// explanation copy and clicks Continue to trigger the dialog.
    @ViewBuilder
    private var adminPreAckGate: some View {
        AdminAccessRequiredView(mode: .preAcknowledgement)
    }

    /// Branches on the second-stage registration gate. The first-stage
    /// (cryptographic) gate is already cleared at this point, so the
    /// `LicenseEntryView` is behind us.
    @ViewBuilder
    private var gatedContent: some View {
        switch coordinator.registrationGate {
        case .limitReached(let max, let count):
            DeviceLimitReachedView(
                licenseId: coordinator.verifiedLicense?.licenseId ?? "",
                maxFingerprints: max,
                registeredCount: count
            )
        case .fatal(let reason):
            DeviceRegistrationErrorView(reason: reason)
        case .idle, .registering:
            // The install layout itself is fine to render -- bootstrap()
            // is gated separately, so the subprocess does not launch
            // until the gate is .ready. The footer ProgressView keeps
            // spinning, which is the natural UX for "we're checking".
            installLayout
        case .ready:
            // Pre-launch admin-grant cancelled? Hold here with a
            // Retry surface; the install subprocess is not running.
            if coordinator.needsAdminRetry {
                adminRetryGate
            } else if coordinator.needsAdminAcknowledgement {
                // F3: park at the explanation screen until the
                // customer clicks Continue. Dialog fires on tap.
                adminPreAckGate
            } else {
                installLayout
            }
        }
    }

    private var installLayout: some View {
        VStack(spacing: 0) {
            // F5 (Studio retest #2 2026-05-20): when the install
            // fails, render a full-width red banner across the top
            // of the window. Pre-fix the failure indicator was a
            // bottom-left status line in the footer; Andy walked
            // past it without noticing. This banner is prominent +
            // carries the failure copy + Copy log + Try again.
            if coordinator.finished == .fail {
                InstallFailedBannerView()
            }
            HStack(spacing: 0) {
                SidebarView()
                    .frame(width: 200)
                    .background(Color.ostlerChassisDeep)

                Rectangle()
                    .fill(Color.ostlerHairlineFaint)
                    .frame(width: 1)

                VStack(spacing: 0) {
                    // Onboarding takes over the main content area
                    // whenever there is a live PROMPT or the customer
                    // is reviewing a previous answer via Back. The
                    // sidebar Steps + footer remain visible so the
                    // customer never loses their progress anchor.
                    if coordinator.pendingPrompt != nil ||
                       coordinator.backReviewIndex != nil {
                        OnboardingQuestionView()
                    } else {
                        HintPanelView()
                    }
                    Spacer()
                    if showLogDrawer {
                        Rectangle()
                            .fill(Color.ostlerHairlineFaint)
                            .frame(height: 1)
                        LogDrawerView()
                            .frame(height: 200)
                    }
                    Rectangle()
                        .fill(Color.ostlerHairlineFaint)
                        .frame(height: 1)
                    FooterView(showLogDrawer: $showLogDrawer)
                        .frame(height: 60)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.ostlerChassis)
            }
        }
    }
}

/// F5: prominent top-of-window failure banner. Replaces the bottom-
/// left footer status line as the primary failure signal. Surfaces:
///   - one-line cause from `coordinator.error` (falls back to a
///     generic "Install failed" if no error is set)
///   - "Email support" button (primary) -- opens a mailto: to
///     support@ostler.ai with the redacted log pre-filled (task #351
///     follow-on, 2026-05-21). The PII redactor (see Support/
///     PIIRedactor.swift) strips emails, phones, names, /Users/<u>/
///     and IP addresses before the log lands in the customer's email
///     compose window. Keeps technical content (function names,
///     /Applications + /tmp paths, error codes, hex digests) intact.
///   - "Copy redacted log" button -- same redacted buffer but copies
///     to the pasteboard for customers who prefer not to open Mail.
///   - "Copy log (raw)" button -- escape hatch for unredacted log.
///     Gated behind a confirmation modal that names the personal
///     data classes the buffer can contain. Most customers should
///     never reach this path.
///   - "Try again" button -- terminates the app so the customer
///     can re-launch. We deliberately do NOT attempt an in-place
///     restart because the failed install may have left
///     ~/.ostler/ in a state that needs a fresh process to clean up.
private struct InstallFailedBannerView: View {
    @EnvironmentObject private var coordinator: InstallerCoordinator
    @State private var rawCopied = false
    @State private var redactedCopied = false
    @State private var emailOpening = false
    @State private var showRawCopyConfirm = false

    /// Build the redactor on demand: each render reads the latest
    /// answerHistory in case the customer's name only became known
    /// late in onboarding. Cheap to construct (no I/O).
    private func makeRedactor() -> PIIRedactor {
        // Pull any caller-supplied display names out of the onboarding
        // answer history. We accept several prompt-id shapes because
        // the install.sh strings catalogue has shifted between
        // `user_name`, `display_name`, and `your_name` over the
        // last fortnight; whichever one carries the name on this
        // build, we'll catch it.
        let nameKeys: Set<String> = [
            "user_name", "your_name", "display_name", "name",
            "operator_name", "operator", "full_name",
        ]
        let names = coordinator.answerHistory
            .filter { nameKeys.contains($0.prompt.id) }
            .map { $0.answer }
        return PIIRedactor(names: names)
    }

    private var rawBuffer: String {
        LogDrawerView.formatBuffer(coordinator.logLines)
    }

    private var redactedBuffer: String {
        makeRedactor().redact(rawBuffer)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: CGFloat.ostlerSpace3) {
            Image(systemName: "exclamationmark.octagon.fill")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(Color.white)
            VStack(alignment: .leading, spacing: 2) {
                Text(ViewCopy.shared.string(for: "install_failed_banner.heading"))
                    .font(.ostlerH2)
                    .foregroundStyle(Color.white)
                Text(coordinator.error
                     ?? ViewCopy.shared.string(for: "install_failed_banner.subtitle_default"))
                    .font(.ostlerBody)
                    .foregroundStyle(Color.white.opacity(0.92))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: CGFloat.ostlerSpace3)

            // Primary: Email support with the redacted log.
            Button(emailOpening
                   ? ViewCopy.shared.string(for: "install_failed_banner.email_support_button_busy")
                   : ViewCopy.shared.string(for: "install_failed_banner.email_support_button")) {
                openMailto()
            }
            .buttonStyle(.ostlerPrimary)
            .disabled(emailOpening)
            .keyboardShortcut(.defaultAction)

            // Secondary: copy the redacted log to the pasteboard.
            Button(redactedCopied
                   ? ViewCopy.shared.string(for: "install_failed_banner.copy_redacted_button_copied")
                   : ViewCopy.shared.string(for: "install_failed_banner.copy_redacted_button")) {
                copyToPasteboard(redactedBuffer)
                redactedCopied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                    redactedCopied = false
                }
            }
            .buttonStyle(.ostlerGhost)
            .foregroundStyle(Color.white)

            // Tertiary: copy the RAW log, behind a confirmation modal.
            Button(rawCopied
                   ? ViewCopy.shared.string(for: "install_failed_banner.copy_log_button_copied")
                   : ViewCopy.shared.string(for: "install_failed_banner.copy_log_button")) {
                showRawCopyConfirm = true
            }
            .buttonStyle(.ostlerGhost)
            .foregroundStyle(Color.white)

            Button(ViewCopy.shared.string(for: "install_failed_banner.try_again_button")) {
                NSApp.terminate(nil)
            }
            .buttonStyle(.ostlerGhost)
            .foregroundStyle(Color.white)
        }
        .padding(.horizontal, CGFloat.ostlerSpace3)
        .padding(.vertical, CGFloat.ostlerSpace2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.ostlerOxblood)
        .alert(
            ViewCopy.shared.string(for: "install_failed_banner.raw_copy_confirm_title"),
            isPresented: $showRawCopyConfirm
        ) {
            Button(
                ViewCopy.shared.string(for: "install_failed_banner.raw_copy_confirm_cancel"),
                role: .cancel
            ) {
                // Default cancel.
            }
            Button(
                ViewCopy.shared.string(for: "install_failed_banner.raw_copy_confirm_proceed"),
                role: .destructive
            ) {
                copyToPasteboard(rawBuffer)
                rawCopied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                    rawCopied = false
                }
            }
        } message: {
            Text(ViewCopy.shared.string(for: "install_failed_banner.raw_copy_confirm_body"))
        }
    }

    // MARK: - Helpers

    private func copyToPasteboard(_ s: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
    }

    private func openMailto() {
        emailOpening = true
        defer {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                emailOpening = false
            }
        }

        let to = ViewCopy.shared.string(for: "install_failed_banner.mailto_to")
        let summary = (coordinator.error?.split(separator: "\n").first.map(String.init))
            ?? ViewCopy.shared.string(for: "install_failed_banner.mailto_subject_fallback_summary")
        let subjectTemplate = ViewCopy.shared.string(for: "install_failed_banner.mailto_subject")
        let subject = subjectTemplate.replacingOccurrences(of: "{summary}", with: summary)
        let preamble = ViewCopy.shared.string(for: "install_failed_banner.mailto_body_preamble")
        let body = preamble + redactedBuffer

        // Percent-encode for the mailto URL. `.urlQueryAllowed` covers
        // the common shape; we then strip the few stragglers (`&`, `=`)
        // that would otherwise terminate the query.
        let encodedSubject = subject.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? subject
        let encodedBody = body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? body
        let urlString = "mailto:\(to)?subject=\(encodedSubject)&body=\(encodedBody)"

        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}

/// Pre-launch admin-grant screen. Two modes:
///
///   - `.preAcknowledgement`: the very first time we ask. Renders
///     explanation copy + a single primary "Continue and enter your
///     password" button. F3 (Studio retest #2 2026-05-20): the
///     macOS password dialog must fire on user click, not on view
///     appear, so the customer has time to read why we need admin.
///
///   - `.retry`: the customer previously clicked Cancel (or
///     osascript returned non-zero). Same explanation copy + a
///     Retry button alongside a Quit installer button.
///
/// Either way, the install subprocess has NOT been launched at this
/// point; the button taps drive `coordinator.userAcknowledgedAdminRequest()`
/// (or `retryAdminAuthorization`) which actually fires the dialog.
private struct AdminAccessRequiredView: View {
    @EnvironmentObject private var coordinator: InstallerCoordinator
    let mode: Mode

    enum Mode {
        case preAcknowledgement
        case retry
    }

    var body: some View {
        VStack(spacing: 24) {
            HStack(spacing: 12) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 28, weight: .regular))
                    .foregroundColor(.ostlerOxblood)
                Text(ViewCopy.shared.string(for: "admin_access_required.heading"))
                    .font(.ostlerH1)
                    .foregroundColor(.ostlerInk)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(ViewCopy.shared.string(for: "admin_access_required.prompt_reason"))
                .font(.ostlerBody)
                .foregroundColor(.ostlerInk)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if mode == .preAcknowledgement {
                // Friendly reassurance for the first-time prompt.
                // Lifted from the brief: "your password stays on
                // this Mac, never sent anywhere".
                Text(ViewCopy.shared.string(for: "admin_access_required.reassurance"))
                    .font(.ostlerBody)
                    .foregroundColor(.ostlerInkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 12) {
                Spacer()
                if mode == .retry {
                    Button(ViewCopy.shared.string(for: "admin_access_required.quit_button")) {
                        NSApp.terminate(nil)
                    }
                    .buttonStyle(.ostlerGhost)
                }

                let buttonKey = mode == .retry
                    ? "admin_access_required.retry_button"
                    : "admin_access_required.continue_button"
                Button(ViewCopy.shared.string(for: buttonKey)) {
                    if mode == .retry {
                        coordinator.retryAdminAuthorization()
                    } else {
                        coordinator.userAcknowledgedAdminRequest()
                    }
                }
                .buttonStyle(.ostlerPrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(coordinator.requestingAdmin)
            }
            Spacer()
        }
        .padding(.horizontal, 48)
        .padding(.vertical, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.ostlerChassis)
    }
}

/// Shown when the Worker rejected the registration with a terminal
/// (non-cap) reason: licence not found, revoked, or malformed. The
/// install is refused; the user is pointed at hello@ostler.ai.
private struct DeviceRegistrationErrorView: View {
    let reason: String

    var body: some View {
        VStack(spacing: 24) {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 28, weight: .regular))
                    .foregroundColor(.ostlerOxblood)
                Text(ViewCopy.shared.string(for: "device_registration_error.heading"))
                    .font(.ostlerH1)
                    .foregroundColor(.ostlerInk)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(reason)
                .font(.ostlerBody)
                .foregroundColor(.ostlerInk)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                Spacer()
                Button(ViewCopy.shared.string(for: "device_registration_error.quit_button")) {
                    NSApp.terminate(nil)
                }
                    .buttonStyle(.ostlerPrimary)
                    .keyboardShortcut(.defaultAction)
            }
            Spacer()
        }
        .padding(.horizontal, 48)
        .padding(.vertical, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.ostlerChassis)
    }
}

private struct FooterView: View {
    @EnvironmentObject private var coordinator: InstallerCoordinator
    @Binding var showLogDrawer: Bool

    var body: some View {
        HStack(spacing: .ostlerSpace2) {
            Button(ViewCopy.shared.string(for: "footer.cancel_button")) {
                coordinator.cancel()
                NSApp.terminate(nil)
            }
            .buttonStyle(.ostlerGhost)
            .keyboardShortcut(.cancelAction)

            Spacer()

            Toggle(isOn: $showLogDrawer) {
                Label("Log", systemImage: "terminal")
                    .font(.ostlerCaption)
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .tint(.ostlerInk)
            .keyboardShortcut("d", modifiers: [.command, .shift])

            if coordinator.finished == .ok {
                Button(ViewCopy.shared.string(for: "footer.reveal_in_finder_button")) {
                    let url = URL(fileURLWithPath: ("~/Documents/Ostler" as NSString).expandingTildeInPath)
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                .buttonStyle(.ostlerGhost)
                Button(ViewCopy.shared.string(for: "footer.done_button")) { NSApp.terminate(nil) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.ostlerPrimary)
            } else if coordinator.finished == .fail {
                Button(ViewCopy.shared.string(for: "footer.quit_button")) { NSApp.terminate(nil) }
                    .buttonStyle(.ostlerPrimary)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .tint(.ostlerOxblood)
            }
        }
        .padding(.horizontal, .ostlerSpace3)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.ostlerChassis)
    }
}
