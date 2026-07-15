// ConfirmLearnedView.swift
//
// End-of-install "Confirm what we learned about you" screen.
//
// The final propose-and-confirm gate of the install (the block in
// install.sh between the wiki-recompile hydrate and the Summary
// recap) asks the operator to confirm what the hydrate learned:
//
//   calendar_owner     whose calendar is this?          (kind: text)
//   calendar_type      what sort of calendar is it?     (kind: choice)
//   identity_collapse  are these fragments all you?     (kind: yesno)
//   identity_namesake  is this you, or a namesake?      (kind: choice)
//
// The bash side proposes via lib/ostler-confirm-calendars.py and
// lib/ostler-confirm-identity.py, emits one PROMPT per decision via
// gui_read, and feeds the answers back into the helpers' decision
// writers (calendars.json + corrections/duplicates.yaml). Without
// this view those prompts render through the generic
// OnboardingQuestionView controls (a bare text field, a menu
// picker, a yes/no switch) with no framing that this is the
// "confirm what we learned" moment and no visible evidence for the
// proposal.
//
// This view is the dedicated surface, dispatched from
// OnboardingQuestionView when the prompt id is one of the four
// confirmation ids (same per-prompt-id pattern as
// TailscaleConnectView for tailscale_connect):
//
//   - a "Confirm what we learned" strap replaces "QUESTION X"
//     (the operator is confirming, not being interviewed),
//   - the helper-supplied evidence (sample events / identity
//     signals from the prompt's `help` field) renders in a framed
//     panel so the operator can see WHY we propose the answer,
//   - accept/correct controls: the proposal arrives pre-selected
//     (radio cards) or pre-filled (owner name field), so plain
//     Continue accepts, and correcting is one click / one edit,
//   - the answer routes back through the caller's standard
//     submit(q) -> coordinator.respond(to:with:) -> gui_read FIFO
//     path, exactly like every other prompt, which install.sh
//     turns into `ostler-confirm-identity.py record` /
//     `ostler-confirm-calendars.py write` calls.
//
// Wire values (pinned by tests/test_confirm_ui_gui_answer_contract.sh
// against install.sh's case arms -- change them in lockstep):
//   identity_collapse   "y" (combine) / "n" (keep separate)
//   identity_namesake   "different" (veto merge) / "me"
//   calendar_type       the raw choice value (personal/work/...)
//   calendar_owner      the typed name (default kept on empty)
//
// All customer-facing strings route via ViewCopy.shared.string(for:)
// per Rule 0.9 -- v1.2 translation is a catalogue-file drop, not a
// code lift. The prompt title + evidence arrive already localised
// from install.sh.strings.{lang}.sh.

import SwiftUI

/// Prompt ids that belong to the end-of-install confirmation step
/// and get the dedicated ConfirmLearnedView instead of the generic
/// question body. Must stay in lockstep with the gui_read ids in
/// install.sh's "End-of-install confirmation" block (pinned by
/// tests/test_confirm_ui_gui_answer_contract.sh).
let confirmLearnedPromptIds: Set<String> = [
    "calendar_owner",
    "calendar_type",
    "identity_collapse",
    "identity_namesake",
]

/// One selectable accept/correct card on the confirmation screen.
/// `value` is the wire value posted back to install.sh's gui_read
/// FIFO; title/subtitle are ViewCopy catalogue keys.
struct ConfirmLearnedOption: Equatable {
    let value: String
    let titleKey: String
    let subtitleKey: String
}

/// Builds the card options for a confirmation prompt. Pure function
/// (module scope) so OstlerInstallerTests can pin the wire values
/// without a SwiftUI host.
///
/// - identity_collapse: the PROMPT is yesno-kind, so the cards carry
///   the canonical "y"/"n" wire values the coordinator's yesno path
///   sends (install.sh matches `yes|true|y|Y` for accept).
/// - identity_namesake / calendar_type: the cards carry the raw
///   choice values install.sh supplied in the PROMPT's `choices`
///   field, preserving bash-side order; catalogue keys are derived
///   per value.
/// - calendar_owner is text-kind and has no cards (returns []).
func confirmLearnedOptions(promptId: String, choices: [String]) -> [ConfirmLearnedOption] {
    switch promptId {
    case "identity_collapse":
        return [
            ConfirmLearnedOption(
                value: "y",
                titleKey: "confirm_learned.identity_collapse_y_title",
                subtitleKey: "confirm_learned.identity_collapse_y_subtitle"
            ),
            ConfirmLearnedOption(
                value: "n",
                titleKey: "confirm_learned.identity_collapse_n_title",
                subtitleKey: "confirm_learned.identity_collapse_n_subtitle"
            ),
        ]
    case "identity_namesake", "calendar_type":
        return choices.map { value in
            ConfirmLearnedOption(
                value: value,
                titleKey: "confirm_learned.\(promptId)_\(value)_title",
                subtitleKey: "confirm_learned.\(promptId)_\(value)_subtitle"
            )
        }
    default:
        return []
    }
}

