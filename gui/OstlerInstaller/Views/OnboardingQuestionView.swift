// OnboardingQuestionView.swift
//
// In-window renderer for #OSTLER PROMPT events. Replaces the
// `.sheet(item:)` PromptSheet path (deleted in #353) so the customer
// never sees an installer-popup over the main window during the
// 12 to 17 onboarding questions -- a single window-flow with a
// progress header instead.
//
// Reads either:
//   - `coordinator.pendingPrompt` (live, editable, Continue sends
//     the answer back over the FIFO), or
//   - `coordinator.answerHistory[coordinator.backReviewIndex]` (Back
//     review mode, read-only -- bash has already consumed the answer
//     so we cannot re-send).
//
// v7.1 Back semantics deliberately conservative; Route A (full
// edit-and-resend) is the next iteration. See the brief at
// HR015/launch/TNM_BRIEF_CM051_INLINE_QUESTIONS_2026-05-17.md.
//
// All customer-facing strings route via ViewCopy.shared.string(for:)
// per Rule 0.9 (locked 2026-05-19) -- v1.2 translation is a
// catalogue-file drop, not a code lift.

import SwiftUI
import AppKit

struct OnboardingQuestionView: View {
    @EnvironmentObject private var coordinator: InstallerCoordinator

    /// Live answer state (only used when not in review mode).
    @State private var textValue: String = ""
    @State private var secretValue: String = ""
    @State private var yesnoValue: Bool = true
    @State private var choiceValue: String = ""
    /// `folder` kind: holds the path the customer has picked (or
    /// the default `~/Downloads`). Empty string means "skip".
    @State private var folderValue: String = ""
    @State private var validationError: String? = nil
    @FocusState private var focused: Bool

    /// Tracks the prompt id we last seeded against so a new incoming
    /// PROMPT resets the input rather than carrying over the previous
    /// answer (a stale carry-over would be a confusing UX bug).
    @State private var lastSeededPromptId: String? = nil

    /// Either the prompt being reviewed (Back) or the live one.
    private var displayed: DisplayedQuestion? {
        if let idx = coordinator.backReviewIndex,
           idx < coordinator.answerHistory.count {
            let item = coordinator.answerHistory[idx]
            return DisplayedQuestion(
                prompt: item.prompt,
                index: item.index,
                priorAnswer: item.answer,
                isReview: true
            )
        }
        if let prompt = coordinator.pendingPrompt {
            return DisplayedQuestion(
                prompt: prompt,
                index: coordinator.currentQuestionIndex,
                priorAnswer: nil,
                isReview: false
            )
        }
        return nil
    }

    var body: some View {
        if let q = displayed {
            renderQuestion(q)
        } else {
            EmptyView()
        }
    }

