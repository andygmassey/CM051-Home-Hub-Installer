// InstallCompleteView.swift
//
// CX-49 (DMG #30, 2026-05-24): affirmative completion panel shown
// in the main content area when coordinator.finished == .ok. Replaces
// the generic "Quick sanity pass" Health Check placeholder so the
// customer sees a clear "you're done, everything is up" state
// instead of the same body copy they were reading mid-install.
//
// CX-56 (DMG ship, 2026-05-24): pairing-QR section added between
// the service tick list + the CTA buttons. The Hub gateway exposes
// a §3.3 envelope at POST http://localhost:8000/admin/paircode
// which we render as a 256x256 QR with an oxblood border. CM031's
// iOS pairing flow scans the QR + verifies the envelope on the iOS
// side. Fetch fires on .task with a Refresh button for retries
// (e.g. gateway not yet up immediately after start-services).
//
// The per-service tick list reads from coordinator.completedSteps +
// peeks for the health probes' "X healthy" / "X granted" log lines
// so the page reflects the actual health-check outcomes. No data
// flows OFF the Mac to render this view.

import SwiftUI
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

struct InstallCompleteView: View {
    @EnvironmentObject private var coordinator: InstallerCoordinator

    // CX-56 pairing-QR state. Stays inside InstallCompleteView so
    // the lifecycle (fetch on appear, refresh on tap) is colocated
    // with the view that owns it; the GatewayClient itself is
    // stateless.
    @State private var pairEnvelope: String? = nil
    @State private var pairFetchInFlight: Bool = false
    @State private var pairFetchError: String? = nil

    private let gatewayClient = GatewayClient()

    // The health probes install.sh runs at the tail of Phase 4. We
    // detect them by scanning logLines for the canonical "X healthy"
    // / "X granted" patterns emitted by install.sh's `ok` calls. If
    // a service didn't tick green during the probe (offline, port
    // collision, optional skip), it's rendered as a warn row so the
    // customer is informed without panicking the success page.
    private struct ServiceCheck: Identifiable {
        let id: String
        let label: String
        let status: StepStatus
    }

    private var serviceChecks: [ServiceCheck] {
        let lines = coordinator.logLines.map { $0.text }
        func ok(_ probe: String) -> Bool {
            lines.contains { $0.localizedCaseInsensitiveContains(probe) }
        }
        return [
            ServiceCheck(id: "qdrant",   label: "Knowledge graph (Qdrant)",
                         status: ok("Qdrant healthy") ? .ok : .warn),
            ServiceCheck(id: "oxigraph", label: "Triple store (Oxigraph)",
                         status: ok("Oxigraph healthy") ? .ok : .warn),
            ServiceCheck(id: "redis",    label: "Cache + message bus (Redis)",
                         status: ok("Redis healthy") ? .ok : .warn),
            ServiceCheck(id: "ollama",   label: "Local AI (Ollama)",
                         status: ok("Ollama healthy") ? .ok : .warn),
            ServiceCheck(id: "vane",     label: "Local web search (Vane)",
                         status: ok("Vane healthy") ? .ok : .warn),
            ServiceCheck(id: "imessage", label: "iMessage automation",
                         status: ok("iMessage Automation permission: granted") ? .ok : .warn),
        ]
    }

