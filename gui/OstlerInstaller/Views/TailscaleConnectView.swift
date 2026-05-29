// TailscaleConnectView.swift
//
// CX-81 Tailscale step (2026-05-26): dedicated full-screen
// "Connect your iPhone and Watch" view, dispatched from
// OnboardingQuestionView when prompt.id == "tailscale_connect".
// Paired with install.sh §3.15's `progress` STEP_BEGIN so the
// sidebar shows the row from launch.
//
// Why a dedicated view (not the default choice Picker):
//   The previous shape rendered the Tailscale opt-in as a yes/no
//   prompt buried mid-flow in Phase 3. Andy's Mac Studio retest
//   (2026-05-26) found customers skipping past it without noticing
//   they were being asked something significant. The dedicated
//   full-screen view with two big card-style buttons and a
//   collapsible mini-FAQ raises the prominence to match the
//   feature's launch importance (without it, the iOS Companion
//   only works on home Wi-Fi).
//
// Wiring:
//   - Caller (OnboardingQuestionView) hands us the DisplayedQuestion
//     and a single onSubmit callback that takes the chosen value.
//   - We emit "setup" or "skip" via the callback; the parent
//     populates its choiceValue + invokes submit(q), which routes
//     through coordinator.respond(to:with:) back to install.sh's
//     gui_read FIFO. Same control-flow as every other PROMPT.
//
// All copy lives in `gui/OstlerInstaller/Resources/ViewCopy.json`
// under the `tailscale_connect` key (Rule 0.9 lock).

import SwiftUI

struct TailscaleConnectView: View {
    /// The PROMPT being answered. Carries title/help/id for review
    /// mode + the choices the bash side will accept ("setup,skip").
    let question: DisplayedQuestion

    /// Caller's submit hook. We hand back the chosen value ("setup"
    /// or "skip") and the caller wires that into its choiceValue +
    /// invokes its standard submit(q) so the gui_read FIFO receives
    /// the answer through the same path as every other prompt.
    let onSubmit: (String) -> Void

