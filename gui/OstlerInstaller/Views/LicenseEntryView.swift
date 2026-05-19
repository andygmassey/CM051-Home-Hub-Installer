// LicenseEntryView.swift
//
// First-step view shown before the installer subprocess launches.
// Two input modes:
//   1. Drag a .json licence file onto the drop zone.
//   2. Paste the licence JSON text directly (fallback for email
//      clients that mangle attachments).
// Either path runs through `LicenseVerifier.verify`; on `.valid`
// the verified bytes are persisted via `LicensePersistence` and
// the coordinator's `licenseVerified` flag flips, letting
// ContentView advance to the install layout.

import SwiftUI
import UniformTypeIdentifiers

struct LicenseEntryView: View {
    @EnvironmentObject private var coordinator: InstallerCoordinator

    @State private var pasteText: String = ""
    @State private var isTargeted: Bool = false
    @State private var errorMessage: String? = nil

    var body: some View {
        VStack(spacing: 24) {
            header
            dropZone
            pasteRow
            verifyButton
            if let errorMessage {
                errorBanner(errorMessage)
            }
            Spacer()
            footerHint
        }
        .padding(.horizontal, 48)
        .padding(.vertical, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.ostlerChassis)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(ViewCopy.shared.string(for: "license_entry.heading"))
                .font(.ostlerH1)
                .foregroundColor(.ostlerInk)
            Text(ViewCopy.shared.string(for: "license_entry.intro"))
                .font(.ostlerBody)
                .foregroundColor(.ostlerInkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Drop zone

    private var dropZone: some View {
        RoundedRectangle(cornerRadius: 12)
            .strokeBorder(
                isTargeted ? Color.ostlerOxblood : Color.ostlerHairlineFaint,
                style: StrokeStyle(lineWidth: isTargeted ? 2 : 1, dash: isTargeted ? [] : [6, 4])
            )
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isTargeted ? Color.ostlerOxblood.opacity(0.04) : Color.ostlerChassisDeep)
            )
            .frame(height: 130)
            .overlay(dropZoneContent)
            .onDrop(of: [.fileURL, .json, .plainText], isTargeted: $isTargeted, perform: handleDrop)
    }

    private var dropZoneContent: some View {
        VStack(spacing: 6) {
            Image(systemName: "doc.badge.arrow.up")
                .font(.system(size: 28, weight: .regular))
                .foregroundColor(.ostlerInkMuted)
            Text(ViewCopy.shared.string(for: isTargeted ? "license_entry.dropzone_active"
                                                        : "license_entry.dropzone_idle"))
                .font(.ostlerBodyLg)
                .foregroundColor(.ostlerInk)
            Text(ViewCopy.shared.string(for: "license_entry.dropzone_hint"))
                .font(.ostlerCaption)
                .foregroundColor(.ostlerInkMuted)
        }
    }

    // MARK: - Paste row

