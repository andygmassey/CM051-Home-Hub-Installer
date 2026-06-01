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
//
// CX-128 (2026-06-01): this is the customer's literal first impression
// of Ostler on their Mac, so it reads as a welcome screen, not a bare
// permission gate. It thanks them for buying Ostler, sets the "works
// quietly in the background" expectation, frames the permission asks as
// the cost of that, then introduces Full Disk Access as the first one
// (happening next). The control row matches the house layout every
// other screen uses: ghost on the left, primary action bottom-right
// carrying the default-action keyboard shortcut.

import SwiftUI

struct FullDiskAccessGateView: View {
    @EnvironmentObject private var coordinator: InstallerCoordinator

    // The four Apple data sources Ostler reads, shown as scannable chips
    // so the "what it reads" message lands at a glance rather than buried
    // in prose. Order matches the customer's mental priority.
    private struct DataSource: Identifiable {
        let id = UUID()
        let icon: String
        let labelKey: String
    }
    private let dataSources: [DataSource] = [
        .init(icon: "message.fill",            labelKey: "fda_gate.data_messages"),
        .init(icon: "envelope.fill",           labelKey: "fda_gate.data_mail"),
        .init(icon: "calendar",                labelKey: "fda_gate.data_calendar"),
        .init(icon: "person.crop.circle.fill", labelKey: "fda_gate.data_contacts"),
        .init(icon: "checklist",               labelKey: "fda_gate.data_reminders"),
        .init(icon: "photo.on.rectangle",      labelKey: "fda_gate.data_photos"),
    ]

    var body: some View {
        VStack(spacing: CGFloat.ostlerSpace4) {
            hero
            readsCard
            fullDiskAccessCard
            Spacer(minLength: 0)
            controls
        }
        .padding(.horizontal, CGFloat.ostlerSpace5)
        .padding(.top, CGFloat.ostlerSpace4)
        .padding(.bottom, CGFloat.ostlerSpace4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.ostlerChassis)
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(spacing: CGFloat.ostlerSpace2) {
            OstlerMarque(size: 50)
            Text(ViewCopy.shared.string(for: "fda_gate.heading"))
                .font(.ostlerDisplay)
                .foregroundStyle(Color.ostlerInk)
            Text(ViewCopy.shared.string(for: "fda_gate.welcome"))
                .font(.ostlerBodyLg)
                .foregroundStyle(Color.ostlerInkMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - "What Ostler reads" card

    private var readsCard: some View {
        VStack(alignment: .leading, spacing: CGFloat.ostlerSpace2) {
            Text(ViewCopy.shared.string(for: "fda_gate.reads_lead"))
                .font(.ostlerBodyLg)
                .foregroundStyle(Color.ostlerInk)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: CGFloat.ostlerSpace2) {
                ForEach(dataSources) { source in
                    dataChip(source)
                }
            }

            HStack(spacing: CGFloat.ostlerSpace2) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.ostlerForest)
                Text(ViewCopy.shared.string(for: "fda_gate.privacy_line"))
                    .font(.ostlerCaption)
                    .foregroundStyle(Color.ostlerInkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(CGFloat.ostlerSpace3)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.ostlerPanel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.ostlerHairlineSoft, lineWidth: 1)
        )
    }

    private func dataChip(_ source: DataSource) -> some View {
        VStack(spacing: CGFloat.ostlerSpace1) {
            Image(systemName: source.icon)
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(Color.ostlerOxblood)
            Text(ViewCopy.shared.string(for: source.labelKey))
                .font(.ostlerCaption)
                .foregroundStyle(Color.ostlerInk)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, CGFloat.ostlerSpace3)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.ostlerChassisDeep)
        )
    }

    // MARK: - Full Disk Access card (the first permission, emphasised)

    private var fullDiskAccessCard: some View {
        VStack(alignment: .leading, spacing: CGFloat.ostlerSpace2) {
            HStack(spacing: CGFloat.ostlerSpace2) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(Color.ostlerOxblood)
                Text(ViewCopy.shared.string(for: "fda_gate.upnext_label"))
                    .font(.ostlerH2)
                    .foregroundStyle(Color.ostlerInk)
            }

            VStack(alignment: .leading, spacing: CGFloat.ostlerSpace2) {
                stepRow(1, key: "fda_gate.step_1")
                stepRow(2, key: "fda_gate.step_2")
                stepRow(3, key: "fda_gate.step_3")
            }

            Text(ViewCopy.shared.string(for: "fda_gate.permissions_note"))
                .font(.ostlerCaption)
                .foregroundStyle(Color.ostlerInkMuted)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(CGFloat.ostlerSpace3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.ostlerOxbloodSoft)
        )
    }

    private func stepRow(_ number: Int, key: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: CGFloat.ostlerSpace2) {
            Text("\(number)")
                .font(.ostlerCaption)
                .foregroundStyle(Color.ostlerPanel)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.ostlerOxblood))
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 5 }
            Text(ViewCopy.shared.string(for: key))
                .font(.ostlerBody)
                .foregroundStyle(Color.ostlerInk)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: CGFloat.ostlerSpace3) {
            Button(ViewCopy.shared.string(for: "fda_gate.recheck_button")) {
                coordinator.recheckFullDiskAccessAndProceed()
            }
            .buttonStyle(.ostlerGhost)

            Spacer()

            Button(ViewCopy.shared.string(for: "fda_gate.open_settings_button")) {
                AuthorizationHelper.shared.openFullDiskAccessPane()
            }
            .buttonStyle(.ostlerPrimary)
            .keyboardShortcut(.defaultAction)
        }
    }
}

// MARK: - Ostler marque

/// The Ostler brand mark: an oxblood squircle with a white "O" ring,
/// matching the Ostler.app icon. Drawn in code so it stays crisp at any
/// size and needs no bundled asset.
private struct OstlerMarque: View {
    let size: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(Color.ostlerOxblood)
            .frame(width: size, height: size)
            .overlay(
                Circle()
                    .strokeBorder(Color.ostlerPanel, lineWidth: size * 0.11)
                    .padding(size * 0.26)
            )
    }
}
