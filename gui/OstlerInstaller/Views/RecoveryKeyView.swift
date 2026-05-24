// RecoveryKeyView.swift
//
// CX-53 (DMG ship, 2026-05-24). Recovery-key reveal sheet rendered
// over InstallCompleteView when install.sh emits the RECOVERY_KEY
// marker. The TTY install.sh path (line 7574-onwards) already echoes
// the recovery key in YELLOW BOLD to the terminal; GUI customers
// previously got "Recovery key saved to Keychain" with no surface to
// see the actual value. If their Keychain ever wobbles, they're
// locked out for good (we cannot recover it server-side -- the key
// is the SOLE input to AES-GCM-derived unlock material).
//
// This sheet shows the key in monospace, with Copy / Save PDF / Print
// controls and a confirm checkbox + Continue button. Customer must
// tick the checkbox to enable Continue; once they click Continue the
// sheet dismisses + the underlying InstallCompleteView is usable.
//
// SECURITY NOTES:
//   - The key value is read from `coordinator.recoveryKey` which is
//     populated by the structured RECOVERY_KEY marker parser. It is
//     NEVER routed into `logLines` (which is rendered in the visible
//     Log drawer) -- see InstallerCoordinator `case .recoveryKey`
//     handler comment.
//   - Print + Save PDF render the value to a CGContext, which is
//     fine on macOS (the print dialog runs in-process and never
//     spools to a remote service unless the customer picks one).
//   - Copy puts the value on the general pasteboard; no expiry.
//     macOS Universal Clipboard could ferry this to another Apple
//     device on the same iCloud account, but that's the same
//     security posture as the customer typing the value into their
//     password manager (which we explicitly recommend).
//
// Strings: route through ViewCopy.shared.string(for: "recovery_key_reveal.*")
// per Rule 0.9 (locked 2026-05-19).

import SwiftUI
import AppKit

struct RecoveryKeyView: View {
    @EnvironmentObject private var coordinator: InstallerCoordinator
    /// Local copy-confirmation toast. Surfaces below the buttons for
    /// 2 seconds after Copy is pressed so the customer gets feedback
    /// even when the button does not visually change.
    @State private var copiedToastVisible: Bool = false
    /// Whether the customer has ticked "I've saved this somewhere
    /// safe". Drives the Continue button's disabled state so a
    /// careless dismiss-on-empty-acknowledgement never happens.
    @State private var savedConfirmed: Bool = false

    /// The key value, sourced from the coordinator. Empty when the
    /// view is rendered for layout previews; the actual reveal flow
    /// never presents the sheet unless `coordinator.recoveryKey` has
    /// a non-empty value (gated by .sheet(isPresented:) in
    /// InstallCompleteView).
    private var recoveryKey: String {
        coordinator.recoveryKey ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: .ostlerSpace3) {
            // Hero: shield icon + heading.
            HStack(alignment: .top, spacing: .ostlerSpace3) {
                Image(systemName: "key.horizontal.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(Color.ostlerOxblood)
                VStack(alignment: .leading, spacing: .ostlerSpace1) {
                    Text(ViewCopy.shared.string(for: "recovery_key_reveal.heading"))
                        .font(.ostlerH2)
                        .tracking(-0.2)
                        .foregroundStyle(Color.ostlerInk)
                    Text(ViewCopy.shared.string(for: "recovery_key_reveal.body"))
                        .font(.ostlerBody)
                        .foregroundStyle(Color.ostlerInkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // Big monospace reveal of the key. textSelection enables
            // drag-select for customers who prefer to copy a region
            // manually rather than the Copy button.
            VStack(alignment: .leading, spacing: .ostlerSpace1) {
                Text(recoveryKey)
                    .font(.system(.title3, design: .monospaced).weight(.semibold))
                    .foregroundStyle(Color.ostlerInk)
                    .textSelection(.enabled)
                    .padding(CGFloat.ostlerSpace3)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.ostlerChassisDeep)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.ostlerOxblood.opacity(0.35), lineWidth: 1)
                    )
            }

            // Action row: Copy / Save PDF / Print.
            HStack(spacing: .ostlerSpace2) {
                Button(action: copyToClipboard) {
                    HStack(spacing: .ostlerSpace1) {
                        Image(systemName: "doc.on.doc")
                        Text(ViewCopy.shared.string(for: "recovery_key_reveal.copy_button"))
                    }
                }
                .buttonStyle(.ostlerGhost)

                Button(action: saveAsPDF) {
                    HStack(spacing: .ostlerSpace1) {
                        Image(systemName: "square.and.arrow.down")
                        Text(ViewCopy.shared.string(for: "recovery_key_reveal.save_pdf_button"))
                    }
                }
                .buttonStyle(.ostlerGhost)

                Button(action: printRecoveryKey) {
                    HStack(spacing: .ostlerSpace1) {
                        Image(systemName: "printer")
                        Text(ViewCopy.shared.string(for: "recovery_key_reveal.print_button"))
                    }
                }
                .buttonStyle(.ostlerGhost)

                Spacer()
            }

            // Inline copy-confirmation toast. Slides in for 2s after
            // Copy is pressed; restores on each press.
            if copiedToastVisible {
                HStack(spacing: .ostlerSpace1) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.ostlerForest)
                    Text(ViewCopy.shared.string(for: "recovery_key_reveal.copied_announcement"))
                        .font(.ostlerCaption)
                        .foregroundStyle(Color.ostlerInkMuted)
                }
                .padding(.vertical, 4)
            }

            Divider()

