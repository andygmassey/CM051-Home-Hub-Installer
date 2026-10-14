// PermissionsIntroView.swift
//
// CX-17 (2026-05-23). Intro screen rendered BEFORE the
// PermissionsPrewarmer fires.
//
// PROBLEM: Studio retest log 14:14:00 showed all four macOS TCC
// dialogs (Contacts / Calendar / Reminders / Photos) appearing AND
// being granted/denied in the same second. The concurrent burst
// meant the popups stacked behind each other; Andy did not see the
// Calendar / Photos dialogs at all, ended up with two silent
// denies, and would have allowed them if he had seen them.
//
// FIX (per CX-17 brief): split the fix across this intro screen
// and the SERIAL request loop in PermissionsPrewarmer.
//   - This view explains "four macOS dialogs are about to appear"
//     and names each one with a one-liner WHY explanation. It
//     gives the customer one beat of context BEFORE the macOS
//     dialogs land, so the system focus race never has to win.
//   - A primary "Grant permissions" button drives the actual
//     pre-warm via `coordinator.beginPermissionsPrewarm()`.
//   - A secondary "Skip for now" button lets the customer defer
//     all four prompts; they can grant later in System Settings.
//     install.sh has skip-on-deny fallbacks everywhere, so a
//     skipped pre-warm still produces a working (if reduced)
//     install.
//
// RENDER POSITION: this view replaces `installLayout` (and the
// licence + admin gates) as the FIRST customer-facing screen --
// the macOS TCC dialogs must fire BEFORE the licence flow because
// the install.sh subprocess inherits the parent-bundle TCC grants
// and we want them already settled. After this view dismisses
// (either via Grant or Skip + summary acknowledgement), the
// existing licence + admin acknowledgement flow takes over.
//
// CATALOGUE: every customer-facing string here resolves via
// `ViewCopy.shared.string(for: "permissions_prewarm.*")` per Rule
// 0.9. The PermissionsIntroCatalogueKeysTest walks this file +
// asserts every string render goes through the catalogue.

import SwiftUI

struct PermissionsIntroView: View {
    @EnvironmentObject private var coordinator: InstallerCoordinator

    var body: some View {
        Group {
            switch coordinator.permissionsIntroState {
            case .intro, .requesting:
                introBody
            case .summary(let denials):
                summaryBody(denials: denials)
            case .complete, .skipped:
                // Should never render; ContentView gates this view
                // away as soon as the state leaves .intro / .requesting
                // / .summary. Defensive empty view rather than a
                // crash.
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.ostlerChassis)
    }

    // MARK: - Intro body

    private var introBody: some View {
        VStack(alignment: .leading, spacing: CGFloat.ostlerSpace3) {
            HStack(spacing: CGFloat.ostlerSpace2) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 28, weight: .regular))
                    .foregroundStyle(Color.ostlerOxblood)
                Text(ViewCopy.shared.string(for: "permissions_prewarm.intro_heading"))
                    .font(.ostlerH1)
                    .foregroundStyle(Color.ostlerInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(ViewCopy.shared.string(for: "permissions_prewarm.intro_subheading"))
                .font(.ostlerBody)
                .foregroundStyle(Color.ostlerInk)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: CGFloat.ostlerSpace2) {
                ForEach(PermissionsPrewarmer.requestOrder, id: \.self) { p in
                    permissionRow(p)
                }
            }
            .padding(.vertical, CGFloat.ostlerSpace2)

            Text(ViewCopy.shared.string(for: "permissions_prewarm.intro_privacy_note"))
                .font(.ostlerCaption)
                .foregroundStyle(Color.ostlerInkMuted)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer()

            HStack(spacing: CGFloat.ostlerSpace3) {
                Button(ViewCopy.shared.string(for: "permissions_prewarm.intro_skip_button")) {
                    coordinator.skipPermissionsPrewarm()
                }
                .buttonStyle(.ostlerGhost)
                .disabled(coordinator.permissionsIntroState == .requesting)

                Spacer()

                Button(action: { coordinator.beginPermissionsPrewarm() }) {
                    // CX-127: while the serial TCC pre-warm runs (the
                    // four macOS dialogs fire 800ms apart, several
                    // seconds of otherwise-silent wait), show a spinner
                    // + "Requesting access" label so the tap reads as
                    // taken. The earlier spinner fix landed on the
                    // admin-auth button, not this one -- this is the
                    // button the customer taps first after the FDA
                    // relaunch, so it is where the feedback belongs.
                    if coordinator.permissionsIntroState == .requesting {
                        HStack(spacing: CGFloat.ostlerSpace1) {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                            Text(ViewCopy.shared.string(for: "permissions_prewarm.intro_grant_button_requesting"))
                        }
                    } else {
                        Text(ViewCopy.shared.string(for: "permissions_prewarm.intro_grant_button"))
                    }
                }
                .buttonStyle(.ostlerPrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(coordinator.permissionsIntroState == .requesting)
            }
        }
        .padding(.horizontal, CGFloat.ostlerSpace5)
        .padding(.vertical, CGFloat.ostlerSpace4)
    }

