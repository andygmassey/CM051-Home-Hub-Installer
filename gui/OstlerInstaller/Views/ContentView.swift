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
            // CX-126: a deliberate user-cancel / consent-decline takes
            // over the whole window with a calm neutral terminal. Checked
            // first so it overrides every other gate once install.sh has
            // emitted DONE status=cancelled.
            if coordinator.cancelled {
                InstallCancelledView()
            // CX-87 (2026-06-01): Full Disk Access gate sits ahead of
            // everything except the cancelled terminal. On first launch
            // with no FDA, this is the only screen shown until the
            // customer grants it and reopens -- so the quit-and-reopen
            // happens before any questions, not mid-install.
            } else if coordinator.needsFullDiskAccessUpfront {
                FullDiskAccessGateView()
            // CX-17 (2026-05-23): the permissions intro screen lands
            // BEFORE everything else (licence, admin gate, install).
            // The macOS TCC dialogs must fire while the customer is
            // attentive at first launch -- not after they have
            // walked away to read their welcome email. Once the
            // intro flow is `.complete` or `.skipped` we fall
            // through to the existing licence + admin gates.
            } else if !coordinator.permissionsPrewarmFinished {
                PermissionsIntroView()
            } else if coordinator.licenseVerified {
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
        .onChange(of: coordinator.permissionsPrewarmFinished) { _, finished in
            // CX-17: when the customer leaves the intro screen
            // (Grant + all-granted, Grant + summary acknowledge, or
            // Skip), kick the licence re-verify path that App.swift
            // used to fire from onAppear. Returning customers with
            // a persisted licence drop straight into the install
            // gates; first-timers land on LicenseEntryView.
            if finished {
                coordinator.verifyExistingLicenseOnLaunch()
            }
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
        case .offlineGraceExhausted(let attempts):
            // v1.0.10 security lockdown: the bounded offline fail-open
            // grace is used up. Refuse to proceed until this Mac can
            // reach our server and complete a real device registration.
            DeviceRegistrationErrorView(
                reason: "This licence has been installed offline \(attempts) time(s) on this Mac without ever confirming your device with our server. To protect your licence allowance, please connect this Mac to the internet and re-run the installer so we can verify your device."
            )
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
                    // When the install has failed, CX-14 Section E2
                    // (2026-05-23) replaces the previous read-only
                    // LogDrawerView with InstallFailedBodyView: the
                    // rich apology + next-step copy + hyperlinked
                    // support@ostler.ai + Email-support + Copy-log
                    // actions. Pre-CX-14 the right pane was just the
                    // log scrollback with no contextual copy; Studio
                    // retest #6 found customers reading the log and
                    // not understanding what to do next. The new pane
                    // embeds the LogDrawerView inside the body so the
                    // log is still visible but framed by the next-
                    // step copy.
                    if coordinator.finished == .fail {
                        InstallFailedBodyView()
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

/// F5 + CX-14 Section E2 (2026-05-23): top-of-window failure banner.
///
/// PRE-CX-14 the banner crammed the heading + a one-line cause +
/// four buttons (Email support / Copy redacted / Copy log / Try
/// again) into a single horizontal strip. Studio retest #6 found:
///   - the four buttons wrapped on the 880pt window, so the actions
///     looked accidental rather than offered
///   - the subtitle read as a single throwaway sentence in the
///     space the customer mostly scans for what-happened context
///   - the customer did not connect the buttons to the failure copy
///     and walked away thinking the installer had hung
///
/// CX-14 split: top banner is now MINIMAL (title only, no buttons,
/// no exit-code duplicate). The rich apology + next-step copy +
/// action buttons live in `InstallFailedBodyView` in the right
/// pane, where the customer is already looking when the install
/// fails. The hyperlinked support@ostler.ai inline in the body
/// removes the need for a separate "Email support" label.
///
/// We deliberately DROP "Try again": terminating the app and
/// asking the customer to re-launch is more reliable than an
/// in-place restart, and the Quit option in the footer already
/// does the same thing. The Email-support button stays as the
/// primary CTA in the body pane (introduced PR #150).
private struct InstallFailedBannerView: View {
    @EnvironmentObject private var coordinator: InstallerCoordinator

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: CGFloat.ostlerSpace3) {
            Image(systemName: "exclamationmark.octagon.fill")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(Color.white)
            // CX-17 (2026-05-23): when install.sh's fail_with_code
            // emitted a stable error code on the DONE marker, fold
            // the code INTO the banner heading ("Install failed:
            // ERR-17-DOCTOR-MISSING") rather than rendering it as
            // a separate row. The code is the FIRST thing support
            // sees when triaging a customer report -- right next to
            // the failure marker, not buried in the log.
            Text(bannerHeading())
                .font(.ostlerH2)
                .foregroundStyle(Color.white)
            Spacer(minLength: CGFloat.ostlerSpace3)
        }
        .padding(.horizontal, CGFloat.ostlerSpace3)
        .padding(.vertical, CGFloat.ostlerSpace2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.ostlerOxblood)
    }

    /// Builds the visible banner heading. With a code, renders the
    /// `install_failed_banner.error_code_heading_with_code` template
    /// after substituting `{code}`. Without a code (success path or
    /// a regression-test seam that fired finished=.fail without
    /// going through the DONE marker), falls back to the plain
    /// heading so the banner still renders gracefully.
    private func bannerHeading() -> String {
        if let code = coordinator.lastErrorCode, !code.isEmpty {
            return ViewCopy.shared.string(
                for: "install_failed_banner.error_code_heading_with_code",
                fills: ["code": code]
            )
        }
        return ViewCopy.shared.string(for: "install_failed_banner.heading")
    }
}

/// CX-14 Section E2 (2026-05-23): rich body pane shown in the
/// right content area when `coordinator.finished == .fail`. Pairs
/// with the minimal top `InstallFailedBannerView` to split the
/// "what happened" copy from the always-visible failure marker.
///
/// LAYOUT (top to bottom):
///   - body_heading ("The installer hit a fatal error and stopped")
///     -- translates the previous "code 1" exit-code shorthand into
///     a single human sentence
///   - body paragraph with hyperlinked `support@ostler.ai` inline
///     via AttributedString (.link attribute + Oxblood foreground +
///     underline, matching the consent-install body link styling)
///   - LogDrawerView (read-only buffer view) so the customer can
///     see the actual failure output without flipping the verbose-
///     log toggle
///   - actions row: Email support (primary CTA, same mailto pipeline
///     as before) + Copy redacted log + Copy log
///
/// The "Try again" button is deliberately dropped per E2 brief:
/// the footer Quit option already terminates the app, and asking
/// the customer to re-launch by hand is more reliable than an
/// in-place restart that might land on partial install state.
private struct InstallFailedBodyView: View {
    @EnvironmentObject private var coordinator: InstallerCoordinator
    @State private var copied = false
    @State private var redactedCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: CGFloat.ostlerSpace3) {
            Text(ViewCopy.shared.string(for: "install_failed_banner.body_heading"))
                .font(.ostlerH1)
                .foregroundStyle(Color.ostlerInk)
                .fixedSize(horizontal: false, vertical: true)

            // AttributedString with an inline .link run on the
            // support@ostler.ai label. SwiftUI renders .link as a
            // tappable run that opens via NSWorkspace by default;
            // we add an explicit Oxblood + underline to match the
            // consent-install terms-link styling in
            // OnboardingQuestionView.consentInstallBody().
            Text(supportBodyAttributed())
                .font(.ostlerBody)
                .foregroundStyle(Color.ostlerInk)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)

            // Read-only failure log so the customer can see the
            // actual subprocess output. Inherits the LogDrawer's
            // existing buffer formatting + colourisation.
            Rectangle()
                .fill(Color.ostlerHairlineFaint)
                .frame(height: 1)

            LogDrawerView()
                .frame(maxWidth: .infinity, maxHeight: 220)

            // Actions row. Email support stays as primary CTA; the
            // two copy-log variants stay for customers who prefer
            // paste-into-Slack / paste-into-an-issue-tracker. Try
            // again is dropped per E2.
            HStack(spacing: CGFloat.ostlerSpace3) {
                Button(ViewCopy.shared.string(for: "install_failed_banner.email_support_button")) {
                    openSupportMailto()
                }
                .buttonStyle(.ostlerPrimary)
                .keyboardShortcut(.defaultAction)

                Button(redactedCopied
                       ? ViewCopy.shared.string(for: "install_failed_banner.copy_redacted_log_button_copied")
                       : ViewCopy.shared.string(for: "install_failed_banner.copy_redacted_log_button")) {
                    copyRedacted()
                }
                .buttonStyle(.ostlerGhost)

                Button(copied
                       ? ViewCopy.shared.string(for: "install_failed_banner.copy_log_button_copied")
                       : ViewCopy.shared.string(for: "install_failed_banner.copy_log_button")) {
                    copyRaw()
                }
                .buttonStyle(.ostlerGhost)

                Spacer()
            }
        }
        .padding(.horizontal, CGFloat.ostlerSpace4)
        .padding(.vertical, CGFloat.ostlerSpace4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Builds the body paragraph as an AttributedString with the
    /// support@ostler.ai label rendered as an inline .link run.
    /// Mirrors `OnboardingQuestionView.consentInstallBody()`'s
    /// pattern so the visual styling is consistent across the app.
    private func supportBodyAttributed() -> AttributedString {
        let prefix = ViewCopy.shared.string(for: "install_failed_banner.body_paragraph_prefix")
        let label = ViewCopy.shared.string(for: "install_failed_banner.body_support_email_label")
        let urlString = ViewCopy.shared.string(for: "install_failed_banner.body_support_email_url")
        let suffix = ViewCopy.shared.string(for: "install_failed_banner.body_paragraph_suffix")

        var s = AttributedString(prefix)
        var link = AttributedString(label)
        if let url = URL(string: urlString) {
            link.link = url
        }
        link.foregroundColor = .ostlerOxblood
        link.underlineStyle = .single
        s += link
        s += AttributedString(suffix)
        return s
    }

    /// CX-15 (2026-05-23): the previous implementation crammed the
    /// full PII-redacted log into the mailto: body. macOS Mail.app
    /// silently truncates mailto: URLs at ~2KB and the body would
    /// drop mid-sentence around ~580 chars. Customers landed in
    /// a half-written email and could not actually send the log.
    ///
    /// Fix: copy the redacted log to the clipboard FIRST, then open
    /// a SHORT mailto: with just the heading + paste-prompt. The
    /// customer pastes one Cmd-V and is done.
    ///
    /// Strings live in ViewCopy.json under install_failed_banner.*
    /// per Rule 0.9. Body assembly is delegated to the static helper
    /// `SupportMailtoBuilder.makeMailtoURL(...)` so the regression
    /// test (EmailSupportMailtoTest) can byte-walk the assembled URL
    /// without spinning up a real coordinator.
    private func openSupportMailto() {
        // CX-17 (2026-05-23): prepend the Reference: ERR-NN-* line
        // to the buffer so it is the FIRST thing support sees in
        // the pasted log. The subject also gets the [ERR-NN-*]
        // suffix via SupportMailtoBuilder so triage can sort the
        // inbox by code without opening every email.
        let code = coordinator.lastErrorCode
        let buffer = LogDrawerView.formatBuffer(coordinator.logLines, errorCode: code)
        let redacted = LogRedactor.redact(buffer)

        // 1. Copy the redacted log to the system pasteboard FIRST so
        //    even if the URL.open call later races / fails, the
        //    customer already has the log on their clipboard.
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(redacted, forType: .string)

        // 2. Build the short mailto: URL (no log content in the body).
        if let url = SupportMailtoBuilder.makeMailtoURL(errorCode: code) {
            NSWorkspace.shared.open(url)
        }

        // 3. Light visual confirmation by re-using the existing
        //    redactedCopied state-flash pattern from copyRedacted().
        //    The Email-support button label does not bind to this
        //    flag, but the Copy-redacted button does, so the customer
        //    sees the "Redacted copied" pill flip briefly -- explicit
        //    confirmation that the clipboard now carries the log.
        redactedCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            redactedCopied = false
        }
    }

    private func copyRedacted() {
        let buffer = LogDrawerView.formatBuffer(
            coordinator.logLines,
            errorCode: coordinator.lastErrorCode
        )
        let redacted = LogRedactor.redact(buffer)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(redacted, forType: .string)
        redactedCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            redactedCopied = false
        }
    }

    private func copyRaw() {
        let buffer = LogDrawerView.formatBuffer(
            coordinator.logLines,
            errorCode: coordinator.lastErrorCode
        )
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(buffer, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            copied = false
        }
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
        // Phase 2 UX sweep 2026-05-22: added IPv6, API-key prefix
        // patterns (sk-*, gho_*, ghp_*, github_pat_*), and a
        // conservative names regex (capitalised pair) per Andy's
        // F-1b expansion. Re-uses the prefix shapes from
        // bin/operator-pii-scan.sh.
        let replacements: [(NSRegularExpression?, String)] = [
            // UUID v4 (licence IDs, fingerprints)
            (try? NSRegularExpression(pattern: #"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b"#),
             "⟨uuid⟩"),
            // API-key shapes (must run BEFORE the email regex because
            // ghp_/gho_ tokens can superficially resemble local parts)
            (try? NSRegularExpression(pattern: #"\bsk-ant-[A-Za-z0-9_-]{20,}\b"#),
             "⟨api-key⟩"),
            (try? NSRegularExpression(pattern: #"\bsk-[A-Za-z0-9]{20,}\b"#),
             "⟨api-key⟩"),
            (try? NSRegularExpression(pattern: #"\bghp_[A-Za-z0-9]{30,}\b"#),
             "⟨api-key⟩"),
            (try? NSRegularExpression(pattern: #"\bgho_[A-Za-z0-9]{30,}\b"#),
             "⟨api-key⟩"),
            (try? NSRegularExpression(pattern: #"\bgithub_pat_[A-Za-z0-9_]{30,}\b"#),
             "⟨api-key⟩"),
            // Email
            (try? NSRegularExpression(pattern: #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#),
             "⟨email⟩"),
            // E.164 phone (+447700900000 etc.)
            (try? NSRegularExpression(pattern: #"\+\d{7,15}\b"#),
             "⟨phone⟩"),
            // IPv6 (run before IPv4 so the longer pattern wins).
            // Permits compressed `::` forms by allowing empty hex
            // groups: e.g. `2001:db8::1` parses as
            //   2001 + :db8 + : (empty) + :1
            // Anchored on at least one leading hex group + 2-7
            // following `:hex?` groups so single-colon shapes (MAC
            // addresses, time stamps) do not match.
            (try? NSRegularExpression(pattern: #"\b[0-9a-fA-F]{1,4}(?::[0-9a-fA-F]{0,4}){2,7}\b"#),
             "⟨ip⟩"),
            // IPv4
            (try? NSRegularExpression(pattern: #"\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b"#),
             "⟨ip⟩"),
            // /Users/<name>/ (preserve everything after the username)
            (try? NSRegularExpression(pattern: #"/Users/[^/\s]+"#),
             "/Users/⟨user⟩"),
            // Conservative name shape: two capitalised words in a row
            // (e.g. "Andy Massey", "Mary Jane Watson"). Lower-cased
            // common log noise like "Apple Mail" / "Apple Silicon" /
            // "Touch ID" would also match -- accepted as overreach
            // because false positives (extra ⟨name⟩) are preferable
            // to false negatives (PII reaching support).
            (try? NSRegularExpression(pattern: #"\b[A-Z][a-z]{1,15} [A-Z][a-z]{1,20}\b"#),
             "⟨name⟩"),
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

/// CX-15 (2026-05-23): assembles the SHORT mailto: URL for the
/// install-failed Email-support button. The previous implementation
/// stuffed the full PII-redacted log into the URL body; macOS Mail
/// silently truncates mailto: at ~2KB and the body dropped mid-
/// sentence around ~580 chars. Now the log lives on the clipboard
/// (see `InstallFailedBodyView.openSupportMailto()`); the body is
/// just heading + paste-prompt + separator.
///
/// Pulled out as a static helper for two reasons:
///   1. The regression test `EmailSupportMailtoTest` can call this
///      without spinning up an `InstallerCoordinator` or live view.
///   2. The byte-by-byte URL-length cap (~1024 chars, well under
///      macOS's 2KB ceiling) is enforced in ONE place that the test
///      points at. Future regression "let me inline a small log
///      preview" would have to mutate this builder, and the cap
///      test would fail.
///
/// All customer-facing strings come from ViewCopy.json under
/// install_failed_banner.email_body_* per Rule 0.9.
enum SupportMailtoBuilder {

    /// Defensive cap on the assembled mailto: URL length. macOS Mail
    /// truncates at ~2KB; we sit well under that so any future copy
    /// edit has headroom. The regression test asserts this cap.
    static let urlLengthCap: Int = 1024

    /// The mailto: recipient. Kept in sync with
    /// install_failed_banner.body_support_email_url in ViewCopy.json
    /// (the hyperlink rendered in the body paragraph).
    static let recipient: String = "support@ostler.ai"

    /// Assembles the body text from the three ViewCopy catalogue keys.
    /// Layout (top to bottom):
    ///   <intro>\n\n
    ///   <clipboard_instruction>\n\n
    ///   <separator>\n\n
    ///
    /// Returns the raw (unencoded) body so the test can assert on
    /// the keyed substrings before percent-encoding.
    static func makeBody() -> String {
        let intro = ViewCopy.shared.string(for: "install_failed_banner.email_body_intro")
        let instruction = ViewCopy.shared.string(for: "install_failed_banner.email_body_clipboard_instruction")
        let separator = ViewCopy.shared.string(for: "install_failed_banner.email_body_separator")
        return intro + "\n\n" + instruction + "\n\n" + separator + "\n\n"
    }

    /// Assembles the full mailto: URL string (post percent-encoding).
    /// Returns nil if percent-encoding fails (it won't in practice,
    /// but kept as an Option for parity with `URL(string:)`).
    static func makeMailtoURLString() -> String {
        return makeMailtoURLString(errorCode: nil)
    }

    /// CX-17 (2026-05-23) overload: when an error code is supplied,
    /// the subject gets a `[ERR-NN-*]` suffix so support triage can
    /// sort the inbox by code without opening every email. Subject
    /// suffix template lives at `install_failed_banner.error_code_subject_suffix`
    /// per Rule 0.9.
    static func makeMailtoURLString(errorCode: String?) -> String {
        var subject = ViewCopy.shared.string(for: "install_failed_banner.email_subject")
        if let code = errorCode, !code.isEmpty {
            let suffixTemplate = ViewCopy.shared.string(
                for: "install_failed_banner.error_code_subject_suffix",
                fills: ["code": code]
            )
            subject += suffixTemplate
        }
        let body = makeBody()
        let allowed = CharacterSet.urlQueryAllowed
        let encSubject = subject.addingPercentEncoding(withAllowedCharacters: allowed) ?? subject
        let encBody = body.addingPercentEncoding(withAllowedCharacters: allowed) ?? body
        return "mailto:\(recipient)?subject=\(encSubject)&body=\(encBody)"
    }

    /// Convenience: parse the string into a URL.
    static func makeMailtoURL() -> URL? {
        URL(string: makeMailtoURLString())
    }

    /// CX-17 overload that threads the error code through.
    static func makeMailtoURL(errorCode: String?) -> URL? {
        URL(string: makeMailtoURLString(errorCode: errorCode))
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

/// CX-126: shown when the customer deliberately cancelled / declined a
/// consent gate and install.sh exited cleanly having written nothing.
/// This is NOT a failure, so it uses calm ink colours (no oxblood/red,
/// no "contact support") -- just a neutral acknowledgement + a way out.
private struct InstallCancelledView: View {
    var body: some View {
        VStack(spacing: 24) {
            HStack(spacing: 12) {
                Image(systemName: "xmark.circle")
                    .font(.system(size: 28, weight: .regular))
                    .foregroundColor(.ostlerInkMuted)
                Text(ViewCopy.shared.string(for: "install_cancelled.heading"))
                    .font(.ostlerH1)
                    .foregroundColor(.ostlerInk)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(ViewCopy.shared.string(for: "install_cancelled.body"))
                .font(.ostlerBody)
                .foregroundColor(.ostlerInk)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                Spacer()
                Button(ViewCopy.shared.string(for: "install_cancelled.quit_button")) {
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
                Button(ViewCopy.shared.string(for: "footer.done_button")) {
                    // CX-52 (DMG #30, 2026-05-24): on successful install,
                    // move OstlerInstaller.app to ~/.Trash on the way out.
                    // The installer has served its purpose; leaving it
                    // in /Applications as a stale 33MB DMG-extracted
                    // bundle is clutter the customer didn't ask for.
                    // Best-effort: any failure (path missing, perms) is
                    // swallowed so the terminate still happens.
                    let bundleURL = Bundle.main.bundleURL
                    if bundleURL.path.hasPrefix("/Applications/") {
                        var trashedURL: NSURL?
                        try? FileManager.default.trashItem(
                            at: bundleURL, resultingItemURL: &trashedURL)
                    }
                    NSApp.terminate(nil)
                }
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