            // Confirm checkbox + Continue button. Continue is disabled
            // until the customer ticks the box. The two are visually
            // grouped so the gating is unambiguous.
            HStack(alignment: .center, spacing: .ostlerSpace3) {
                Toggle(isOn: $savedConfirmed) {
                    Text(ViewCopy.shared.string(for: "recovery_key_reveal.confirm_label"))
                        .font(.ostlerBody)
                        .foregroundStyle(Color.ostlerInk)
                }
                .toggleStyle(.checkbox)

                Spacer()

                Button(ViewCopy.shared.string(for: "recovery_key_reveal.continue_button")) {
                    coordinator.recoveryKeyAcknowledged = true
                    // Clear the value once acknowledged. The customer
                    // has saved it somewhere; keeping it around in
                    // memory longer than needed is unnecessary surface
                    // area for a future memory-dump or screen-capture
                    // bug. The acknowledgement flag is what gates the
                    // sheet's isPresented binding from here on.
                    coordinator.recoveryKey = nil
                }
                .buttonStyle(.ostlerPrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(!savedConfirmed)
            }
        }
        .padding(CGFloat.ostlerSpace4)
        .frame(width: 560)
        .background(Color.ostlerChassis)
    }

    // ── Actions ───────────────────────────────────────────────────

    private func copyToClipboard() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(recoveryKey, forType: .string)
        withAnimation(.easeInOut(duration: 0.2)) {
            copiedToastVisible = true
        }
        // Auto-dismiss after 2s.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            withAnimation(.easeInOut(duration: 0.2)) {
                copiedToastVisible = false
            }
        }
    }

    /// Render the recovery key to a PDF and let the customer choose
    /// where to save it. The rendered page is intentionally simple:
    /// a centred heading + the key in big monospace + a short body
    /// explaining the value, so a printed sheet of paper is
    /// self-explanatory if the customer pins it on their fridge.
    private func saveAsPDF() {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.pdf]
        savePanel.nameFieldStringValue = ViewCopy.shared.string(
            for: "recovery_key_reveal.pdf_default_filename"
        )
        savePanel.canCreateDirectories = true
        savePanel.message = ViewCopy.shared.string(for: "recovery_key_reveal.heading")
        guard savePanel.runModal() == .OK, let url = savePanel.url else { return }

        let printableView = printableNSView()
        // dataWithPDF returns a print-quality PDF of the rendered NSView.
        let pdfData = printableView.dataWithPDF(inside: printableView.bounds)
        do {
            try pdfData.write(to: url, options: .atomic)
        } catch {
            // Best-effort: a save-panel failure (read-only mount,
            // missing permissions) is not worth blocking the install
            // flow on. The customer still has Copy + Print available.
            NSLog("RecoveryKeyView: PDF save failed: \(error.localizedDescription)")
        }
    }

    /// Trigger the native macOS print dialog with the same printable
    /// representation we use for Save PDF. The customer picks any
    /// installed printer (or "Save as PDF" from the print dialog's
    /// PDF dropdown -- a third route to the same outcome).
    private func printRecoveryKey() {
        let printableView = printableNSView()
        let info = NSPrintInfo.shared
        info.jobDisposition = .spool
        let op = NSPrintOperation(view: printableView, printInfo: info)
        op.showsPrintPanel = true
        op.showsProgressPanel = true
        op.jobTitle = ViewCopy.shared.string(for: "recovery_key_reveal.print_job_title")
        op.run()
    }

    /// Build a printable NSView with the recovery key + supporting
    /// copy. Used by both Save PDF and Print so the two surfaces
    /// stay byte-identical. 8.5x11 inches (US Letter) at 72dpi =
    /// 612x792 pt -- a safe canvas size that prints cleanly on
    /// both A4 (210x297mm = 595x842pt) and US Letter.
    private func printableNSView() -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 612, height: 792))
        view.wantsLayer = true

        // Heading.
        let heading = NSTextField(labelWithString:
            ViewCopy.shared.string(for: "recovery_key_reveal.heading"))
        heading.font = NSFont.boldSystemFont(ofSize: 28)
        heading.textColor = NSColor.labelColor
        heading.frame = NSRect(x: 48, y: 700, width: 516, height: 40)
        view.addSubview(heading)

        // The key value, big + centred + monospaced.
        let keyField = NSTextField(labelWithString: recoveryKey)
        keyField.font = NSFont.monospacedSystemFont(ofSize: 28, weight: .semibold)
        keyField.alignment = .center
        keyField.textColor = NSColor.labelColor
        keyField.frame = NSRect(x: 48, y: 560, width: 516, height: 100)
        view.addSubview(keyField)

        // Body copy explaining what this is + that it cannot be
        // recovered. Read from the same ViewCopy string so the
        // sheet + the printed sheet say the same thing.
        let body = NSTextField(wrappingLabelWithString:
            ViewCopy.shared.string(for: "recovery_key_reveal.body"))
        body.font = NSFont.systemFont(ofSize: 13)
        body.textColor = NSColor.secondaryLabelColor
        body.frame = NSRect(x: 48, y: 420, width: 516, height: 120)
        view.addSubview(body)

        // Date stamp footer.
        let stamp = NSTextField(labelWithString:
            "Generated \(Self.dateFormatter.string(from: Date()))")
        stamp.font = NSFont.systemFont(ofSize: 11)
        stamp.textColor = NSColor.tertiaryLabelColor
        stamp.frame = NSRect(x: 48, y: 60, width: 516, height: 20)
        view.addSubview(stamp)

        return view
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .long
        f.timeStyle = .short
        f.locale = Locale(identifier: "en_GB")
        return f
    }()
}