    private func permissionRow(_ permission: PrewarmPermission) -> some View {
        let (titleKey, reasonKey) = catalogueKeys(for: permission)
        return HStack(alignment: .firstTextBaseline, spacing: CGFloat.ostlerSpace2) {
            Image(systemName: iconName(for: permission))
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(Color.ostlerOxblood)
                .frame(width: 18, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text(ViewCopy.shared.string(for: titleKey))
                    .font(.ostlerH2)
                    .foregroundStyle(Color.ostlerInk)
                Text(ViewCopy.shared.string(for: reasonKey))
                    .font(.ostlerBody)
                    .foregroundStyle(Color.ostlerInkMuted)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private func catalogueKeys(for permission: PrewarmPermission) -> (title: String, reason: String) {
        let base = "permissions_prewarm.intro_\(permission.rawValue)"
        return ("\(base)_title", "\(base)_reason")
    }

    private func iconName(for permission: PrewarmPermission) -> String {
        switch permission {
        case .contacts:  return "person.crop.circle"
        case .calendar:  return "calendar"
        case .reminders: return "checklist"
        case .photos:    return "photo.on.rectangle"
        }
    }

    // MARK: - Summary body (denials)

    @ViewBuilder
    private func summaryBody(denials: [PrewarmPermission]) -> some View {
        VStack(alignment: .leading, spacing: CGFloat.ostlerSpace3) {
            HStack(spacing: CGFloat.ostlerSpace2) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 24, weight: .regular))
                    .foregroundStyle(Color.ostlerOxblood)
                Text(ViewCopy.shared.string(for: "permissions_prewarm.denial_summary_heading"))
                    .font(.ostlerH1)
                    .foregroundStyle(Color.ostlerInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: CGFloat.ostlerSpace2) {
                ForEach(denials, id: \.self) { p in
                    denialRow(p)
                }
            }
            .padding(.vertical, CGFloat.ostlerSpace2)

            Text(ViewCopy.shared.string(for: "permissions_prewarm.denial_summary_footer"))
                .font(.ostlerCaption)
                .foregroundStyle(Color.ostlerInkMuted)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer()

            HStack(spacing: CGFloat.ostlerSpace3) {
                Spacer()
                Button(ViewCopy.shared.string(for: "permissions_prewarm.denial_continue_button")) {
                    coordinator.acknowledgePermissionsDenialSummary()
                }
                .buttonStyle(.ostlerPrimary)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, CGFloat.ostlerSpace5)
        .padding(.vertical, CGFloat.ostlerSpace4)
    }

    private func denialRow(_ permission: PrewarmPermission) -> some View {
        // Re-use the existing per-permission denied copy: it already
        // names the System Settings path, which is exactly the
        // CX-17 brief ask ("surface a one-line note BEFORE the
        // install starts").
        let key = "permissions_prewarm.\(permission.rawValue)_denied"
        return HStack(alignment: .firstTextBaseline, spacing: CGFloat.ostlerSpace2) {
            Image(systemName: "minus.circle")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(Color.ostlerOxblood)
                .frame(width: 18, alignment: .center)
            Text(ViewCopy.shared.string(for: key))
                .font(.ostlerBody)
                .foregroundStyle(Color.ostlerInk)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
