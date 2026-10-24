// SystemRequirementsView.swift
//
// F006 (2026-10-24): the first and only screen on a Mac below the
// hardware floor. Same shape as InstallCancelledView: icon + heading,
// body, primary action bottom-right. Shown before anything has been
// asked of the customer, so it says plainly that nothing changed.

import SwiftUI

struct SystemRequirementsView: View {
    @EnvironmentObject private var coordinator: InstallerCoordinator
    let shortfall: SystemRequirements.Shortfall

    private var copy: ViewCopy { ViewCopy.shared }

    /// One line per floor this Mac misses, in the order the body names
    /// them. Internal so a test can assert exactly what is said.
    var detailLines: [String] {
        var lines: [String] = []
        if shortfall.notAppleSilicon {
            lines.append(copy.string(for: "system_requirements.chip_line"))
        }
        if shortfall.memoryTooLow {
            lines.append(copy.string(
                for: "system_requirements.memory_line",
                fills: ["gb": String(shortfall.readings.memoryGB)]
            ))
        }
        if shortfall.macOSTooOld {
            lines.append(copy.string(
                for: "system_requirements.macos_line",
                fills: ["version": shortfall.readings.macOSVersion]
            ))
        }
        return lines
    }

    var body: some View {
        VStack(spacing: 24) {
            HStack(spacing: 12) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 28, weight: .regular))
                    .foregroundColor(.ostlerInkMuted)
                Text(copy.string(for: "system_requirements.heading"))
                    .font(.ostlerH1)
                    .foregroundColor(.ostlerInk)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 12) {
                Text(copy.string(
                    for: "system_requirements.body",
                    fills: [
                        "min_gb": String(SystemRequirements.minimumMemoryGB),
                        "min_macos": String(SystemRequirements.macOSFloorMajor),
                    ]
                ))
                ForEach(detailLines, id: \.self) { line in
                    Text(line)
                }
                Text(copy.string(for: "system_requirements.nothing_changed"))
                    .foregroundColor(.ostlerInkMuted)
            }
            .font(.ostlerBody)
            .foregroundColor(.ostlerInk)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                if let url = URL(string: copy.string(for: "system_requirements.requirements_url")) {
                    Link(copy.string(for: "system_requirements.requirements_link"), destination: url)
                        .font(.ostlerBody)
                }
                Spacer()
                Button(copy.string(for: "system_requirements.quit_button")) {
                    coordinator.quitAction()
                }
                    .buttonStyle(.ostlerPrimary)
                    .keyboardShortcut(.defaultAction)
            }
            Spacer()
        }
        .padding(.horizontal, 48)
        .padding(.vertical, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.ostlerChassis)
    }
}
