// LogDrawerView.swift
//
// Collapsible bottom panel that streams every #OSTLER LOG line.
// Auto-scrolls to the bottom. Raw stdout/stderr from install.sh
// sub-tools (ollama / docker / pip) is captured via os_log under
// subsystem `ai.ostler.installer`, category `subprocess` -- visible
// to engineers via `log show` but not surfaced in this drawer.
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
                Text(ViewCopy.shared.string(for: "log_drawer.header_label"))
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

                // F7 (Studio retest #2 2026-05-20): the Verbose toggle
                // used to live next to Copy log but did nothing
                // useful for the customer -- it gated the raw-line
                // firehose (`devModeRawLog`) which is dev-only
                // signal that drowns the curated LOG markers in
                // ollama / docker / pip chatter. Andy: "best to
                // remove if we're not going to implement anything
                // for it, as it doesn't sit that well visually
                // next to the Copy function". `devModeRawLog`
                // stays in the coordinator as default-false; the
                // `os_log` subprocess category (LogDrawerView.swift
                // pre-#348 + InstallerCoordinator `OstlerLog.subprocess`
                // calls) keeps the full stream available via
                // `log show --predicate 'subsystem == "ai.ostler.installer"'`
                // for engineers debugging a customer install.
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
        return formatBuffer(lines, errorCode: nil)
    }

    /// CX-17 (2026-05-23): when the install failed with a stable
    /// error code from `fail_with_code`, prepend a Reference line
    /// to the buffer so it is the FIRST thing support sees in the
    /// pasted log -- right next to the timestamps. The catalogue
    /// key `install_failed_banner.error_code_prefix` controls the
    /// label so a translated catalogue ("Référence") drives the
    /// header text without code edits.
    static func formatBuffer(
        _ lines: [InstallerCoordinator.LogLine],
        errorCode: String?
    ) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let body = lines.map { line in
            let level = line.level.uppercased().padding(
                toLength: 5,
                withPad: " ",
                startingAt: 0
            )
            return "\(formatter.string(from: line.timestamp))  [\(level)] \(line.text)"
        }.joined(separator: "\n")
        if let code = errorCode, !code.isEmpty {
            let prefix = ViewCopy.shared.string(for: "install_failed_banner.error_code_prefix")
            return "\(prefix): \(code)\n\n\(body)"
        }
        return body
    }
}

private extension String {
    func copyToPasteboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(self, forType: .string)
    }
}
