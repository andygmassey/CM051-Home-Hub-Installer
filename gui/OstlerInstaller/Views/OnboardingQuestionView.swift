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

            // consent_install carries a hyperlinked terms link in
            // place of plain help copy; render via a dedicated
            // helper. Everything else gets the standard
            // Text(help).
            if q.prompt.id == "consent_install" {
                consentInstallBody()
            } else if let help = q.prompt.help, !help.isEmpty {
                Text(help)
                    .font(.ostlerBodyLg)
                    .foregroundStyle(Color.ostlerInkMuted)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // F6.1 (assistant_name): inline helper copy explaining
            // the suggestions, mirroring Andy's brand-warmth note.
            if q.prompt.id == "assistant_name" && !q.isReview {
                Text(ViewCopy.shared.string(for: "onboarding_question.assistant_name_helper"))
                    .font(.ostlerBody)
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

    /// F6.8 consent_install body: "Ready to install. By clicking
    /// Install Ostler, you confirm you accept the [terms]." The
    /// `terms` token is rendered as a hyperlink to ostler.ai/terms
    /// via SwiftUI's AttributedString support; tapping opens the
    /// default browser through `NSWorkspace.shared.open(_:)`.
    private func consentInstallBody() -> some View {
        let prefix = ViewCopy.shared.string(for: "onboarding_question.consent_install_body_prefix")
        let linkLabel = ViewCopy.shared.string(for: "onboarding_question.consent_install_terms_link_label")
        let suffix = ViewCopy.shared.string(for: "onboarding_question.consent_install_body_suffix")
        let urlString = ViewCopy.shared.string(for: "onboarding_question.consent_install_terms_url")

        // AttributedString lets us embed a tappable link inline.
        // SwiftUI renders .link attributes as default-styled
        // clickable runs; we add an explicit foreground to keep the
        // Oxblood accent and an underline to make the affordance
        // visible against the muted body copy.
        var s = AttributedString(prefix)
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

    /// "Question 5 of 17" style header. Drops the "of Y" suffix until
    /// the channel_choice answer commits and Y becomes known.
    private func header(_ q: DisplayedQuestion) -> some View {
        let x = String(q.index)
        let label: String
        if let total = coordinator.totalQuestionCount {
            label = ViewCopy.shared.string(
                for: "onboarding_question.header_with_total",
                fills: ["current": x, "total": String(total)]
            )
        } else {
            label = ViewCopy.shared.string(
                for: "onboarding_question.header_without_total",
                fills: ["current": x]
            )
        }
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
                        Text(choice).tag(choice)
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
            } else if q.prompt.id == "consent_install" {
                // F6.8: Install Ostler / Cancel pair. Install posts
                // "INSTALL" back over the FIFO, Cancel posts "CANCEL"
                // (install.sh's loop branches on these values).
                Button(ViewCopy.shared.string(for: "onboarding_question.consent_install_cancel")) {
                    coordinator.respond(to: q.prompt, with: "CANCEL")
                }
                .buttonStyle(.ostlerGhost)

                Button(ViewCopy.shared.string(for: "onboarding_question.consent_install_primary")) {
                    coordinator.respond(to: q.prompt, with: "INSTALL")
                }
                .buttonStyle(.ostlerPrimary)
                .keyboardShortcut(.defaultAction)
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
        }
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
        case .folder:
            // Default is supplied by install.sh as the customer's
            // ~/Downloads path. Tilde-expand defensively (gui_read
            // already expands but defence-in-depth is cheap).
            let expanded = (def as NSString).expandingTildeInPath
            folderValue = expanded
        }
        focused = true
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
}

private struct DisplayedQuestion: Equatable {
    let prompt: InstallerCoordinator.PendingPrompt
    let index: Int
    let priorAnswer: String?
    let isReview: Bool
}
