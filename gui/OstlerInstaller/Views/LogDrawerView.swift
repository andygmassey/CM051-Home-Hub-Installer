// LogDrawerView.swift
//
// Collapsible bottom panel that streams every #OSTLER LOG line plus
// raw stdout/stderr (in dev mode, cmd-shift-D toggle).
// Auto-scrolls to the bottom.

import SwiftUI

struct LogDrawerView: View {
    @EnvironmentObject private var coordinator: InstallerCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: .ostlerSpace2) {
                Image(systemName: "terminal")
                    .foregroundStyle(Color.ostlerChassis.opacity(0.85))
                Text("LOG")
                    .font(.ostlerStrap)
                    .tracking(2.0)
                    .foregroundStyle(Color.ostlerChassis.opacity(0.85))
                Spacer()
                Toggle("Verbose", isOn: $coordinator.devModeRawLog)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .tint(.ostlerOxbloodWarm)
                    .foregroundStyle(Color.ostlerChassis.opacity(0.75))
            }
            .padding(.horizontal, .ostlerSpace3)
            .padding(.vertical, .ostlerSpace2)
            .background(Color.ostlerInk)

            Rectangle()
                .fill(Color.ostlerChassis.opacity(0.08))
                .frame(height: 1)

            ScrollViewReader { reader in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(coordinator.logLines) { line in
                            HStack(alignment: .firstTextBaseline, spacing: .ostlerSpace2) {
                                Text(timeString(line.timestamp))
                                    .font(.ostlerMonoSm)
                                    .foregroundStyle(Color.ostlerChassis.opacity(0.45))
                                Text(line.text)
                                    .font(.ostlerMono)
                                    .foregroundStyle(colour(for: line.level))
                                    .textSelection(.enabled)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, .ostlerSpace3)
                            .id(line.id)
                        }
                    }
                    .padding(.vertical, .ostlerSpace1)
                }
                .onChange(of: coordinator.logLines.count) { _, _ in
                    if let last = coordinator.logLines.last {
                        withAnimation(.linear(duration: 0.1)) {
                            reader.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .background(Color.ostlerInk)
    }

    private func timeString(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: d)
    }

    private func colour(for level: String) -> Color {
        switch level {
        case "warn": return Color.ostlerOxbloodWarm.opacity(0.95)
        case "error": return Color(red: 0xE6/255, green: 0x6A/255, blue: 0x6A/255)
        default: return Color.ostlerChassis.opacity(0.92)
        }
    }
}
