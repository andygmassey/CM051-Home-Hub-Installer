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

        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(coordinator.phase)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(meta?.title ?? coordinator.currentStepTitle)
                        .font(.title2.weight(.semibold))
                    if let subtitle = meta?.subtitle {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if coordinator.currentStepPercent > 0 {
                    Text("\(coordinator.currentStepPercent)%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            ProgressView(value: Double(coordinator.currentStepPercent),
                         total: 100)
                .progressViewStyle(.linear)

            if let why = meta?.why {
                Text(why)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let tip = longRunningTip(meta: meta) {
                HStack(spacing: 8) {
                    Image(systemName: "clock.badge.exclamationmark")
                        .foregroundStyle(.yellow)
                    Text(tip)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(8)
                .background(.yellow.opacity(0.1))
                .cornerRadius(8)
            }

            if let err = coordinator.error {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.octagon.fill")
                        .foregroundStyle(.red)
                    Text(err)
                        .font(.callout)
                }
                .padding(8)
                .background(.red.opacity(0.1))
                .cornerRadius(8)
            }

            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
