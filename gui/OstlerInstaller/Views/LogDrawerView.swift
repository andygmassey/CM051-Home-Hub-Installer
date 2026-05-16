// LogDrawerView.swift
//
// Collapsible bottom panel that streams every #OSTLER LOG line plus
// raw stdout/stderr (in dev mode, cmd-shift-D toggle).
// Auto-scrolls to the bottom.
//
// Text selection: every log row carries .textSelection(.enabled) on
// the row's whole HStack so the customer can drag-select across the
// timestamp + message and copy them together (cmd-C). A "Copy log"
// button in the header grabs the full buffer at once for support
// emails -- AppKit NSPasteboard write because SwiftUI does not expose
// a programmatic-copy primitive that works for off-screen lines.

import AppKit
import SwiftUI

struct LogDrawerView: View {
    @EnvironmentObject private var coordinator: InstallerCoordinator

    /// Brief "Copied" pulse on the header button so the user gets
    /// confirmation that the pasteboard now carries the buffer.
    @State private var copyConfirmActive: Bool = false

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
                Button(action: copyAllLogLines) {
                    Label(copyConfirmActive ? "Copied" : "Copy log",
                          systemImage: copyConfirmActive ? "checkmark" : "doc.on.doc")
                        .labelStyle(.titleAndIcon)
                        .font(.ostlerStrap)
                        .tracking(1.4)
                }
                .buttonStyle(.borderless)
                .controlSize(.mini)
                .foregroundStyle(Color.ostlerChassis.opacity(copyConfirmActive ? 0.95 : 0.75))
                .disabled(coordinator.logLines.isEmpty)
                .help("Copy the whole log buffer to the clipboard")
                .keyboardShortcut("c", modifiers: [.command, .shift])

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
                                Spacer(minLength: 0)
                            }
                            // .textSelection on the whole HStack so a
                            // drag-select grabs the timestamp + the
                            // message together. Pre-#344 selection
                            // only covered the message Text and
                            // timestamps had to be retyped when
                            // emailing support.
                            .textSelection(.enabled)
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

    /// Copies the full in-memory log buffer to the system pasteboard.
    /// Each line is rendered as `HH:mm:ss  [LEVEL] message` so a
    /// pasted support email is grep-friendly without further surgery.
    private func copyAllLogLines() {
        Self.formatBuffer(coordinator.logLines).copyToPasteboard()
        copyConfirmActive = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            copyConfirmActive = false
        }
    }
}

// MARK: - Buffer formatting (split out so the unit tests can exercise
// the exact bytes the pasteboard receives without standing up a SwiftUI
// host).

extension LogDrawerView {
    static func formatBuffer(_ lines: [InstallerCoordinator.LogLine]) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return lines.map { line in
            let level = line.level.uppercased().padding(
                toLength: 5,
                withPad: " ",
                startingAt: 0
            )
            return "\(formatter.string(from: line.timestamp))  [\(level)] \(line.text)"
        }.joined(separator: "\n")
    }
}

private extension String {
    func copyToPasteboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(self, forType: .string)
    }
}
