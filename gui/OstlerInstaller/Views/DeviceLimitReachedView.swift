// DeviceLimitReachedView.swift
//
// Shown when the Worker rejected this Mac's registration because the
// licence has already been used on its `max_hardware_fingerprints`
// slots. The view is a hard stop -- the install does not proceed.
//
// Two affordances:
//   - "Email hello@ostler.ai" opens a mailto: that includes the licence
//     id in the subject so the support reply can resolve quickly.
//     The dedicated reset-devices web flow is a v1.5 surface (see
//     CM050 Phase 2.4); a mailto is the v1 placeholder.
//   - "Quit installer" terminates the app cleanly.
//
// We deliberately do NOT mention the specific Macs in the licence's
// active set. The CM050 API does return the set, but exposing other-Mac
// fingerprints in the installer UI is a privacy footgun for a customer
// who shares the screenshot with us in support. We surface the count
// and the max only.

import AppKit
import SwiftUI

struct DeviceLimitReachedView: View {

    let licenseId: String
    let maxFingerprints: Int
    let registeredCount: Int

    var body: some View {
        VStack(spacing: 24) {
            header
            explanation
            actions
            Spacer()
            footerHint
        }
        .padding(.horizontal, 48)
        .padding(.vertical, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.ostlerChassis)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 28, weight: .regular))
                    .foregroundColor(.ostlerOxblood)
                Text("This licence is on \(displayCount) Macs")
                    .font(.ostlerH1)
                    .foregroundColor(.ostlerInk)
            }
            Text("Each Ostler licence is valid on up to \(displayMax) Macs. This one is already at the limit, so we cannot register this Mac without freeing up a slot first.")
                .font(.ostlerBody)
                .foregroundColor(.ostlerInkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var explanation: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What you can do")
                .font(.ostlerCaption)
                .foregroundColor(.ostlerInkMuted)

            bullet(
                "Email us at hello@ostler.ai and we will free a slot for you. Quote your licence id below."
            )
            bullet(
                "Or purchase an additional licence at ostler.ai if this is a new Mac you want to keep alongside your other ones."
            )
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.ostlerChassisDeep)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.ostlerHairlineFaint, lineWidth: 1)
        )
    }

    private var actions: some View {
        HStack(spacing: 12) {
            Spacer()
            Button("Quit installer") {
                NSApp.terminate(nil)
            }
            .buttonStyle(.ostlerGhost)
            .keyboardShortcut(.cancelAction)

            Button("Email hello@ostler.ai") {
                openSupportMailto()
            }
            .buttonStyle(.ostlerPrimary)
            .keyboardShortcut(.defaultAction)
        }
    }

    private var footerHint: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Licence id")
                .font(.ostlerCaption)
                .foregroundColor(.ostlerInkMuted)
            Text(licenseId)
                .font(.custom(Font.OstlerFontName.monoRegular, size: 12, relativeTo: .caption))
                .foregroundColor(.ostlerInk)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Helpers

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("•")
                .font(.ostlerBody)
                .foregroundColor(.ostlerInkMuted)
            Text(text)
                .font(.ostlerBody)
                .foregroundColor(.ostlerInk)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var displayCount: String {
        // Worker returns -1 when we could not parse a body; render as
        // "the maximum number of" so the customer is not confronted
        // with nonsensical numbers.
        registeredCount > 0 ? String(registeredCount) : "the maximum number of"
    }

    private var displayMax: String {
        maxFingerprints > 0 ? String(maxFingerprints) : "the licensed number of"
    }

    private func openSupportMailto() {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = "hello@ostler.ai"
        components.queryItems = [
            URLQueryItem(name: "subject", value: "Free up a slot for licence \(licenseId)"),
            URLQueryItem(
                name: "body",
                value: """
                Hi Ostler team,

                I have hit the device limit on my licence and would like to free up a slot so I can install on this Mac.

                Licence id: \(licenseId)

                Thanks.
                """
            ),
        ]
        if let url = components.url {
            NSWorkspace.shared.open(url)
        }
    }
}
