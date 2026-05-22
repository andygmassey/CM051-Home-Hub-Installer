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
import os

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
        // Drag-over uses `ostlerForest` (accent-3, green-leaning) as
        // an "accept affordance". The pre-2026-05-21 build used
        // `ostlerOxblood` for the drag-over border, which is the
        // brand's reject / error red and reads to customers as a
        // rejection signal. Studio retest #8 surfaced this: customers
        // dragged a valid licence file, saw the oxblood border, and
        // concluded the file was being rejected, despite the drop
        // sometimes succeeding silently. Oxblood is reserved for
        // genuine validation errors (the `errorBanner`).
        RoundedRectangle(cornerRadius: 12)
            .strokeBorder(
                isTargeted ? Color.ostlerForest : Color.ostlerHairlineFaint,
                style: StrokeStyle(lineWidth: isTargeted ? 2 : 1, dash: isTargeted ? [] : [6, 4])
            )
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isTargeted ? Color.ostlerForest.opacity(0.04) : Color.ostlerChassisDeep)
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

    /// Single drop path that funnels every supported NSItemProvider
    /// representation (URL.self loadable, public.file-url, public.json,
    /// public.plain-text) through the same `verify(data:source:)` call
    /// the paste-button uses. The pre-2026-05-21 build forked into
    /// three independent branches with silent guard returns on each
    /// async-load failure -- a JSON file dragged from Finder where
    /// `loadObject(ofClass: URL.self)` returned a nil URL produced a
    /// drop-accepted-then-silent-bail with no error message and no
    /// installer advance. Every failure path here surfaces an error
    /// via `errorMessage` so the customer sees the actual reason.
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else {
            DispatchQueue.main.async {
                self.errorMessage = ViewCopy.shared.string(for: "license_entry.drop_no_provider_error")
            }
            return false
        }
        acquireDropData(from: provider)
        return true
    }

    /// Fan out across the provider's supported representations and
    /// dispatch to `verify(data:source:)` once data is in hand. All
    /// failure paths land on `errorMessage` rather than silently
    /// bailing, so the customer always gets either an installer
    /// advance or a one-line reason.
    ///
    /// Each branch logs an `.info` line at entry so a retest can
    /// identify which dispatcher branch matched without needing a
    /// debug build (the previous build only logged the registered
    /// type list and per-branch failures; if no branch matched, the
    /// customer saw the dashed-idle border with no installer
    /// advance and the cause was invisible to support).
    private func acquireDropData(from provider: NSItemProvider) {
        let typeIdentifiers = provider.registeredTypeIdentifiers
        OstlerLog.lifecycle.info("license drop: provider types=\(typeIdentifiers.joined(separator: ","), privacy: .public)")

        // Branch A: URL.self loadable. Finder-sourced file drops land
        // here on macOS 12+. Apple Forum threads under
        // <feedback://NSItemProvider-canLoadObject-URL> note Sequoia
        // (macOS 15) occasionally returns `false` here for files with
        // an active quarantine xattr; in that case Branch B picks up
        // via the older `public.file-url` representation. Keep both
        // branches; reorder only on confirmed-repro evidence.
        if provider.canLoadObject(ofClass: URL.self) {
            OstlerLog.lifecycle.info("license drop: matched branch A (canLoadObject URL.self)")
            _ = provider.loadObject(ofClass: URL.self) { url, error in
                DispatchQueue.main.async {
                    if let url {
                        OstlerLog.lifecycle.info("license drop branch A resolved URL: \(url.lastPathComponent, privacy: .public)")
                        self.loadFromURL(url)
                    } else {
                        self.errorMessage = ViewCopy.shared.string(
                            for: "license_entry.drop_url_resolve_error",
                            fills: ["reason": error?.localizedDescription ?? "no URL returned"]
                        )
                        OstlerLog.lifecycle.error("license drop branch A URL.self load returned nil: \(error?.localizedDescription ?? "no error", privacy: .public)")
                    }
                }
            }
            return
        }

        // Branch B: explicit public.file-url representation.
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            OstlerLog.lifecycle.info("license drop: matched branch B (public.file-url)")
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                DispatchQueue.main.async {
                    if let urlData = item as? Data,
                       let url = URL(dataRepresentation: urlData, relativeTo: nil) {
                        OstlerLog.lifecycle.info("license drop branch B resolved URL: \(url.lastPathComponent, privacy: .public)")
                        self.loadFromURL(url)
                    } else {
                        self.errorMessage = ViewCopy.shared.string(
                            for: "license_entry.drop_url_resolve_error",
                            fills: ["reason": error?.localizedDescription ?? "file URL data was empty or malformed"]
                        )
                        OstlerLog.lifecycle.error("license drop branch B public.file-url load failed: \(error?.localizedDescription ?? "no error", privacy: .public)")
                    }
                }
            }
            return
        }

        // Branch C: explicit public.json representation. The pre-fix
        // build registered `.json` in the `.onDrop(of:)` accept list
        // but never handled it in the dispatcher, so a JSON-only
        // provider (no fileURL, no URL.self coercion) fell through
        // to the false return and the customer saw the dashed-idle
        // border with no error.
        if provider.hasItemConformingToTypeIdentifier(UTType.json.identifier) {
            OstlerLog.lifecycle.info("license drop: matched branch C (public.json)")
            provider.loadItem(forTypeIdentifier: UTType.json.identifier, options: nil) { item, error in
                DispatchQueue.main.async {
                    if let data = item as? Data {
                        OstlerLog.lifecycle.info("license drop branch C loaded \(data.count, privacy: .public) bytes")
                        self.verify(data: data, source: "drop-json")
                    } else if let s = item as? String, let data = s.data(using: .utf8) {
                        OstlerLog.lifecycle.info("license drop branch C loaded \(data.count, privacy: .public) bytes (string)")
                        self.verify(data: data, source: "drop-json-string")
                    } else {
                        self.errorMessage = ViewCopy.shared.string(
                            for: "license_entry.drop_json_load_error",
                            fills: ["reason": error?.localizedDescription ?? "JSON payload was empty"]
                        )
                        OstlerLog.lifecycle.error("license drop branch C public.json load failed: \(error?.localizedDescription ?? "no error", privacy: .public)")
                    }
                }
            }
            return
        }

        // Branch D: plain-text payload. Apps that put JSON on the
        // pasteboard as text-only land here (e.g. dragging a text
        // selection out of a code editor).
        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            OstlerLog.lifecycle.info("license drop: matched branch D (public.plain-text)")
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, error in
                DispatchQueue.main.async {
                    if let s = item as? String, let data = s.data(using: .utf8) {
                        OstlerLog.lifecycle.info("license drop branch D loaded \(data.count, privacy: .public) bytes")
                        self.verify(data: data, source: "drop-text")
                    } else {
                        self.errorMessage = ViewCopy.shared.string(
                            for: "license_entry.drop_text_load_error",
                            fills: ["reason": error?.localizedDescription ?? "text payload was empty"]
                        )
                        OstlerLog.lifecycle.error("license drop branch D public.plain-text load failed: \(error?.localizedDescription ?? "no error", privacy: .public)")
                    }
                }
            }
            return
        }

        // No branch matched. Surface what we saw so a customer
        // sending a screenshot to support has something to paste.
        DispatchQueue.main.async {
            self.errorMessage = ViewCopy.shared.string(
                for: "license_entry.drop_unsupported_type_error",
                fills: ["types": typeIdentifiers.joined(separator: ", ")]
            )
            OstlerLog.lifecycle.error("license drop unsupported provider types: \(typeIdentifiers.joined(separator: ","), privacy: .public)")
        }
    }

    /// Read bytes off disk for a URL that came in via Branch A or B.
    ///
    /// Pre-2026-05-22: this used `try? Data(contentsOf:)`. The
    /// `try?` swallowed the actual error and the message that landed
    /// on the customer's screen was the generic "Could not read the
    /// licence file at <filename>" -- a dead end with no support
    /// signal. If the read happened to succeed but the file was
    /// empty (zero bytes), the empty Data slid into `verify(data:)`,
    /// JSON-parsed, and emitted "Could not parse licence JSON" --
    /// also dead-end and misleading-cause-and-effect (the bytes
    /// weren't malformed, there just weren't any). Both shapes are
    /// what Andy's earlier "file empty" recollection refers to.
    ///
    /// Now: explicit do/try/catch surfaces the actual underlying
    /// error via `localizedDescription`, and an explicit empty-data
    /// guard raises a distinct `drop_file_empty_error` rather than
    /// pretending the bytes were malformed.
    private func loadFromURL(_ url: URL) {
        do {
            let data = try readLicenceFile(at: url)
            OstlerLog.lifecycle.info("license drop file read \(data.count, privacy: .public) bytes from \(url.lastPathComponent, privacy: .public)")
            verify(data: data, source: "drop-file")
        } catch is LicenceFileEmpty {
            OstlerLog.lifecycle.error("license drop file empty: \(url.lastPathComponent, privacy: .public)")
            errorMessage = ViewCopy.shared.string(
                for: "license_entry.drop_file_empty_error",
                fills: ["filename": url.lastPathComponent]
            )
        } catch {
            OstlerLog.lifecycle.error("license drop file read failed \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            errorMessage = ViewCopy.shared.string(
                for: "license_entry.read_file_error",
                fills: [
                    "filename": url.lastPathComponent,
                    "reason": error.localizedDescription
                ]
            )
        }
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

/// Sentinel error type for the "URL read succeeded but the file
/// has zero bytes" case. Distinct from the underlying read error
/// so the catch in `LicenseEntryView.loadFromURL` can emit a
/// dedicated `drop_file_empty_error` message instead of letting
/// an empty Data slide into the JSON parser (which would then
/// misleadingly emit "Could not parse licence JSON").
///
/// Module-scope `struct` rather than a nested `enum` case so the
/// `@testable import OstlerInstaller` tests can construct + match
/// it without depending on SwiftUI types.
struct LicenceFileEmpty: Error {}

/// Read a licence file from disk and surface either:
///  - the underlying `Data(contentsOf:)` error (which carries the
///    actual filesystem-level reason: permissions, missing file,
///    quarantine xattr conflict on Sequoia, etc.) via
///    `error.localizedDescription`, or
///  - `LicenceFileEmpty` if the read succeeded but the file has
///    zero bytes (the path that previously slid into
///    `verify(data:)` and emitted a misleading
///    "malformed JSON" error).
///
/// Lives at module scope so OstlerInstallerTests can test it
/// directly without instantiating `LicenseEntryView` (which
/// requires an EnvironmentObject and a SwiftUI hosting context).
func readLicenceFile(at url: URL) throws -> Data {
    let data = try Data(contentsOf: url)
    guard !data.isEmpty else {
        throw LicenceFileEmpty()
    }
    return data
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