    var body: some View {
        // CX-64 (DMG #36, 2026-05-24): wrap the body in a ScrollView so
        // the hero never gets clipped above the viewport when the
        // installer window is shorter than the assembled content.
        // Studio retest #28 had the "You're all set" hero scrolled out
        // of sight: total content runs ~600pt (hero + tick list +
        // pairing QR + CTAs) and the VStack's trailing Spacer was
        // taking the overflow off the TOP, not the bottom. ScrollView
        // gives the content the room it actually needs, with the hero
        // pinned at the top so it's always the first thing the
        // customer sees on a successful install.
        //
        // CX-DMG44 (DMG #44, 2026-05-25): hero is now visible but the
        // primary CTA buttons (Open Ostler / Open your Wiki) sit at
        // the bottom of the scroll content and disappear below the
        // viewport fold on short installer windows. Refactor the
        // layout: ScrollView on top holding hero + tick list + QR;
        // a sticky footer outside the ScrollView holding the CTA
        // buttons. Buttons are now always above the fold regardless
        // of window size. Studio retest #43 found customers didn't
        // realise they could scroll to find the buttons.
        VStack(spacing: 0) {
        ScrollView {
        VStack(alignment: .leading, spacing: .ostlerSpace4) {
            // Hero: large oxblood check + bold heading. Mirrors the
            // sidebar's terminal "Done" footer but at full size so
            // the main content area carries the announcement.
            HStack(alignment: .center, spacing: .ostlerSpace3) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(Color.ostlerForest)
                VStack(alignment: .leading, spacing: .ostlerSpace1) {
                    Text("INSTALL COMPLETE")
                        .font(.ostlerStrap)
                        .tracking(1.6)
                        .foregroundStyle(Color.ostlerInkMuted)
                    Text(ViewCopy.shared.string(for: "install_complete.heading"))
                        .font(.ostlerH1)
                        .tracking(-0.4)
                        .foregroundStyle(Color.ostlerInk)
                    Text(ViewCopy.shared.string(for: "install_complete.subheading"))
                        .font(.ostlerBodyLg)
                        .foregroundStyle(Color.ostlerInkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, .ostlerSpace2)

            Divider()

            // CX-120 (DMG #48s, 2026-05-30): on the green path (all
            // health probes OK) replace the per-service tick list with
            // a what-happens-next panel. The checklist was useful as a
            // diagnostic but most customers don't need it — the real
            // estate is better spent telling them where their data
            // lands, that hydration takes time, and how to get the
            // iOS app. The checklist still renders when any probe is
            // .warn so the customer can spot trouble.
            if serviceChecks.allSatisfy({ $0.status == .ok }) {
                whatsNextSection
            } else {
                healthCheckList
            }

            Divider()

            // CX-56 (DMG ship, 2026-05-24): iOS Companion pairing
            // QR. Sits between the service tick list and the CTA
            // buttons so the customer's last action on the install
            // is "open the iPhone app and scan this". The QR
            // encodes the §3.3 envelope returned by
            // POST http://localhost:8000/admin/paircode.
            pairingSection

            Spacer(minLength: .ostlerSpace2)
        }
        .padding(CGFloat.ostlerSpace4)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        }  // end ScrollView

        // CX-DMG44 sticky footer: Primary CTA + secondary live in a
        // non-scrolling bar pinned to the bottom of the viewport.
        // Always above the fold regardless of installer window size.
        // Reveal-in-Finder lives in the bottom toolbar already so we
        // don't repeat it here.
        Divider()
        HStack(spacing: .ostlerSpace2) {
            Button(action: openOstlerHub) {
                HStack(spacing: .ostlerSpace1) {
                    Image(systemName: "app.dashed")
                    Text(ViewCopy.shared.string(for: "install_complete.open_ostler_button"))
                }
                .padding(.horizontal, .ostlerSpace3)
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(.ostlerOxblood)

            Button(action: openWiki) {
                HStack(spacing: .ostlerSpace1) {
                    Image(systemName: "book.closed")
                    Text(ViewCopy.shared.string(for: "install_complete.open_wiki_button"))
                }
                .padding(.horizontal, .ostlerSpace3)
                .padding(.vertical, 6)
            }
            .buttonStyle(.bordered)

            Spacer()
        }
        .padding(.horizontal, CGFloat.ostlerSpace4)
        .padding(.vertical, CGFloat.ostlerSpace2)
        .background(Color.ostlerChassis)
        }  // end outer VStack
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.ostlerChassis)
        .task {
            // Fire the initial pair-code fetch when the success
            // screen first appears. .task is async, cancels on
            // disappear, and guards against double-fires if the
            // view rebuilds for an unrelated reason.
            await fetchPairCode()
        }
    }

    // ── CX-120 what-happens-next (green-path replacement) ─────────────

    @ViewBuilder
    private var whatsNextSection: some View {
        VStack(alignment: .leading, spacing: .ostlerSpace3) {
            Text(ViewCopy.shared.string(for: "install_complete.whats_next_label"))
                .font(.ostlerStrap)
                .tracking(1.2)
                .foregroundStyle(Color.ostlerInkMuted)

            whatsNextItem(
                icon: "clock.badge",
                titleKey: "install_complete.whats_next_hydration_title",
                bodyKey: "install_complete.whats_next_hydration_body"
            )

            whatsNextItem(
                icon: "iphone",
                titleKey: "install_complete.whats_next_ios_title",
                bodyKey: "install_complete.whats_next_ios_body",
                cta: (
                    titleKey: "install_complete.whats_next_ios_button",
                    action: openAppStorePlaceholder
                )
            )

            whatsNextItem(
                icon: "folder",
                titleKey: "install_complete.whats_next_files_title",
                bodyKey: "install_complete.whats_next_files_body"
            )
        }
        .padding(.vertical, .ostlerSpace1)
    }

    @ViewBuilder
    private func whatsNextItem(
        icon: String,
        titleKey: String,
        bodyKey: String,
        cta: (titleKey: String, action: () -> Void)? = nil
    ) -> some View {
        HStack(alignment: .top, spacing: .ostlerSpace2) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(Color.ostlerOxblood)
                .frame(width: 22, alignment: .center)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text(ViewCopy.shared.string(for: titleKey))
                    .font(.ostlerH2)
                    .foregroundStyle(Color.ostlerInk)
                Text(ViewCopy.shared.string(for: bodyKey))
                    .font(.ostlerBody)
                    .foregroundStyle(Color.ostlerInkMuted)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let cta {
                    Button(action: cta.action) {
                        Text(ViewCopy.shared.string(for: cta.titleKey))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// CX-120 placeholder: until the iOS app is live on the App Store,
    /// the "Download" button opens the marketing page instead. Swap to
    /// the real itms-apps:// deep-link once App Store Connect approves
    /// the binary.
    private func openAppStorePlaceholder() {
        if let url = URL(string: "https://ostler.ai/ios") {
            NSWorkspace.shared.open(url)
        }
    }

    @ViewBuilder
    private var healthCheckList: some View {
        VStack(alignment: .leading, spacing: .ostlerSpace1) {
            Text(ViewCopy.shared.string(for: "install_complete.health_check_label"))
                .font(.ostlerStrap)
                .tracking(1.2)
                .foregroundStyle(Color.ostlerInkMuted)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(serviceChecks) { check in
                    HStack(spacing: .ostlerSpace2) {
                        Image(systemName: check.status == .ok
                              ? "checkmark.circle.fill"
                              : "exclamationmark.triangle.fill")
                            .foregroundStyle(check.status == .ok
                                             ? Color.ostlerForest
                                             : Color.ostlerOxbloodWarm)
                            .frame(width: 18)
                        Text(check.label)
                            .font(.ostlerBody)
                            .foregroundStyle(Color.ostlerInk)
                        Spacer()
                        Text(check.status == .ok ? "OK" : "see log")
                            .font(.ostlerCaption)
                            .foregroundStyle(Color.ostlerInkSubdued)
                    }
                }
            }
            .padding(.vertical, .ostlerSpace1)
        }
    }

    // ── CX-56 pairing QR ──────────────────────────────────────────

    @ViewBuilder
    private var pairingSection: some View {
        VStack(alignment: .leading, spacing: .ostlerSpace2) {
            Text(ViewCopy.shared.string(for: "pair_iphone.title"))
                .font(.ostlerStrap)
                .tracking(1.2)
                .foregroundStyle(Color.ostlerInkMuted)

            HStack(alignment: .center, spacing: .ostlerSpace3) {
                // QR panel. Always reserves a 144x144 box so the
                // layout doesn't jump between loading + loaded.
                pairingQRPanel
                    .frame(width: 144, height: 144)

                VStack(alignment: .leading, spacing: .ostlerSpace1) {
                    Text(ViewCopy.shared.string(for: "pair_iphone.help"))
                        .font(.ostlerBody)
                        .foregroundStyle(Color.ostlerInk)
                        .fixedSize(horizontal: false, vertical: true)

                    if let err = pairFetchError {
                        Text(err)
                            .font(.ostlerCaption)
                            .foregroundStyle(Color.ostlerOxbloodWarm)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(spacing: .ostlerSpace2) {
                        Button(action: { Task { await fetchPairCode() } }) {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.clockwise")
                                Text(ViewCopy.shared.string(for: "pair_iphone.refresh_button"))
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(pairFetchInFlight)
                        Spacer()
                    }
                }
            }
        }
        .padding(.vertical, .ostlerSpace1)
    }

    @ViewBuilder
    private var pairingQRPanel: some View {
        ZStack {
            // Oxblood-tinted border that matches the brand.
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.ostlerOxblood.opacity(0.5), lineWidth: 2)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white)
                )

            if let envelope = pairEnvelope, !envelope.isEmpty,
               let qrImage = Self.makeQRImage(payload: envelope, size: 128) {
                Image(nsImage: qrImage)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .padding(8)
            } else if pairFetchInFlight {
                VStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.ostlerOxblood)
                    Text(ViewCopy.shared.string(for: "pair_iphone.fetching"))
                        .font(.ostlerCaption)
                        .foregroundStyle(Color.ostlerInkMuted)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 4)
                }
            } else {
                // Error or empty state: show a muted QR-glyph
                // placeholder so the layout doesn't read as blank.
                Image(systemName: "qrcode")
                    .font(.system(size: 56))
                    .foregroundStyle(Color.ostlerInkSubdued)
            }
        }
    }

    @MainActor
    private func fetchPairCode() async {
        guard !pairFetchInFlight else { return }
        pairFetchInFlight = true
        pairFetchError = nil
        defer { pairFetchInFlight = false }

        do {
            let envelope = try await gatewayClient.fetchPairCodeEnvelope()
            if envelope.isEmpty {
                pairFetchError = ViewCopy.shared.string(for: "pair_iphone.fetch_failed")
                pairEnvelope = nil
            } else {
                pairEnvelope = envelope
                pairFetchError = nil
            }
        } catch {
            pairFetchError = ViewCopy.shared.string(for: "pair_iphone.fetch_failed")
            pairEnvelope = nil
        }
    }

    /// Render a CoreImage QR code for the given payload at the
    /// requested integer pixel size. Uses
    /// CIFilter.qrCodeGenerator() with a high error-correction
    /// level (Q = 25%) so the printed QR survives shutter blur on
    /// the iPhone camera + scuffs on a printed sheet. Returns nil
    /// when CoreImage fails to render (extremely rare; defensive
    /// guard so the panel falls through to the placeholder rather
    /// than crashing).
    static func makeQRImage(payload: String, size: CGFloat) -> NSImage? {
        let data = Data(payload.utf8)
        let filter = CIFilter.qrCodeGenerator()
        filter.message = data
        // Q = 25% error correction. The §3.3 envelope is typically
        // 200-400 bytes so the QR ends up at version 8-12; Q keeps
        // it scannable in the wild.
        filter.correctionLevel = "Q"
        guard let output = filter.outputImage else { return nil }

        // Scale up to the target size with nearest-neighbour so the
        // pixels stay crisp on Retina + non-Retina displays. The
        // generator emits a tiny image (~33x33 for a v4 code); we
        // need to upscale by an integer factor.
        let extent = output.extent
        guard extent.width > 0, extent.height > 0 else { return nil }
        let scale = size / extent.width
        let transformed = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        let context = CIContext(options: nil)
        guard let cgImage = context.createCGImage(transformed, from: transformed.extent) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: size, height: size))
    }

    private func openOstlerHub() {
        if let url = URL(string: "file:///Applications/Ostler.app") {
            NSWorkspace.shared.open(url)
        }
    }

    private func openWiki() {
        if let url = URL(string: "http://localhost:8044") {
            NSWorkspace.shared.open(url)
        }
    }
}