    /// Local state for the collapsible mini-FAQ disclosures.
    @State private var expandedFAQ: String? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: .ostlerSpace4) {
                heading
                explainer
                buttons
                Divider()
                    .padding(.vertical, .ostlerSpace1)
                faq
                Spacer(minLength: .ostlerSpace4)
            }
            .padding(.horizontal, .ostlerSpace4)
            .padding(.vertical, .ostlerSpace3)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.ostlerChassis)
    }

    // MARK: heading

    private var heading: some View {
        VStack(alignment: .leading, spacing: .ostlerSpace1) {
            Text(ViewCopy.shared.string(for: "tailscale_connect.strap"))
                .font(.ostlerStrap)
                .tracking(1.6)
                .foregroundStyle(Color.ostlerInkMuted)
            Text(ViewCopy.shared.string(for: "tailscale_connect.heading"))
                .font(.ostlerH1)
                .tracking(-0.4)
                .foregroundStyle(Color.ostlerInk)
        }
    }

    // MARK: explainer

    private var explainer: some View {
        Text(ViewCopy.shared.string(for: "tailscale_connect.body"))
            .font(.ostlerBodyLg)
            .foregroundStyle(Color.ostlerInkMuted)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: buttons

    private var buttons: some View {
        VStack(alignment: .leading, spacing: .ostlerSpace2) {
            primaryButton
            secondaryButton
        }
    }

    private var primaryButton: some View {
        // Big card-style button. Tinted with the brand oxblood so
        // it reads as the recommended action even at a glance. The
        // sub-line under the headline gives the customer the "what
        // happens next" cost (~1 minute, app opens, we wait).
        Button(action: { onSubmit("setup") }) {
            HStack(spacing: .ostlerSpace2) {
                Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                    .font(.system(size: 28))
                VStack(alignment: .leading, spacing: 4) {
                    Text(ViewCopy.shared.string(for: "tailscale_connect.setup_button"))
                        .font(.ostlerBodyLg)
                        .fontWeight(.semibold)
                    Text(ViewCopy.shared.string(for: "tailscale_connect.setup_button_sub"))
                        .font(.ostlerCaption)
                        .foregroundStyle(.white.opacity(0.85))
                }
                Spacer()
            }
            .padding(.horizontal, .ostlerSpace3)
            .padding(.vertical, .ostlerSpace2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.ostlerOxblood)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(question.isReview)
    }

    private var secondaryButton: some View {
        Button(action: { onSubmit("skip") }) {
            HStack(spacing: .ostlerSpace2) {
                Image(systemName: "forward.circle")
                    .font(.system(size: 24))
                    .foregroundStyle(Color.ostlerInkMuted)
                VStack(alignment: .leading, spacing: 4) {
                    Text(ViewCopy.shared.string(for: "tailscale_connect.skip_button"))
                        .font(.ostlerBodyLg)
                        .foregroundStyle(Color.ostlerInk)
                    Text(ViewCopy.shared.string(for: "tailscale_connect.skip_button_sub"))
                        .font(.ostlerCaption)
                        .foregroundStyle(Color.ostlerInkMuted)
                }
                Spacer()
            }
            .padding(.horizontal, .ostlerSpace3)
            .padding(.vertical, .ostlerSpace2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.ostlerChassis)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.ostlerInkMuted.opacity(0.25), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(question.isReview)
    }

    // MARK: faq

    private var faq: some View {
        VStack(alignment: .leading, spacing: .ostlerSpace2) {
            Text(ViewCopy.shared.string(for: "tailscale_connect.faq_heading"))
                .font(.ostlerStrap)
                .tracking(1.2)
                .foregroundStyle(Color.ostlerInkMuted)

            faqRow(id: "what",
                   questionKey: "tailscale_connect.faq_what_q",
                   answerKey: "tailscale_connect.faq_what_a")
            faqRow(id: "secure",
                   questionKey: "tailscale_connect.faq_secure_q",
                   answerKey: "tailscale_connect.faq_secure_a")
            faqRow(id: "later",
                   questionKey: "tailscale_connect.faq_later_q",
                   answerKey: "tailscale_connect.faq_later_a")
        }
    }

    @ViewBuilder
    private func faqRow(id: String, questionKey: String, answerKey: String) -> some View {
        let isExpanded = expandedFAQ == id
        VStack(alignment: .leading, spacing: 6) {
            Button(action: {
                expandedFAQ = isExpanded ? nil : id
            }) {
                HStack(spacing: .ostlerSpace1) {
                    Image(systemName: isExpanded
                          ? "chevron.down"
                          : "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.ostlerInkMuted)
                        .frame(width: 16)
                    Text(ViewCopy.shared.string(for: questionKey))
                        .font(.ostlerBody)
                        .foregroundStyle(Color.ostlerInk)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                Text(ViewCopy.shared.string(for: answerKey))
                    .font(.ostlerCaption)
                    .foregroundStyle(Color.ostlerInkMuted)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 22)
                    .padding(.trailing, .ostlerSpace2)
                    .padding(.bottom, 4)
            }
        }
    }
}

#if DEBUG
// SwiftUI preview helper for designers + screenshot capture in
// Xcode's preview canvas. Wire identical to the live path so a
// preview-render matches what a customer sees mid-install. Render
// the view at the installer's nominal content size (920x720) so the
// screenshot in the PR body matches the bundled OstlerInstaller.app
// window geometry.
#Preview("Tailscale connect – first entry") {
    let prompt = InstallerCoordinator.PendingPrompt(
        id: "tailscale_connect",
        kind: .choice,
        title: "Connect your iPhone and Watch",
        defaultValue: "setup",
        help: nil,
        choices: ["setup", "skip"],
        error: nil
    )
    let q = DisplayedQuestion(
        prompt: prompt,
        index: 0,
        priorAnswer: nil,
        isReview: false
    )
    return TailscaleConnectView(question: q, onSubmit: { _ in })
        .frame(width: 920, height: 720)
}
#endif
