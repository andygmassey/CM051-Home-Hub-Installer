// DeviceLimitReachedView.swift
//
// Shown when the Worker rejected this Mac's registration because the
// licence has already been used on its `max_hardware_fingerprints`
// slots. The view is a hard stop -- the install does not proceed.
//
// Two affordances:
//   - "Email support@ostler.ai" opens a mailto: that includes the licence
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
                Text(ViewCopy.shared.string(
                    for: "device_limit.heading",
                    fills: ["count": displayCount]
                ))
                    .font(.ostlerH1)
                    .foregroundColor(.ostlerInk)
            }
            Text(ViewCopy.shared.string(
                for: "device_limit.explanation",
                fills: ["max": displayMax]
            ))
                .font(.ostlerBody)
                .foregroundColor(.ostlerInkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var explanation: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(ViewCopy.shared.string(for: "device_limit.what_you_can_do_caption"))
                .font(.ostlerCaption)
                .foregroundColor(.ostlerInkMuted)

            bullet(
                ViewCopy.shared.string(for: "device_limit.bullet_email_us")
            )
            bullet(
                ViewCopy.shared.string(for: "device_limit.bullet_buy_another")
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
            Button(ViewCopy.shared.string(for: "device_limit.quit_button")) {
                NSApp.terminate(nil)
            }
            .buttonStyle(.ostlerGhost)
            .keyboardShortcut(.cancelAction)

            Button(ViewCopy.shared.string(for: "device_limit.email_button")) {
                openSupportMailto()
            }
            .buttonStyle(.ostlerPrimary)
            .keyboardShortcut(.defaultAction)
        }
    }

    private var footerHint: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(ViewCopy.shared.string(for: "device_limit.license_id_caption"))
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
        registeredCount > 0 ? String(registeredCount)
                            : ViewCopy.shared.string(for: "device_limit.fallback_count")
    }

    private var displayMax: String {
        maxFingerprints > 0 ? String(maxFingerprints)
                            : ViewCopy.shared.string(for: "device_limit.fallback_max")
    }

    private func openSupportMailto() {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = "support@ostler.ai"
        components.queryItems = [
            URLQueryItem(
                name: "subject",
                value: ViewCopy.shared.string(
                    for: "device_limit.mailto_subject",
                    fills: ["license_id": licenseId]
                )
            ),
            URLQueryItem(
                name: "body",
                value: ViewCopy.shared.string(
                    for: "device_limit.mailto_body",
                    fills: ["license_id": licenseId]
                )
            ),
        ]
        if let url = components.url {
            NSWorkspace.shared.open(url)
        }
    }
}
