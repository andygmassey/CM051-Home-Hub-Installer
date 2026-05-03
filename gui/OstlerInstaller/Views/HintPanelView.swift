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
                if coordinator.currentStepPercent > 0 {
                    Text("\(coordinator.currentStepPercent)%")
                        .font(.ostlerMono.monospacedDigit())
                        .foregroundStyle(Color.ostlerInkMuted)
                }
            }

            ProgressView(value: Double(coordinator.currentStepPercent),
                         total: 100)
                .progressViewStyle(.linear)
                .tint(.ostlerOxblood)

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
