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
            HStack {
                Image(systemName: "terminal")
                Text("Log")
                    .font(.caption.weight(.semibold))
                Spacer()
                Toggle("Verbose", isOn: $coordinator.devModeRawLog)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.thinMaterial)

            Divider()

            ScrollViewReader { reader in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(coordinator.logLines) { line in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(timeString(line.timestamp))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                Text(line.text)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(colour(for: line.level))
                                    .textSelection(.enabled)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 12)
                            .id(line.id)
                        }
                    }
                    .padding(.vertical, 4)
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
        .background(Color(NSColor.textBackgroundColor))
    }

    private func timeString(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: d)
    }

    private func colour(for level: String) -> Color {
        switch level {
        case "warn": return .orange
        case "error": return .red
        default: return .primary
        }
    }
}