    private var pasteRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(ViewCopy.shared.string(for: "license_entry.paste_label"))
                .font(.ostlerCaption)
                .foregroundColor(.ostlerInkMuted)
            TextEditor(text: $pasteText)
                .font(.custom(Font.OstlerFontName.monoRegular, size: 13, relativeTo: .body))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(height: 110)
                .background(Color.ostlerChassisDeep)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.ostlerHairlineFaint, lineWidth: 1)
                )
        }
    }

    // MARK: - Verify button

    private var verifyButton: some View {
        HStack {
            Spacer()
            Button(ViewCopy.shared.string(for: "license_entry.verify_button")) {
                errorMessage = nil
                if looksLikeShortLicenceId(pasteText) {
                    errorMessage = LicenseEntryView.shortIdGuidanceMessage
                    return
                }
                guard let data = pasteText.data(using: .utf8), !pasteText.isEmpty else {
                    errorMessage = ViewCopy.shared.string(for: "license_entry.paste_empty_error")
                    return
                }
                verify(data: data, source: "paste")
            }
            .buttonStyle(.ostlerPrimary)
            .keyboardShortcut(.defaultAction)
            .disabled(pasteText.isEmpty)
        }
    }

    // MARK: - Error banner

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.ostlerOxblood)
            VStack(alignment: .leading, spacing: 4) {
                Text(message)
                    .font(.ostlerBody)
                    .foregroundColor(.ostlerInk)
                Text(ViewCopy.shared.string(for: "license_entry.error_help_caption"))
                    .font(.ostlerCaption)
                    .foregroundColor(.ostlerInkMuted)
            }
            Spacer()
        }
        .padding(12)
        .background(Color.ostlerOxblood.opacity(0.07))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.ostlerOxblood.opacity(0.30), lineWidth: 1)
        )
    }

    // MARK: - Footer hint

    private var footerHint: some View {
        Text(ViewCopy.shared.string(for: "license_entry.footer_hint"))
            .font(.ostlerCaption)
            .foregroundColor(.ostlerInkMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Drop handling

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        if provider.canLoadObject(ofClass: URL.self) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async {
                    self.loadFromURL(url)
                }
            }
            return true
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard let urlData = item as? Data,
                      let url = URL(dataRepresentation: urlData, relativeTo: nil) else { return }
                DispatchQueue.main.async {
                    self.loadFromURL(url)
                }
            }
            return true
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
                guard let s = item as? String,
                      let data = s.data(using: .utf8) else { return }
                DispatchQueue.main.async {
                    self.verify(data: data, source: "drop-text")
                }
            }
            return true
        }
        return false
    }

    private func loadFromURL(_ url: URL) {
        guard let data = try? Data(contentsOf: url) else {
            errorMessage = ViewCopy.shared.string(
                for: "license_entry.read_file_error",
                fills: ["filename": url.lastPathComponent]
            )
            return
        }
        verify(data: data, source: "drop-file")
    }

    // MARK: - Verify + hand off

    private func verify(data: Data, source: String) {
        let result = coordinator.verifyLicense(data: data, source: source)
        switch result {
        case .valid:
            errorMessage = nil
        case .invalidSignature:
            errorMessage = ViewCopy.shared.string(for: "license_entry.signature_invalid_error")
        case .expired(let expiresAt):
            errorMessage = ViewCopy.shared.string(
                for: "license_entry.expired_error",
                fills: ["expires_at": "\(expiresAt)"]
            )
        case .malformed(let reason):
            errorMessage = ViewCopy.shared.string(
                for: "license_entry.malformed_error",
                fills: ["reason": reason]
            )
        }
    }

    // MARK: - Short-Licence-ID heuristic

    // Friendly message shown when the customer pastes their short Licence
    // ID (first 8 chars of the licence_id UUID, surfaced inline in the
    // welcome email) into the JSON-paste field. Without this the verifier
    // would emit a meaningless JSON-parse error.
    //
    // The English source lives in Resources/ViewCopy.json under the key
    // `license_entry.short_id_guidance`. This static var stays as the
    // call-site stable name so existing tests (and any future callers)
    // do not have to know about the catalogue lookup.
    static var shortIdGuidanceMessage: String {
        ViewCopy.shared.string(for: "license_entry.short_id_guidance")
    }
}

// Detects pastes that match the short-Licence-ID shape rather than the
// full licence JSON. Conservative: only triggers on short hex-like
// strings (4-16 chars, hex + dash, no `{` or `"`). Real JSON will
// always contain `{` or be longer than 16 chars, so passes through
// untouched. Empty pastes return false so the existing empty-paste
// guard keeps its own error message.
//
// Lives at module scope rather than as a private member so the
// OstlerInstallerTests target can exercise it directly via
// `@testable import OstlerInstaller`.
func looksLikeShortLicenceId(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }
    guard trimmed.count <= 16 else { return false }
    guard !trimmed.contains("{"), !trimmed.contains("\"") else { return false }
    let hexCharSet = CharacterSet(charactersIn: "0123456789abcdefABCDEF-")
    return trimmed.unicodeScalars.allSatisfy { hexCharSet.contains($0) }
}
