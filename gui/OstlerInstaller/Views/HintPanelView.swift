// HintPanelView.swift
//
// Main content area: title + "why" copy for the current step,
// plus the long-running tip if elapsed > threshold. Phase 1 is
// text-only; Phase 2 swaps in per-step illustrations.

import SwiftUI

struct HintPanelView: View {
    @EnvironmentObject private var coordinator: InstallerCoordinator
    @State private var stepStartedAt = Date()
    @State private var ticker = Date()

    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        // CX-49 (DMG #30, 2026-05-24): when the install finishes ok,
        // swap the generic "Quick sanity pass" Health Check placeholder
        // out for a proper affirmative completion view. Customers in
        // Studio retest #24/#25 explicitly asked for a confirmed positive
        // check + summary in the main window when everything is done.
        // The fail-state path continues to fall through to the existing
        // step-and-error rendering below.
        if coordinator.finished == .ok {
            InstallCompleteView()
                .environmentObject(coordinator)
        } else {
            mainBody
        }
    }

    @ViewBuilder
    private var mainBody: some View {
        let meta = StepCatalog.shared.meta(for: coordinator.currentStepId ?? "")

        VStack(alignment: .leading, spacing: .ostlerSpace4) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: .ostlerSpace1) {
                    Text(coordinator.phase.uppercased())
                        .font(.ostlerStrap)
                        .tracking(1.6)
                        .foregroundStyle(Color.ostlerInkMuted)
                    Text(meta?.title ?? coordinator.currentStepTitle)
                        .font(.ostlerH1)
                        .tracking(-0.4)
                        .foregroundStyle(Color.ostlerInk)
                    if let subtitle = meta?.subtitle {
                        Text(subtitle)
                            .font(.ostlerBodyLg)
                            .foregroundStyle(Color.ostlerInkMuted)
                    }
                }
                Spacer()
                // CX-38 (DMG #27, 2026-05-24): only show the per-step
                // percentage during the active install phase. Pre-fix,
                // currentStepPercent could be 100 from a prior step's
                // tail or from cross-phase state, showing "100%" during
                // the questions phase (no install in progress) and
                // around the 3rd-to-last install step (premature) which
                // looked like the installer was lying. Gate on:
                //   - phase contains "Install" (skip questions/license/etc)
                //   - install not yet finished (so we don't dwell on 100%
                //     while later steps run)
                //   - a step is actively in progress (currentStepId != nil)
                //   - the value is > 0
                if coordinator.phase.localizedCaseInsensitiveContains("install"),
                   coordinator.finished == nil,
                   coordinator.currentStepId != nil,
                   coordinator.currentStepPercent > 0 {
                    Text("\(coordinator.currentStepPercent)%")
                        .font(.ostlerMono.monospacedDigit())
                        .foregroundStyle(Color.ostlerInkMuted)
                }
            }

            // Same gate as the text above so the progress bar doesn't
            // sit at full red between steps or during questions.
            if coordinator.phase.localizedCaseInsensitiveContains("install"),
               coordinator.finished == nil,
               coordinator.currentStepId != nil {
                ProgressView(value: Double(coordinator.currentStepPercent),
                             total: 100)
                    .progressViewStyle(.linear)
                    .tint(.ostlerOxblood)
            }

            if let why = meta?.why {
                Text(why)
                    .font(.ostlerBodyLg)
                    .foregroundStyle(Color.ostlerInk)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let tip = longRunningTip(meta: meta) {
                HStack(alignment: .top, spacing: .ostlerSpace2) {
                    Image(systemName: "clock.badge.exclamationmark")
                        .foregroundStyle(Color.ostlerOxbloodWarm)
                    Text(tip)
                        .font(.ostlerBody)
                        .foregroundStyle(Color.ostlerInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(CGFloat.ostlerSpace3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.ostlerOxbloodSoft)
                )
            }

            if let err = coordinator.error {
                HStack(alignment: .top, spacing: .ostlerSpace2) {
                    Image(systemName: "exclamationmark.octagon.fill")
                        .foregroundStyle(Color.ostlerOxblood)
                    Text(err)
                        .font(.ostlerBody)
                        .foregroundStyle(Color.ostlerInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(CGFloat.ostlerSpace3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.ostlerOxbloodSoft)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.ostlerOxblood.opacity(0.35), lineWidth: 1)
                )
            }

            // F4 (Studio retest #2 2026-05-20): surface the most-
            // recent subprocess info message during quiet windows
            // (e.g. the 20s contact-card pre-fill + export pause
            // between perms_ok and user_name). Pre-fix the LOG
            // markers landed in the LogDrawer (hidden by default)
            // and the main content area stayed silent, so Andy
            // thought the installer had hung.
            if let status = coordinator.preInstallStatus,
               !status.isEmpty,
               coordinator.finished == nil,
               coordinator.error == nil {
                HStack(alignment: .center, spacing: .ostlerSpace2) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.ostlerOxblood)
                    Text(status)
                        .font(.ostlerBody)
                        .foregroundStyle(Color.ostlerInk)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
                .padding(CGFloat.ostlerSpace3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.ostlerInkBlueSoft)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.ostlerInkBlue.opacity(0.25), lineWidth: 1)
                )
            }

            // CX-14 D5 (2026-05-23): "Still going, please wait"
            // overlay surfaces when the subprocess has been silent
            // for >= 15s without finishing. Pre-fix the watchdog
            // only logged into the (hidden by default) LogDrawer,
            // so a wedged install looked identical to a slow one.
            // Suppress when a status banner is already showing so
            // the customer sees one progress signal, not two.
            if coordinator.watchdogSilent,
               coordinator.preInstallStatus == nil,
               coordinator.finished == nil,
               coordinator.error == nil {
                HStack(alignment: .center, spacing: .ostlerSpace2) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.ostlerOxblood)
                    Text(ViewCopy.shared.string(
                        for: "hint_panel.watchdog_still_going"
                    ))
                        .font(.ostlerBody)
                        .foregroundStyle(Color.ostlerInk)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
                .padding(CGFloat.ostlerSpace3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.ostlerInkBlueSoft)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.ostlerInkBlue.opacity(0.25), lineWidth: 1)
                )
            }

            Spacer()
        }
        .padding(CGFloat.ostlerSpace4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.ostlerChassis)
        .onChange(of: coordinator.currentStepId) { _, _ in
            stepStartedAt = Date()
        }
        .onReceive(timer) { now in
            ticker = now
        }
    }

    private func longRunningTip(meta: StepMeta?) -> String? {
        guard let copy = meta?.longRunningCopy,
              let threshold = meta?.longRunningThresholdSeconds else { return nil }
        let elapsed = ticker.timeIntervalSince(stepStartedAt)
        return elapsed >= Double(threshold) ? copy : nil
    }
}
