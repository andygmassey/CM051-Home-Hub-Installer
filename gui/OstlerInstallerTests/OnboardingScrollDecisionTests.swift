// OnboardingScrollDecisionTests.swift
//
// Regression net for the OnboardingQuestionView body-scroll decision
// (Andy box-walk 2026-07-31).
//
// PR #478 fixed the tall consent/ack prompts (consent_spoken_capture etc.)
// clipping their input off-screen by wrapping the middle body region in a
// ScrollView { }.frame(maxHeight: .infinity). But it applied that to EVERY
// prompt, so on the ~20 short-body prompts the greedy ScrollView ate the
// remaining vertical space and shoved the input widget to the viewport
// bottom with ugly empty whitespace above the fold. Andy's verbatim:
// "All the inputs are now stuck to the bottom of the viewport -- which is
// just AWFUL. You were ONLY meant to fix that 'Turn spoken conversations
// into text' one."
//
// The fix scrolls ONLY the known tall bodies (OnboardingQuestionView
// .scrollingBodyPromptIds); everything else flows naturally so the input
// sits just below its body copy. These tests pin that decision so a future
// change cannot silently re-broaden the ScrollView back over the short
// prompts (which is exactly the regression Andy caught).
//
// This is a pure-logic test of the scroll DECISION, not a pixel render.
// The render-crash net lives in OnboardingQuestionViewSnapshotTests
// (which already drives short + tall prompts through ImageRenderer).

import XCTest
@testable import OstlerInstaller

final class OnboardingScrollDecisionTests: XCTestCase {

    /// The five tall-body prompts that legitimately need an internal
    /// ScrollView so their legal fine-print does not push the input toggle
    /// off-screen (the PR #478 case that must be preserved).
    private let tallBodyPromptIds = [
        "consent_spoken_capture",   // Q23 -- the ONE Andy actually asked to fix
        "consent_third_party",
        "consent_article_9",
        "passkey_ack",
        "recovery_passphrase",
    ]

    /// A representative sample of short-body prompts that regressed under the
    /// global ScrollView: dropdown / yes-no / text / multi-card / etc. These
    /// MUST NOT scroll -- their input has to sit at its natural position.
    private let shortBodyPromptIds = [
        "user_name",
        "assistant_name",
        "channel_choice",
        "filevault_skip",
        "reuse_settings",
        "imessage_allowed_contacts",
        "fda_preset",
        "consent_install",          // hyperlinked terms, but flows naturally per spec
        "tailscale_connect",        // has its own dedicated view, never reaches this path
        "some_unknown_future_id",   // default: unknown ids flow naturally, never scroll
    ]

    func testTallBodiesScroll() {
        for id in tallBodyPromptIds {
            XCTAssertTrue(
                OnboardingQuestionView.needsScroll(id),
                "\(id) is a tall-body prompt and must scroll internally so its "
                    + "input is not pushed off-screen (PR #478 behaviour)."
            )
        }
    }

    func testShortBodiesDoNotScroll() {
        for id in shortBodyPromptIds {
            XCTAssertFalse(
                OnboardingQuestionView.needsScroll(id),
                "\(id) is a short-body prompt and must NOT scroll -- a greedy "
                    + "ScrollView shoves its input to the viewport bottom "
                    + "(the 2026-07-31 regression Andy caught)."
            )
        }
    }

    /// Pin the exact membership so a future edit that adds or drops an id is a
    /// deliberate, reviewed change (not an accidental re-broadening).
    func testScrollingSetIsExactlyTheFiveTallBodies() {
        XCTAssertEqual(
            OnboardingQuestionView.scrollingBodyPromptIds,
            Set(tallBodyPromptIds),
            "The scrolling-body set drifted. Adding/removing an id is a UX "
                + "decision -- update this test deliberately if intended."
        )
    }
}
