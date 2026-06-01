// FullDiskAccessGateView.swift
//
// CX-87 (2026-06-01): front-loaded Full Disk Access gate. This is the
// VERY FIRST screen (after self-relocation to /Applications) whenever
// the installer bundle does not yet have Full Disk Access.
//
// WHY this exists: macOS requires the app to quit and reopen after FDA
// is switched on (the new TCC grant is only picked up on relaunch).
// Previously FDA was a *reactive* gate -- install.sh emitted NEEDS_FDA
// part-way through, so the quit-and-reopen landed mid-flow and the
// relaunch took the "previous installation" reuse path, silently
// skipping the unfinished tail of Phase 2 (channel choice, consent,
// the iMessage Automation prompt). By demanding FDA up-front, the whole
// setup runs exactly ONCE on the post-grant launch: no mid-install
// interruption, no reuse-skip, nothing asked twice.
//
// The old FullDiskAccessSheet stays as a defensive fallback for the
// rare case a later step still needs a grant the customer revoked.

import SwiftUI

struct FullDiskAccessGateView: View {
    @EnvironmentObject private var coordinator: InstallerCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: CGFloat.ostlerSpace3) {
            HStack(alignment: .top, spacing: CGFloat.ostlerSpace3) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 40, weight: .regular))
                    .foregroundStyle(Color.ostlerOxblood)
                VStack(alignment: .leading, spacing: CGFloat.ostlerSpace1) {
                    Text(ViewCopy.shared.string(for: "fda_gate.heading"))
                        .font(.ostlerH1)
                        .foregroundStyle(Color.ostlerInk)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(ViewCopy.shared.string(for: "fda_gate.body"))
                        .font(.ostlerBody)
                        .foregroundStyle(Color.ostlerInkMuted)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(ViewCopy.shared.string(for: "fda_gate.steps"))
                .font(.ostlerBody)
                .foregroundStyle(Color.ostlerInk)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer()

            HStack(spacing: CGFloat.ostlerSpace3) {
                Button(ViewCopy.shared.string(for: "fda_gate.open_settings_button")) {
                    AuthorizationHelper.shared.openFullDiskAccessPane()
                }
                .buttonStyle(.ostlerPrimary)
                .keyboardShortcut(.defaultAction)

                Button(ViewCopy.shared.string(for: "fda_gate.recheck_button")) {
                    coordinator.recheckFullDiskAccessAndProceed()
                }
                .buttonStyle(.ostlerGhost)

                Spacer()
            }
        }
        .padding(.horizontal, CGFloat.ostlerSpace5)
        .padding(.vertical, CGFloat.ostlerSpace4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.ostlerChassis)
    }
}
