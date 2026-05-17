// OnboardingQuestionView.swift
//
// In-window renderer for #OSTLER PROMPT events. Replaces the
// `.sheet(item:)` PromptSheet path (deleted in #353) so the customer
// never sees an installer-popup over the main window during the
// 12-to-17 onboarding questions -- a single window-flow with a
// progress header instead.
//
// Reads either:
//   - `coordinator.pendingPrompt` (live, editable, Next sends the
//     answer back over the FIFO), or
//   - `coordinator.answerHistory[coordinator.backReviewIndex]` (Back
//     review mode, read-only -- bash has already consumed the answer
//     so we cannot re-send).
//
// v7.1 Back semantics deliberately conservative; Route A (full
// edit-and-resend) is the next iteration. See the brief at
// HR015/launch/TNM_BRIEF_CM051_INLINE_QUESTIONS_2026-05-17.md.

import SwiftUI

struct OnboardingQuestionView: View {
    @EnvironmentObject private var coordinator: InstallerCoordinator

    /// Live answer state (only used when not in review mode).
    @State private var textValue: String = ""
    @State private var secretValue: String = ""
    @State private var yesnoValue: Bool = true
    @State private var choiceValue: String = ""
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

            if let help = q.prompt.help, !help.isEmpty {
                Text(help)
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

    /// "Question 5 of 17 -- Setup questions" style header. Drops the
    /// "of Y" suffix until the channel_choice answer commits and Y
    /// becomes known.
    private func header(_ q: DisplayedQuestion) -> some View {
        let x = q.index
        let yLabel: String
        if let total = coordinator.totalQuestionCount {
            yLabel = "Question \(x) of \(total)"
        } else {
            yLabel = "Question \(x)"
        }
        let suffix = q.isReview ? "  (review)" : ""
        return HStack(spacing: .ostlerSpace2) {
            Text((yLabel + suffix).uppercased())
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
                Text(q.priorAnswer ?? "(hidden)")
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
    }

    private func buttonRow(_ q: DisplayedQuestion) -> some View {
        HStack(spacing: .ostlerSpace2) {
            Button("Back") { coordinator.enterBackReview() }
                .buttonStyle(.ostlerGhost)
                .disabled(!backEnabled(q))
                .help(backTooltip(q))

            Spacer()

            if q.isReview {
                Button("Return to current question") {
                    coordinator.exitBackReview()
                }
                .buttonStyle(.ostlerPrimary)
                .keyboardShortcut(.defaultAction)
            } else {
                Button("Continue") { submit(q) }
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
            return "No previous answers yet."
        }
        return "Review previous answers. Editing is disabled in this version; cancel and re-run the installer to revise."
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
    }

    private func currentAnswer(_ q: DisplayedQuestion) -> String {
        switch q.prompt.kind {
        case .text:   return textValue
        case .secret: return secretValue
        case .yesno:  return yesnoValue ? "y" : "n"
        case .choice: return choiceValue
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
                return "Please enter a value to continue."
            }
        case .choice:
            if trimmed.isEmpty {
                return "Please pick one of the options."
            }
            if !q.prompt.choices.contains(trimmed) {
                return "Pick one of: " + q.prompt.choices.joined(separator: ", ")
            }
        case .yesno, .secret:
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
        case .text:   textValue = def
        case .secret: secretValue = ""
        case .yesno:  yesnoValue = yesValue(def)
        case .choice: choiceValue = def.isEmpty
            ? (q.prompt.choices.first ?? "")
            : def
        }
        focused = true
    }

    private func yesLabel(_ q: DisplayedQuestion) -> String {
        let value = q.isReview ? yesValue(q.priorAnswer ?? "") : yesnoValue
        return value ? "Yes" : "No"
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
