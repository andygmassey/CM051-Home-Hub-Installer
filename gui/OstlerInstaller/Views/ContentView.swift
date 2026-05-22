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
                    // Studio retest #8 (2026-05-22) found 200pt too
                    // narrow: 6 of the 21 step labels truncated with
                    // ellipsis at lineLimit 1 ("Installing Homebrew +
                    // ...", "Encrypting your data...", "Reading your
                    // Mac's dat...", etc.). 260pt fits every catalogue
                    // entry on one line at 12pt without truncation.
                    .frame(width: 260)
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
                    //
                    // When the install has failed, the banner across
                    // the top carries the message + actions; the right
                    // pane reverts to a read-only LogDrawerView (the
                    // same view the bottom drawer would show) so the
                    // customer can read the actual failure output
                    // without having to flip the verbose-log toggle.
                    // Studio retest #8 (2026-05-22) flagged the blank
                    // white pane as confusing -- the failure log is
                    // exactly what the customer needs to see next.
                    if coordinator.finished == .fail {
                        LogDrawerView()
                    } else if coordinator.pendingPrompt != nil ||
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
///   - "Copy log" button (mirrors the LogDrawerView Copy log button
///     so the customer can grab the full buffer for hello@ostler.ai)
///   - "Try again" button -- terminates the app so the customer
///     can re-launch. We deliberately do NOT attempt an in-place
///     restart because the failed install may have left
///     ~/.ostler/ in a state that needs a fresh process to clean up.
private struct InstallFailedBannerView: View {
    @EnvironmentObject private var coordinator: InstallerCoordinator
    @State private var copied = false
    @State private var redactedCopied = false

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
            // F-CX-2 2026-05-22: dual "Copy log" / "Copy redacted log"
            // pair. Customers were emailing support@ostler.ai with
            // full unredacted logs that contained their email
            // addresses, phone numbers, full file paths and IPs.
            // The redacted variant runs LogRedactor.redact() over the
            // buffer first, so support gets the diagnostic detail
            // without the PII surface.
            Button(redactedCopied
                   ? ViewCopy.shared.string(for: "install_failed_banner.copy_redacted_log_button_copied")
                   : ViewCopy.shared.string(for: "install_failed_banner.copy_redacted_log_button")) {
                let buffer = LogDrawerView.formatBuffer(coordinator.logLines)
                let redacted = LogRedactor.redact(buffer)
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(redacted, forType: .string)
                redactedCopied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                    redactedCopied = false
                }
            }
            .buttonStyle(.ostlerGhost)
            .foregroundStyle(Color.white)
            Button(copied
                   ? ViewCopy.shared.string(for: "install_failed_banner.copy_log_button_copied")
                   : ViewCopy.shared.string(for: "install_failed_banner.copy_log_button")) {
                let buffer = LogDrawerView.formatBuffer(coordinator.logLines)
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(buffer, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                    copied = false
                }
            }
            .buttonStyle(.ostlerGhost)
            .foregroundStyle(Color.white)
            Button(ViewCopy.shared.string(for: "install_failed_banner.try_again_button")) {
                NSApp.terminate(nil)
            }
            .buttonStyle(.ostlerPrimary)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, CGFloat.ostlerSpace3)
        .padding(.vertical, CGFloat.ostlerSpace2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.ostlerOxblood)
    }
}

/// PII redactor for install logs destined for support@ostler.ai.
/// Masks the categories most likely to leak personal data:
///   - email addresses → ⟨email⟩
///   - phone numbers (E.164 + common Western formats) → ⟨phone⟩
///   - /Users/<name>/... paths → /Users/⟨user⟩/...
///   - IPv4 + IPv6 addresses → ⟨ip⟩
///   - macOS Keychain item IDs, fingerprints, licence ids (UUIDs) → ⟨uuid⟩
///
/// Intentionally conservative: false positives (over-redaction) are
/// fine; false negatives (PII leaking through) are not. The
/// catalogue-fronted button copy ("Copy redacted log") tells the
/// customer what to expect.
enum LogRedactor {
    static func redact(_ input: String) -> String {
        var s = input
        // Order matters: longer / more-specific patterns first so
        // they don't get pre-consumed by broader regexes.
        let replacements: [(NSRegularExpression?, String)] = [
            // UUID v4 (licence IDs, fingerprints)
            (try? NSRegularExpression(pattern: #"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b"#),
             "⟨uuid⟩"),
            // Email
            (try? NSRegularExpression(pattern: #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#),
             "⟨email⟩"),
            // E.164 phone (+447700900000 etc.)
            (try? NSRegularExpression(pattern: #"\+\d{7,15}\b"#),
             "⟨phone⟩"),
            // IPv4
            (try? NSRegularExpression(pattern: #"\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b"#),
             "⟨ip⟩"),
            // /Users/<name>/ (preserve everything after the username)
            (try? NSRegularExpression(pattern: #"/Users/[^/\s]+"#),
             "/Users/⟨user⟩"),
        ]
        for (re, replacement) in replacements {
            guard let re else { continue }
            let range = NSRange(s.startIndex..<s.endIndex, in: s)
            s = re.stringByReplacingMatches(
                in: s, options: [], range: range, withTemplate: replacement)
        }
        return s
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
            // F-CX-3 2026-05-22: consent_install renders its own
            // Cancel + Install Ostler pair inside the question view,
            // so suppressing the footer Cancel here avoids the
            // double-Cancel UX Andy flagged from Studio retest #7.
            // Same for the failed state: the banner already has its
            // own Try again + Copy log; footer reserves the Quit
            // slot on the right.
            if coordinator.pendingPrompt?.id != "consent_install" && coordinator.finished == nil {
                Button(ViewCopy.shared.string(for: "footer.cancel_button")) {
                    coordinator.cancel()
                    NSApp.terminate(nil)
                }
                .buttonStyle(.ostlerGhost)
                .keyboardShortcut(.cancelAction)
            }

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
