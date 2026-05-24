// InstallCompleteView.swift
//
// CX-49 (DMG #30, 2026-05-24): affirmative completion panel shown
// in the main content area when coordinator.finished == .ok. Replaces
// the generic "Quick sanity pass" Health Check placeholder so the
// customer sees a clear "you're done, everything is up" state
// instead of the same body copy they were reading mid-install.
//
// The per-service tick list reads from coordinator.completedSteps +
// peeks for the health probes' "X healthy" / "X granted" log lines
// so the page reflects the actual health-check outcomes. No data
// flows OFF the Mac to render this view.

import SwiftUI

struct InstallCompleteView: View {
    @EnvironmentObject private var coordinator: InstallerCoordinator

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
                    Text("You're all set")
                        .font(.ostlerH1)
                        .tracking(-0.4)
                        .foregroundStyle(Color.ostlerInk)
                    Text("Ostler is running on this Mac. Everything you need is set up; you can close this window.")
                        .font(.ostlerBodyLg)
                        .foregroundStyle(Color.ostlerInkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, .ostlerSpace2)

            Divider()

            // Per-service summary. Reads from logLines so the panel
            // reflects the actual probes (not a hardcoded list).
            VStack(alignment: .leading, spacing: .ostlerSpace1) {
                Text("Health check")
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

            Divider()

            // Primary CTA + secondary. Open the wiki (the customer's
            // first thing-they-actually-use) and the Ostler Hub.
            // Reveal-in-Finder lives in the bottom toolbar already so
            // we don't repeat it here.
            HStack(spacing: .ostlerSpace2) {
                Button(action: openOstlerHub) {
                    HStack(spacing: .ostlerSpace1) {
                        Image(systemName: "app.dashed")
                        Text("Open Ostler")
                    }
                    .padding(.horizontal, .ostlerSpace3)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(.ostlerOxblood)

                Button(action: openWiki) {
                    HStack(spacing: .ostlerSpace1) {
                        Image(systemName: "book.closed")
                        Text("Open your Wiki")
                    }
                    .padding(.horizontal, .ostlerSpace3)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)

                Spacer()
            }
            .padding(.top, .ostlerSpace2)

            Spacer()
        }
        .padding(CGFloat.ostlerSpace4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.ostlerChassis)
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