    @ViewBuilder
    private func renderQuestion(_ q: DisplayedQuestion) -> some View {
        VStack(alignment: .leading, spacing: .ostlerSpace4) {
            header(q)

            Text(q.prompt.title)
                .font(.ostlerH1)
                .tracking(-0.4)
                .foregroundStyle(Color.ostlerInk)
                .fixedSize(horizontal: false, vertical: true)

            // Help / body copy. Order:
            //   - consent_install: special hyperlinked terms body
            //   - passkey_ack (Q12): modality-branched copy because
            //     MSG_PROMPT_PASSKEY_ACK_HELP hard-coded "Touch ID",
            //     which is wrong on every desktop Mac without a Magic
            //     Keyboard with Touch ID (Mac Studio / Mac Mini /
            //     Mac Pro / standard iMac). BiometricProbe.cachedResult
            //     drives a modality-appropriate ViewCopy string.
            //   - assistant_name (Q6): ViewCopy-owned brand-warm helper
            //     (the suggestion-pool intro). install.sh deliberately
            //     sends empty help for this prompt id so we don't render
            //     the same copy twice.
            //   - everything else: install.sh's `help` field.
            if q.prompt.id == "consent_install" {
                consentInstallBody()
            } else if q.prompt.id == "consent_third_party" {
                consentThirdPartyBody()
            } else if q.prompt.id == "passkey_ack" {
                passkeyAckBody()
            } else if q.prompt.id == "recovery_passphrase" {
                recoveryPassphraseBody()
            } else if q.prompt.id == "assistant_name" && !q.isReview {
                Text(ViewCopy.shared.string(for: "onboarding_question.assistant_name_helper"))
                    .font(.ostlerBody)
                    .foregroundStyle(Color.ostlerInkMuted)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let help = q.prompt.help, !help.isEmpty {
                // B2 (CX-14): customers couldn't click docs.ostler.ai/...
                // links in body copy because SwiftUI Text(String) does not
                // auto-linkify. Wrap the help text in an AttributedString
                // post-processor that detects bare `docs.ostler.ai/...`
                // and `https://...` substrings and turns them into
                // `.link` runs. Underscores in catalogue keys (e.g. the
                // `download_my_data` segment inside the EXPORTS_ACK help)
                // would have broken a Markdown-parsing alternative; the
                // regex is deliberately narrow to avoid false positives.
                Text(linkifiedHelp(help))
                    .font(.ostlerBodyLg)
                    .foregroundStyle(Color.ostlerInkMuted)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            inputField(q)

            if let err = validationError, !q.isReview {
                Text(err)
                    .font(.ostlerCaption)
                    .foregroundStyle(Color.ostlerOxblood)
            }

            Spacer()

            buttonRow(q)
        }
        .padding(.horizontal, .ostlerSpace4)
        .padding(.vertical, .ostlerSpace3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.ostlerChassis)
        .onAppear { seed(from: q) }
        .onChange(of: q.prompt.id) { _, _ in seed(from: q) }
        .onChange(of: q.isReview) { _, _ in seed(from: q) }
    }

    /// F6.8 consent_install body. CX-18 (Studio retest #13, 2026-05-23):
    /// previous shape literally repeated the headline ("Ready to
    /// install. By clicking...") and rendered `terms` as plain text
    /// with no emphasis on the type-INSTALL action. New shape reads:
    /// "Please type **INSTALL** to confirm you accept the [terms]."
    /// — with INSTALL rendered bold (to emphasise the typed-input
    /// action the customer must perform in the field below) and
    /// `terms` rendered as an underlined Oxblood link to
    /// ostler.ai/terms. The body no longer repeats the Q20 headline.
    ///
    /// Composed from five catalogue runs:
    ///   - consent_install_body_prefix          (plain)
    ///   - consent_install_body_install_token   (bold)
    ///   - consent_install_body_middle          (plain)
    ///   - consent_install_terms_link_label     (link, underlined)
    ///   - consent_install_body_suffix          (plain)
    private func consentInstallBody() -> some View {
        let prefix = ViewCopy.shared.string(for: "onboarding_question.consent_install_body_prefix")
        let installToken = ViewCopy.shared.string(for: "onboarding_question.consent_install_body_install_token")
        let middle = ViewCopy.shared.string(for: "onboarding_question.consent_install_body_middle")
        let linkLabel = ViewCopy.shared.string(for: "onboarding_question.consent_install_terms_link_label")
        let suffix = ViewCopy.shared.string(for: "onboarding_question.consent_install_body_suffix")
        let urlString = ViewCopy.shared.string(for: "onboarding_question.consent_install_terms_url")

        // AttributedString lets us embed inline emphasis + a tappable
        // link. SwiftUI renders .link attributes as default-styled
        // clickable runs; we add an explicit foreground to keep the
        // Oxblood accent and an underline to make the affordance
        // visible against the muted body copy.
        var s = AttributedString(prefix)

        var bold = AttributedString(installToken)
        bold.inlinePresentationIntent = .stronglyEmphasized
        s += bold

        s += AttributedString(middle)

        var link = AttributedString(linkLabel)
        if let url = URL(string: urlString) {
            link.link = url
        }
        link.foregroundColor = .ostlerOxblood
        link.underlineStyle = .single
        s += link

        s += AttributedString(suffix)

        return Text(s)
            .font(.ostlerBodyLg)
            .foregroundStyle(Color.ostlerInk)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Q19 (consent_third_party) body. CX-18 (Studio retest #13,
    /// 2026-05-23): the previous render was a wall of equal-weight
    /// body text from a single MSG_PROMPT_CONSENT_THIRD_PARTY_HELP
    /// string with "Legal note:" buried mid-paragraph. The default
    /// help-text path rendered the whole thing through linkifiedHelp()
    /// in one Text() view with no visual subordination of the GDPR
    /// fine-print.
    ///
    /// New render splits the screen into two Text() views, both
    /// fed from ViewCopy keys (Rule 0.9 catalogue):
    ///   - intro_body  (standard body copy, primary explanation)
    ///   - legal_note  (smaller, italic, .secondary-coloured: looks
    ///                  like fine print, reads like fine print)
    ///
    /// The docs.ostler.ai/privacy/third-party-data link inside
    /// legal_note is auto-detected and made clickable by the existing
    /// linkifyHelpText() Markdown-style post-processor.
    ///
    /// Bash-side MSG_PROMPT_CONSENT_THIRD_PARTY_HELP is unchanged so
    /// the TTY install path still renders the full text inline.
    private func consentThirdPartyBody() -> some View {
        let intro = ViewCopy.shared.string(for: "consent_third_party.intro_body")
        let legal = ViewCopy.shared.string(for: "consent_third_party.legal_note")
        return VStack(alignment: .leading, spacing: .ostlerSpace3) {
            Text(linkifiedHelp(intro))
                .font(.ostlerBodyLg)
                .foregroundStyle(Color.ostlerInkMuted)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            Text(linkifiedHelp(legal))
                .font(.ostlerCaption.italic())
                .foregroundStyle(.secondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Q12 (passkey_ack) body: modality-branched help copy.
    ///
    /// LAUNCH BLOCKER fix 2026-05-22. The bash-side
    /// MSG_PROMPT_PASSKEY_ACK_HELP hard-coded "Touch ID" which fails
    /// on every desktop Mac without a Magic Keyboard with Touch ID
    /// (Mac Studio, Mac Mini, Mac Pro, standard iMac). We override
    /// the bash help text with one of three catalogue strings based
    /// on the modality detected by `BiometricProbe` at process start.
    ///
    /// The underlying encryption flow does not change -- the
    /// passkey-wrapped DEK from task #130 already supports password
    /// + Apple Watch fallback on macOS Sequoia+. Only the copy
    /// differs by modality, so the customer reads an honest screen.
    private func passkeyAckBody() -> some View {
        let key: String
        switch BiometricProbe.cachedModality {
        case .touchID:
            key = "passkey_ack.help_touch_id"
        case .opticID:
            key = "passkey_ack.help_optic_id"
        case .none:
            key = "passkey_ack.help_password_or_watch"
        }
        return Text(ViewCopy.shared.string(for: key))
            .font(.ostlerBodyLg)
            .foregroundStyle(Color.ostlerInkMuted)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Q14 (recovery_passphrase) helper copy, modality-branched to
    /// match the primary unlock factor. Sister to passkeyAckBody:
    /// the bash-side MSG_PROMPT_RECOVERY_PASSPHRASE_HELP hard-coded
    /// "Touch ID" as the fallback referent, but the recovery
    /// passphrase falls back from whatever primary the customer's
    /// Mac actually uses (Touch ID on MacBook Pro / Magic Keyboard;
    /// login password + Apple Watch on Mac Studio / Mac Mini).
    private func recoveryPassphraseBody() -> some View {
        let key: String
        switch BiometricProbe.cachedModality {
        case .touchID:
            key = "recovery_passphrase.help_touch_id"
        case .opticID:
            key = "recovery_passphrase.help_optic_id"
        case .none:
            key = "recovery_passphrase.help_password_or_watch"
        }
        return Text(ViewCopy.shared.string(for: key))
            .font(.ostlerBodyLg)
            .foregroundStyle(Color.ostlerInkMuted)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Prompt ids that render as information-only screens -- no user
    /// input control beyond the Continue button, just title + body
    /// copy. For these the "QUESTION X" header is misleading (the
    /// customer is reading, not answering), so the header renders
    /// "FOR YOUR INFORMATION" instead. Best-effort identification
    /// from the catalogue probe done as part of CX-14 Section B3;
    /// Andy will confirm at the next Studio retest.
    ///
    /// Identified via `grep -n " acknowledge " install.sh`:
    ///   - `exports_ack`    (Q: "Have you requested your data exports?")
    ///   - `passkey_ack`    ("Ready to set up disk encryption")
    ///
    /// Both are `.acknowledge`-kind prompts that render no input
    /// field. If a future prompt joins this shape, add it to the
    /// Set below.
    private static let statementPromptIds: Set<String> = [
        "exports_ack",
        "passkey_ack"
    ]

    /// "Question 5" style header. Studio retest #8 (2026-05-22) caught
    /// the "of Y" total being a jumpy mess in practice: Q1-Q7 ran
    /// before the channel_choice answer expanded the dynamic question
    /// set, so they rendered without "of Y"; Q8-Q14 then suddenly
    /// gained "OF 14"; Q15+ (conditional recovery_passphrase + retry)
    /// overran the planned total and dropped "of Y" again. Three
    /// shapes in one flow looked broken. Andy chose to drop the
    /// "of Y" suffix entirely -- just "QUESTION X" at every step.
    /// The sidebar already shows phase progress, so the customer
    /// still has an anchor.
    ///
    /// B3 (CX-14): statement-shaped prompts (info-only screens with
    /// no input control) render "FOR YOUR INFORMATION" instead of
    /// "QUESTION X". Path A per Andy's pre-answered default --
    /// hard-coded Set<String> short-circuit, no metadata protocol
    /// extension (which would have churned the contract tests).
    private func header(_ q: DisplayedQuestion) -> some View {
        let isStatement = Self.statementPromptIds.contains(q.prompt.id)
        let labelKey = isStatement
            ? "onboarding_question.header_statement_label"
            : "onboarding_question.header_without_total"
        let label = isStatement
            ? ViewCopy.shared.string(for: labelKey)
            : ViewCopy.shared.string(
                for: labelKey,
                fills: ["current": String(q.index)]
            )
        let suffix = q.isReview
            ? ViewCopy.shared.string(for: "onboarding_question.header_review_suffix")
            : ""
        return HStack(spacing: .ostlerSpace2) {
            Text((label + suffix).uppercased())
                .font(.ostlerStrap)
                .tracking(1.6)
                .foregroundStyle(q.isReview ? Color.ostlerInkBlue : Color.ostlerOxblood)
            Spacer()
        }
    }

    @ViewBuilder
    private func inputField(_ q: DisplayedQuestion) -> some View {
        switch q.prompt.kind {
        case .text:
            TextField("", text: q.isReview
                      ? .constant(q.priorAnswer ?? "")
                      : $textValue)
                .textFieldStyle(.roundedBorder)
                .font(.ostlerBodyLg)
                .tint(.ostlerOxblood)
                .focused($focused)
                .disabled(q.isReview)
                .onSubmit { submit(q) }
        case .secret:
            if q.isReview {
                Text(q.priorAnswer ?? ViewCopy.shared.string(
                    for: "onboarding_question.secret_review_placeholder"
                ))
                    .font(.ostlerBody)
                    .foregroundStyle(Color.ostlerInkMuted)
                    .padding(.vertical, .ostlerSpace2)
            } else {
                SecureField("", text: $secretValue)
                    .textFieldStyle(.roundedBorder)
                    .font(.ostlerBodyLg)
                    .tint(.ostlerOxblood)
                    .focused($focused)
                    .onSubmit { submit(q) }
            }
        case .yesno:
            HStack(spacing: .ostlerSpace2) {
                Toggle(isOn: q.isReview
                       ? .constant(yesValue(q.priorAnswer ?? ""))
                       : $yesnoValue) {
                    Text(yesLabel(q))
                        .font(.ostlerBody)
                        .foregroundStyle(Color.ostlerInk)
                }
                .toggleStyle(.switch)
                .tint(.ostlerOxblood)
                .disabled(q.isReview)
                Spacer()
            }
        case .choice:
            // F6.6: fda_preset gets a proper segmented / radio
            // control with all three options visible at once.
            // Andy: "'Choose 1, 2, or 3' and then sub text:
            // '1=Recommended, 2=Everything, 3=Customise'... I mean
            // WTAF?!"  Other choice prompts continue to render as
            // a menu picker (default macOS native control).
            if q.prompt.id == "fda_preset" {
                fdaPresetSegmented(q)
            } else {
                Picker("", selection: q.isReview
                       ? .constant(q.priorAnswer ?? (q.prompt.choices.first ?? ""))
                       : $choiceValue) {
                    ForEach(q.prompt.choices, id: \.self) { choice in
                        Text(choiceLabel(promptId: q.prompt.id, value: choice))
                            .tag(choice)
                    }
                }
                .pickerStyle(.menu)
                .disabled(q.isReview)
            }
        case .acknowledge:
            // Button-only -- no input control. The Continue button
            // in `buttonRow` is the only interaction. We render
            // nothing here; the prompt title + help carry the
            // entire message.
            EmptyView()
        case .folder:
            folderPicker(q)
        case .textWithCancel:
            // Typed-input legal gate: same control shape as `.text`
            // but the Continue button in `buttonRow` is disabled
            // until the trimmed input upper-cased matches the
            // accept sentinel in `choices[0]` (e.g. "INSTALL").
            // The companion Cancel button posts `choices[1]`
            // (e.g. "CANCEL") for graceful exit.
            TextField(
                ViewCopy.shared.string(
                    for: "onboarding_question.consent_install_typed_placeholder"
                ),
                text: q.isReview ? .constant(q.priorAnswer ?? "") : $textValue
            )
                .textFieldStyle(.roundedBorder)
                .font(.ostlerBodyLg)
                .tint(.ostlerOxblood)
                .focused($focused)
                .disabled(q.isReview)
                .onSubmit { submit(q) }
        }
    }

    /// F6.6 fda_preset segmented control. Renders three radio-style
    /// rows, each with a heading + subtitle, so the customer sees
    /// what they're choosing without scrolling or guessing.
    private func fdaPresetSegmented(_ q: DisplayedQuestion) -> some View {
        let selection = q.isReview ? (q.priorAnswer ?? "") : choiceValue
        return VStack(alignment: .leading, spacing: .ostlerSpace2) {
            fdaPresetRow(
                value: "recommended",
                titleKey: "onboarding_question.fda_preset_recommended",
                subtitleKey: "onboarding_question.fda_preset_recommended_subtitle",
                selection: selection,
                isReview: q.isReview
            )
            fdaPresetRow(
                value: "everything",
                titleKey: "onboarding_question.fda_preset_everything",
                subtitleKey: "onboarding_question.fda_preset_everything_subtitle",
                selection: selection,
                isReview: q.isReview
            )
            fdaPresetRow(
                value: "customise",
                titleKey: "onboarding_question.fda_preset_customise",
                subtitleKey: "onboarding_question.fda_preset_customise_subtitle",
                selection: selection,
                isReview: q.isReview
            )
        }
    }

    private func fdaPresetRow(value: String,
                              titleKey: String,
                              subtitleKey: String,
                              selection: String,
                              isReview: Bool) -> some View {
        let selected = selection == value
        return Button {
            if !isReview {
                choiceValue = value
            }
        } label: {
            HStack(alignment: .top, spacing: .ostlerSpace2) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(selected ? Color.ostlerOxblood : Color.ostlerInkMuted)
                VStack(alignment: .leading, spacing: 2) {
                    Text(ViewCopy.shared.string(for: titleKey))
                        .font(.ostlerH3)
                        .foregroundStyle(Color.ostlerInk)
                    Text(ViewCopy.shared.string(for: subtitleKey))
                        .font(.ostlerBody)
                        .foregroundStyle(Color.ostlerInkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .padding(.vertical, .ostlerSpace2)
            .padding(.horizontal, .ostlerSpace3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? Color.ostlerOxbloodSoft : Color.ostlerPanel)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(selected ? Color.ostlerOxblood.opacity(0.55) : Color.ostlerHairlineSoft, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(isReview)
    }

    /// F6.5 folder picker control. Shows the currently-chosen path
    /// (default `~/Downloads`), a "Choose Folder..." button that
    /// pops NSOpenPanel, and a separate "Skip this step" button.
    /// `folderValue` stays as the resolved path; Skip clears it to
    /// empty string before submitting (install.sh treats empty as
    /// "skip the import").
    @ViewBuilder
    private func folderPicker(_ q: DisplayedQuestion) -> some View {
        let displayed = q.isReview
            ? (q.priorAnswer ?? "")
            : folderValue
        VStack(alignment: .leading, spacing: .ostlerSpace2) {
            HStack(alignment: .center, spacing: .ostlerSpace2) {
                Image(systemName: "folder")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(Color.ostlerInkMuted)
                Text(displayed.isEmpty
                     ? ViewCopy.shared.string(for: "onboarding_question.folder_picker_no_selection_placeholder")
                     : displayed)
                    .font(.ostlerMonoSm)
                    .foregroundStyle(Color.ostlerInk)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button(ViewCopy.shared.string(
                    for: "onboarding_question.folder_picker_choose_button"
                )) {
                    chooseFolder(q)
                }
                .buttonStyle(.ostlerGhost)
                .disabled(q.isReview)
            }
            .padding(.horizontal, .ostlerSpace2)
            .padding(.vertical, .ostlerSpace2)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.ostlerPanel)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.ostlerHairlineSoft, lineWidth: 1)
            )
        }
    }

    /// Pops NSOpenPanel scoped to directories, defaulting to the
    /// current `folderValue` (or `~/Downloads` if none).
    private func chooseFolder(_ q: DisplayedQuestion) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = ViewCopy.shared.string(
            for: "onboarding_question.folder_picker_choose_panel_prompt"
        )
        let initial = folderValue.isEmpty
            ? ("~/Downloads" as NSString).expandingTildeInPath
            : folderValue
        panel.directoryURL = URL(fileURLWithPath: initial)
        if panel.runModal() == .OK, let url = panel.url {
            folderValue = url.path
        }
    }

    private func buttonRow(_ q: DisplayedQuestion) -> some View {
        HStack(spacing: .ostlerSpace2) {
            Button(ViewCopy.shared.string(for: "onboarding_question.back_button")) {
                coordinator.enterBackReview()
            }
                .buttonStyle(.ostlerGhost)
                .disabled(!backEnabled(q))
                .help(backTooltip(q))

            Spacer()

            if q.isReview {
                Button(ViewCopy.shared.string(for: "onboarding_question.return_button")) {
                    coordinator.exitBackReview()
                }
                .buttonStyle(.ostlerPrimary)
                .keyboardShortcut(.defaultAction)
            } else if q.prompt.kind == .textWithCancel {
                // Typed-input legal gate (e.g. Q15 consent_install):
                // Cancel posts choices[1] back to install.sh for
                // graceful exit; Continue submits choices[0] but
                // only when the customer's typed input matches the
                // accept sentinel (case-insensitive, trimmed).
                // The disabled state on Continue prevents the
                // "type CONTINUE then press CONTINUE" footgun the
                // pre-2026-05-22 acknowledge-kind suffered from.
                let cancelSentinel = q.prompt.choices.count > 1
                    ? q.prompt.choices[1]
                    : "CANCEL"
                Button(ViewCopy.shared.string(for: "onboarding_question.consent_install_cancel")) {
                    coordinator.respond(to: q.prompt, with: cancelSentinel)
                }
                .buttonStyle(.ostlerGhost)

                Button(ViewCopy.shared.string(for: "onboarding_question.consent_install_primary")) {
                    submit(q)
                }
                .buttonStyle(.ostlerPrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(!typedInstallMatches(q, textValue))
            } else if q.prompt.kind == .folder {
                // F6.5: folder picker carries a Skip button alongside
                // the standard Continue. Skip submits an empty path
                // -- install.sh interprets that as "skip the import".
                Button(ViewCopy.shared.string(
                    for: "onboarding_question.folder_picker_skip_button"
                )) {
                    coordinator.respond(to: q.prompt, with: "")
                }
                .buttonStyle(.ostlerGhost)

                Button(ViewCopy.shared.string(for: "onboarding_question.continue_button")) {
                    submit(q)
                }
                .buttonStyle(.ostlerPrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(folderValue.isEmpty)
            } else {
                Button(ViewCopy.shared.string(for: "onboarding_question.continue_button")) {
                    submit(q)
                }
                    .buttonStyle(.ostlerPrimary)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    /// Back is enabled when there is at least one prior answer to
    /// review and we are not already at the oldest entry.
    private func backEnabled(_ q: DisplayedQuestion) -> Bool {
        if coordinator.answerHistory.isEmpty { return false }
        if let idx = coordinator.backReviewIndex {
            return idx > 0
        }
        return true
    }

    private func backTooltip(_ q: DisplayedQuestion) -> String {
        if coordinator.answerHistory.isEmpty {
            return ViewCopy.shared.string(for: "onboarding_question.back_tooltip_empty")
        }
        return ViewCopy.shared.string(for: "onboarding_question.back_tooltip_default")
    }

    private func submit(_ q: DisplayedQuestion) {
        let answer = currentAnswer(q)
        if let err = validate(q, answer: answer) {
            validationError = err
            return
        }
        validationError = nil
        coordinator.respond(to: q.prompt, with: answer)
        // After submit the next PROMPT (or DONE) will arrive; reset
        // the local input state so the next render starts clean.
        textValue = ""
        secretValue = ""
        yesnoValue = true
        choiceValue = ""
        folderValue = ""
    }

    private func currentAnswer(_ q: DisplayedQuestion) -> String {
        switch q.prompt.kind {
        case .text:        return textValue
        case .secret:      return secretValue
        case .yesno:       return yesnoValue ? "y" : "n"
        case .choice:      return choiceValue
        case .acknowledge:
            // Acknowledgement carries the default value back to
            // install.sh as the "answer". Most install.sh callers
            // ignore the return; the consent_install path branches
            // on it (INSTALL vs CANCEL), but consent_install uses
            // its own button row above, not the default Continue.
            return q.prompt.defaultValue ?? ""
        case .folder:      return folderValue
        case .textWithCancel:
            // Submit the accept sentinel verbatim (e.g. "INSTALL")
            // rather than the raw typed text so install.sh's FIFO
            // reader does not see case / whitespace variation.
            // The validator below has already confirmed the trimmed
            // upper-cased input matches choices[0]; we round-trip
            // that canonical form back to install.sh.
            return q.prompt.choices.first ?? textValue
        }
    }

    /// Returns true if the customer's typed input satisfies the
    /// accept sentinel for the current `.textWithCancel` prompt.
    /// Thin wrapper around the module-scope pure function so the
    /// view + the OstlerInstallerTests target hit the same logic
    /// (see `typedInstallInputMatches(sentinel:input:)`).
    fileprivate func typedInstallMatches(_ q: DisplayedQuestion, _ input: String) -> Bool {
        guard q.prompt.kind == .textWithCancel else { return false }
        return typedInstallInputMatches(
            sentinel: q.prompt.choices.first ?? "",
            input: input
        )
    }

    /// Returns nil when the answer is acceptable, or a customer-
    /// facing error message otherwise. v7.1 keeps validation
    /// conservative: empty text + empty choice are rejected; secrets
    /// and yes/no toggles are always submittable. install.sh's own
    /// validation re-runs the relevant checks after the answer
    /// lands.
    private func validate(_ q: DisplayedQuestion, answer: String) -> String? {
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        switch q.prompt.kind {
        case .text:
            if trimmed.isEmpty && (q.prompt.defaultValue ?? "").isEmpty {
                return ViewCopy.shared.string(for: "onboarding_question.error_empty_text")
            }
        case .choice:
            if trimmed.isEmpty {
                return ViewCopy.shared.string(for: "onboarding_question.error_empty_choice")
            }
            if !q.prompt.choices.contains(trimmed) {
                let options = q.prompt.choices.joined(separator: ", ")
                return ViewCopy.shared.string(
                    for: "onboarding_question.error_invalid_choice",
                    fills: ["options": options]
                )
            }
        case .yesno, .secret, .acknowledge, .folder:
            // acknowledge: never empty (default carries the answer).
            // folder: Skip submits "" deliberately; Continue is
            //         disabled when folderValue is empty so validate
            //         is only reached with a real path.
            break
        case .textWithCancel:
            // Legal-gate validator: the trimmed + upper-cased input
            // must exactly match the accept sentinel (choices[0]).
            // The Continue button is also gated on this check, so
            // validate() should normally only see a satisfying input;
            // this branch is defence-in-depth in case the button
            // logic ever drifts.
            if !typedInstallMatches(q, answer) {
                return ViewCopy.shared.string(
                    for: "onboarding_question.consent_install_typed_mismatch"
                )
            }
        }
        return nil
    }

    /// Seeds the local input state from a freshly-displayed question.
    /// Re-runs when the prompt id changes or when review mode flips.
    private func seed(from q: DisplayedQuestion) {
        validationError = nil
        if q.isReview {
            // Review state is rendered straight from priorAnswer via
            // .constant() bindings so we deliberately don't touch
            // the local @State here.
            lastSeededPromptId = q.prompt.id
            return
        }
        guard lastSeededPromptId != q.prompt.id else { return }
        lastSeededPromptId = q.prompt.id
        let def = q.prompt.defaultValue ?? ""
        switch q.prompt.kind {
        case .text:
            // F6.1: assistant_name pre-fills a randomly-chosen
            // suggestion from the ViewCopy pool, so the field
            // starts with brand-warm prompt-bait rather than blank.
            if q.prompt.id == "assistant_name" {
                textValue = randomAssistantSuggestion(fallback: def)
            } else {
                textValue = def
            }
        case .secret:      secretValue = ""
        case .yesno:       yesnoValue = yesValue(def)
        case .choice:      choiceValue = def.isEmpty
            ? (q.prompt.choices.first ?? "")
            : def
        case .acknowledge: break // no input state to seed
        case .textWithCancel:
            // Always start blank. The customer's typed-INSTALL
            // ceremony is the whole point; pre-filling would
            // undermine the "proactively write INSTALL" legal
            // intent.
            textValue = ""
        case .folder:
            // Default is supplied by install.sh as the customer's
            // ~/Downloads path. Tilde-expand defensively (gui_read
            // already expands but defence-in-depth is cheap).
            let expanded = (def as NSString).expandingTildeInPath
            folderValue = expanded
        }
        focused = true
    }

    /// Looks up a human-readable label for a `.choice` prompt option
    /// via ViewCopy key `onboarding_question.choice_label.{id}.{value}`.
    /// install.sh passes raw machine values (`"1"`, `"recommended"`,
    /// etc.) so without this lookup the dropdown shows the raw codes.
    /// Falls back to the raw value when no label is catalogued.
    private func choiceLabel(promptId: String, value: String) -> String {
        let key = "onboarding_question.choice_label.\(promptId).\(value)"
        let label = ViewCopy.shared.string(for: key)
        // ViewCopy returns the key itself when the lookup misses; treat
        // that as "no label catalogued" and surface the raw value.
        if label == key { return value }
        return label
    }

    /// F6.1: pull one suggestion at random from the ViewCopy
    /// `assistant_name_suggestions.comma_separated` catalogue value.
    /// Falls back to `Marvin` if the catalogue is missing.
    private func randomAssistantSuggestion(fallback: String) -> String {
        let csv = ViewCopy.shared.string(
            for: "assistant_name_suggestions.comma_separated"
        )
        let pool = csv
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if let pick = pool.randomElement() {
            return pick
        }
        return fallback.isEmpty ? "Marvin" : fallback
    }

    private func yesLabel(_ q: DisplayedQuestion) -> String {
        let value = q.isReview ? yesValue(q.priorAnswer ?? "") : yesnoValue
        let key = value ? "onboarding_question.yes_label"
                        : "onboarding_question.no_label"
        return ViewCopy.shared.string(for: key)
    }

    private func yesValue(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if trimmed.isEmpty { return true }
        return trimmed.hasPrefix("y")
    }

    /// B2 (CX-14): turn `https://...` and bare `docs.ostler.ai/...`
    /// substrings inside `help` into clickable AttributedString runs.
    /// Thin wrapper around the module-scope pure function so the
    /// OstlerInstallerTests target can exercise `linkifyHelpText`
    /// directly without spinning up a SwiftUI host.
    fileprivate func linkifiedHelp(_ raw: String) -> AttributedString {
        return linkifyHelpText(raw)
    }
}

private struct DisplayedQuestion: Equatable {
    let prompt: InstallerCoordinator.PendingPrompt
    let index: Int
    let priorAnswer: String?
    let isReview: Bool
}

/// Pure validator for the `.textWithCancel` typed-input legal gate.
///
/// Returns true when `input` is a legitimate match for `sentinel`:
///   - case-insensitive (lower-cased "install" accepts as readily
///     as upper-cased "INSTALL")
///   - whitespace-trimmed at start AND end ("  INSTALL  " accepts)
///   - empty sentinel rejects every input as a defence-in-depth
///     guard against an install.sh bug passing no choices through
///
/// Deliberate non-matches: empty input ("" -> false), partial
/// typing ("INSTAL" -> false), Unicode lookalikes (full-width
/// "ＩＮＳＴＡＬＬ" -> false because String.uppercased() does not
/// fold Halfwidth+Fullwidth to ASCII). The legal-ceremony intent
/// is "customer typed the exact ASCII word"; Unicode lookalikes
/// would defeat that intent.
///
/// Lives at module scope so OstlerInstallerTests can exercise it
/// directly via `@testable import OstlerInstaller`, mirroring the
/// `looksLikeShortLicenceId` pattern in LicenseEntryView.swift.
func typedInstallInputMatches(sentinel: String, input: String) -> Bool {
    guard !sentinel.isEmpty else { return false }
    let typed = input.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    return typed == sentinel.uppercased()
}

/// B2 (CX-14): URL-regex post-processor that turns plain help text
/// into an AttributedString with `.link` attribute runs on detected
/// URL substrings. Replaces a SwiftUI `Text(String)` call site so
/// `docs.ostler.ai/data-exports` (etc.) becomes clickable instead
/// of rendering as inert text.
///
/// Detected URL shapes (narrow by design to avoid catalogue-string
/// false positives):
///   - `https://` followed by host + path until a delimiter
///   - bare `docs.ostler.ai/...` (auto-prefixed with `https://` for
///     the `.link` URL value; rendered text keeps the bare form)
///
/// Deliberately NOT detected:
///   - `http://` (no insecure links in customer copy)
///   - bare hostnames that aren't `docs.ostler.ai` (e.g. plain
///     `ostler.ai/terms` -- the consent_install body has its own
///     specialised handler `consentInstallBody()` and we don't want
///     to double-handle)
///   - underscored keys like `download_my_data` or
///     `info_and_permissions` that appear inside catalogue strings
///     (a Markdown alternative would have rendered these as italic
///     delimiters; the narrow regex sidesteps the problem)
///
/// Delimiter set: any character that terminates a URL inside body
/// copy. Trailing punctuation (`.` `,` `;` `:` `)` `]` `"` `'` `!`
/// `?`) is excluded from the link run -- a customer copy line like
/// "see docs.ostler.ai/data-exports." should not include the period
/// in the clickable target.
///
/// Lives at module scope so OstlerInstallerTests can exercise it
/// directly via `@testable import OstlerInstaller`, mirroring the
/// `typedInstallInputMatches` pattern above.
func linkifyHelpText(_ raw: String) -> AttributedString {
    // Two-pattern alternation: explicit `https://...` OR bare
    // `docs.ostler.ai/...`. NSRegularExpression doesn't support
    // possessive quantifiers but greedy `+` plus a strict character
    // class is enough here -- URLs don't contain spaces or the
    // closing-bracket / punctuation set we exclude below.
    //
    // The trailing class excludes whitespace, end-of-string, and
    // common sentence-ending punctuation. Anchors are NOT used so
    // multiple URLs in the same string each get their own run.
    let pattern = "(https://[A-Za-z0-9._~%/\\-?=&#+]+|docs\\.ostler\\.ai/[A-Za-z0-9._~%/\\-?=&#+]+)"
    guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
        return AttributedString(raw)
    }

    let nsRaw = raw as NSString
    let fullRange = NSRange(location: 0, length: nsRaw.length)
    let matches = regex.matches(in: raw, options: [], range: fullRange)
    guard !matches.isEmpty else {
        return AttributedString(raw)
    }

    var result = AttributedString()
    var cursor = 0

    for match in matches {
        let r = match.range
        // Prefix segment before this URL.
        if r.location > cursor {
            let prefix = nsRaw.substring(
                with: NSRange(location: cursor, length: r.location - cursor)
            )
            result += AttributedString(prefix)
        }

        // Extract the matched URL, then trim trailing sentence
        // punctuation off the URL itself (but keep it as plain
        // text after the link so the sentence still reads
        // correctly).
        var urlText = nsRaw.substring(with: r)
        var tail = ""
        let trailingPunctuation: Set<Character> = [
            ".", ",", ";", ":", ")", "]", "\"", "'", "!", "?"
        ]
        while let last = urlText.last, trailingPunctuation.contains(last) {
            tail = String(last) + tail
            urlText = String(urlText.dropLast())
        }
        guard !urlText.isEmpty else {
            // The whole match was punctuation -- shouldn't happen
            // given the pattern, but be defensive.
            result += AttributedString(nsRaw.substring(with: r))
            cursor = r.location + r.length
            continue
        }

        var linkRun = AttributedString(urlText)
        let urlValue = urlText.hasPrefix("https://")
            ? urlText
            : "https://" + urlText
        if let url = URL(string: urlValue) {
            linkRun.link = url
        }
        linkRun.foregroundColor = .ostlerOxblood
        linkRun.underlineStyle = .single
        result += linkRun

        if !tail.isEmpty {
            result += AttributedString(tail)
        }

        cursor = r.location + r.length
    }

    // Suffix segment after the final URL.
    if cursor < nsRaw.length {
        let suffix = nsRaw.substring(
            with: NSRange(location: cursor, length: nsRaw.length - cursor)
        )
        result += AttributedString(suffix)
    }

    return result
}

/// B2 test seam: returns the substrings detected as URLs by
/// `linkifyHelpText`, in source order, with trailing sentence
/// punctuation stripped. Pure-function mirror of the same regex +
/// trim logic the view uses. Lets the test target assert detection
/// shape without inspecting an opaque AttributedString.
func linkifyDetectedURLs(_ raw: String) -> [String] {
    let pattern = "(https://[A-Za-z0-9._~%/\\-?=&#+]+|docs\\.ostler\\.ai/[A-Za-z0-9._~%/\\-?=&#+]+)"
    guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
        return []
    }
    let nsRaw = raw as NSString
    let matches = regex.matches(
        in: raw,
        options: [],
        range: NSRange(location: 0, length: nsRaw.length)
    )
    let trailingPunctuation: Set<Character> = [
        ".", ",", ";", ":", ")", "]", "\"", "'", "!", "?"
    ]
    return matches.map { m -> String in
        var s = nsRaw.substring(with: m.range)
        while let last = s.last, trailingPunctuation.contains(last) {
            s = String(s.dropLast())
        }
        return s
    }
}