/// The pre-selected card for a confirmation prompt -- the proposal
/// the operator accepts by just pressing Continue. Pure function for
/// tests.
///
/// identity_collapse normalises install.sh's yesno default ("yes")
/// onto the "y"/"n" card values. Choice prompts keep the bash-side
/// default when it is a real choice, else fall back to the first
/// choice (mirrors the generic seed(from:) behaviour).
func confirmLearnedDefaultSelection(promptId: String, defaultValue: String?, choices: [String]) -> String {
    if promptId == "identity_collapse" {
        let d = (defaultValue ?? "yes")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        // Empty default counts as accept -- the bash side passes
        // default "yes" and treats enter-on-empty as accept.
        return (d.isEmpty || d.hasPrefix("y") || d == "true") ? "y" : "n"
    }
    let d = (defaultValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    if !d.isEmpty && choices.contains(d) { return d }
    return choices.first ?? d
}

/// Final wire answer for a confirmation prompt. Pure function for
/// tests. For the owner-name text prompt an empty / whitespace-only
/// edit falls back to the proposed default (accept semantics --
/// install.sh applies the same fallback on its side, but sending
/// the canonical value keeps the answer history readable). Card
/// prompts post the selection verbatim.
func confirmLearnedWireAnswer(
    promptId: String,
    selection: String,
    typedText: String,
    defaultValue: String?
) -> String {
    if promptId == "calendar_owner" {
        let trimmed = typedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return (defaultValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return selection
}

struct ConfirmLearnedView: View {
    /// The PROMPT being answered (live or Back-review projection).
    let question: DisplayedQuestion

    /// Caller's submit hook. We hand back the final wire value; the
    /// caller seeds its input state + invokes its standard submit(q)
    /// so the answer reaches install.sh over the same FIFO path as
    /// every other prompt.
    let onSubmit: (String) -> Void

    /// Caller's exit hook for Back-review mode (the parent wires
    /// this to coordinator.exitBackReview()). The generic buttonRow
    /// is not rendered for dedicated views, so we surface our own
    /// Return button when reviewing.
    let onReturn: () -> Void

    /// Selected card wire value (card prompts only).
    @State private var selection: String = ""
    /// Edited owner name (calendar_owner only).
    @State private var ownerText: String = ""
    /// Guards against re-seeding on unrelated state changes.
    @State private var lastSeededPromptId: String? = nil
    @FocusState private var focused: Bool

    private var options: [ConfirmLearnedOption] {
        confirmLearnedOptions(
            promptId: question.prompt.id,
            choices: question.prompt.choices
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: .ostlerSpace4) {
            header
            Text(question.prompt.title)
                .font(.ostlerH1)
                .tracking(-0.4)
                .foregroundStyle(Color.ostlerInk)
                .fixedSize(horizontal: false, vertical: true)
            evidencePanel
            controls
            Spacer()
            buttonRow
        }
        .padding(.horizontal, .ostlerSpace4)
        .padding(.vertical, .ostlerSpace3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.ostlerChassis)
        .onAppear { seed() }
        .onChange(of: question.prompt.id) { _, _ in seed() }
        .onChange(of: question.isReview) { _, _ in seed() }
    }

    // MARK: header

    /// "CONFIRM WHAT WE LEARNED" strap instead of "QUESTION X" --
    /// the operator is verifying proposals, not being interviewed.
    /// Review mode appends the shared review suffix so Back
    /// navigation reads the same as on generic questions.
    private var header: some View {
        let label = ViewCopy.shared.string(for: "confirm_learned.header_label")
        let suffix = question.isReview
            ? ViewCopy.shared.string(for: "onboarding_question.header_review_suffix")
            : ""
        return HStack(spacing: .ostlerSpace2) {
            Text((label + suffix).uppercased())
                .font(.ostlerStrap)
                .tracking(1.6)
                .foregroundStyle(question.isReview ? Color.ostlerInkBlue : Color.ostlerOxblood)
            Spacer()
        }
    }

    // MARK: evidence

    /// The helper's evidence for the proposal (sample calendar
    /// events, or the shared/diverging identity signals), passed
    /// through the PROMPT's localised `help` field. Framed as a
    /// quiet panel so the operator can see why we are proposing the
    /// pre-filled answer.
    @ViewBuilder
    private var evidencePanel: some View {
        if let help = question.prompt.help, !help.isEmpty {
            VStack(alignment: .leading, spacing: .ostlerSpace1) {
                Text(ViewCopy.shared.string(for: "confirm_learned.evidence_heading").uppercased())
                    .font(.ostlerStrap)
                    .tracking(1.2)
                    .foregroundStyle(Color.ostlerInkMuted)
                Text(help)
                    .font(.ostlerBody)
                    .foregroundStyle(Color.ostlerInkMuted)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, .ostlerSpace3)
            .padding(.vertical, .ostlerSpace2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.ostlerPanel)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.ostlerHairlineSoft, lineWidth: 1)
            )
        }
    }

    // MARK: controls

    @ViewBuilder
    private var controls: some View {
        if question.prompt.id == "calendar_owner" {
            ownerField
        } else {
            VStack(alignment: .leading, spacing: .ostlerSpace2) {
                ForEach(options, id: \.value) { option in
                    optionCard(option)
                }
            }
        }
    }

    /// Owner-name accept/correct field: pre-filled with the proposed
    /// owner so plain Continue accepts; typing replaces it.
    private var ownerField: some View {
        VStack(alignment: .leading, spacing: .ostlerSpace1) {
            TextField("", text: question.isReview
                      ? .constant(question.priorAnswer ?? "")
                      : $ownerText)
                .textFieldStyle(.roundedBorder)
                .font(.ostlerBodyLg)
                .tint(.ostlerOxblood)
                .focused($focused)
                .disabled(question.isReview)
                .onSubmit { submit() }
            if !question.isReview {
                Text(ViewCopy.shared.string(for: "confirm_learned.calendar_owner_hint"))
                    .font(.ostlerCaption)
                    .foregroundStyle(Color.ostlerInkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Radio-style accept/correct card (same shape as the fda_preset
    /// segmented rows): heading + subtitle, proposal pre-selected.
    private func optionCard(_ option: ConfirmLearnedOption) -> some View {
        let current = question.isReview
            ? (question.priorAnswer ?? "")
            : selection
        let selected = current == option.value
        return Button {
            if !question.isReview {
                selection = option.value
            }
        } label: {
            HStack(alignment: .top, spacing: .ostlerSpace2) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(selected ? Color.ostlerOxblood : Color.ostlerInkMuted)
                VStack(alignment: .leading, spacing: 2) {
                    Text(ViewCopy.shared.string(for: option.titleKey))
                        .font(.ostlerH3)
                        .foregroundStyle(Color.ostlerInk)
                    Text(ViewCopy.shared.string(for: option.subtitleKey))
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
        .disabled(question.isReview)
    }

    // MARK: buttons

    private var buttonRow: some View {
        HStack(spacing: .ostlerSpace2) {
            Spacer()
            if question.isReview {
                Button(ViewCopy.shared.string(for: "onboarding_question.return_button")) {
                    onReturn()
                }
                .buttonStyle(.ostlerPrimary)
                .keyboardShortcut(.defaultAction)
            } else {
                Button(ViewCopy.shared.string(for: "onboarding_question.continue_button")) {
                    submit()
                }
                .buttonStyle(.ostlerPrimary)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: state

    private func seed() {
        if question.isReview {
            // Review renders straight from priorAnswer via
            // .constant() bindings; leave live state untouched.
            lastSeededPromptId = question.prompt.id
            return
        }
        guard lastSeededPromptId != question.prompt.id else { return }
        lastSeededPromptId = question.prompt.id
        selection = confirmLearnedDefaultSelection(
            promptId: question.prompt.id,
            defaultValue: question.prompt.defaultValue,
            choices: question.prompt.choices
        )
        ownerText = question.prompt.defaultValue ?? ""
        if question.prompt.id == "calendar_owner" {
            focused = true
        }
    }

    private func submit() {
        let answer = confirmLearnedWireAnswer(
            promptId: question.prompt.id,
            selection: selection,
            typedText: ownerText,
            defaultValue: question.prompt.defaultValue
        )
        onSubmit(answer)
    }
}

#if DEBUG
// Preview at the installer's nominal content size so canvas
// screenshots match what a customer sees mid-install.
#Preview("Confirm learned – identity collapse") {
    let prompt = InstallerCoordinator.PendingPrompt(
        id: "identity_collapse",
        kind: .yesno,
        title: "We found what looks like two copies of you",
        defaultValue: "yes",
        help: "Jane Doe + Jane A Doe (shared email domain example.com; shared LinkedIn profile)",
        choices: [],
        error: nil
    )
    let q = DisplayedQuestion(
        prompt: prompt,
        index: 0,
        priorAnswer: nil,
        isReview: false
    )
    return ConfirmLearnedView(question: q, onSubmit: { _ in }, onReturn: {})
        .frame(width: 920, height: 720)
}

#Preview("Confirm learned – calendar type") {
    let prompt = InstallerCoordinator.PendingPrompt(
        id: "calendar_type",
        kind: .choice,
        title: "What sort of calendar is \u{201C}Robin Carter\u{201D}?",
        defaultValue: "family",
        help: "14 events, e.g. Flight to Tokyo; School run",
        choices: ["personal", "work", "family", "shared", "other"],
        error: nil
    )
    let q = DisplayedQuestion(
        prompt: prompt,
        index: 0,
        priorAnswer: nil,
        isReview: false
    )
    return ConfirmLearnedView(question: q, onSubmit: { _ in }, onReturn: {})
        .frame(width: 920, height: 720)
}
#endif
