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
    private func acquireDropData(from provider: NSItemProvider) {
        let typeIdentifiers = provider.registeredTypeIdentifiers
        OstlerLog.lifecycle.debug("license drop: provider types=\(typeIdentifiers.joined(separator: ","), privacy: .public)")

        // Branch A: URL.self loadable. Finder-sourced file drops land
        // here on macOS 12+.
        if provider.canLoadObject(ofClass: URL.self) {
            _ = provider.loadObject(ofClass: URL.self) { url, error in
                DispatchQueue.main.async {
                    if let url {
                        self.loadFromURL(url)
                    } else {
                        self.errorMessage = ViewCopy.shared.string(
                            for: "license_entry.drop_url_resolve_error",
                            fills: ["reason": error?.localizedDescription ?? "no URL returned"]
                        )
                        OstlerLog.lifecycle.error("license drop URL.self load returned nil: \(error?.localizedDescription ?? "no error", privacy: .public)")
                    }
                }
            }
            return
        }

        // Branch B: explicit public.file-url representation.
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                DispatchQueue.main.async {
                    if let urlData = item as? Data,
                       let url = URL(dataRepresentation: urlData, relativeTo: nil) {
                        self.loadFromURL(url)
                    } else {
                        self.errorMessage = ViewCopy.shared.string(
                            for: "license_entry.drop_url_resolve_error",
                            fills: ["reason": error?.localizedDescription ?? "file URL data was empty or malformed"]
                        )
                        OstlerLog.lifecycle.error("license drop public.file-url load failed: \(error?.localizedDescription ?? "no error", privacy: .public)")
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
        //
        // CX-16 follow-up (2026-05-23): NSItemProvider.loadItem under
        // public.json typically returns a file URL (URL or NSURL),
        // NOT the file bytes, when the customer drags a `.json` file
        // out of Finder. The original Branch C handler only cast the
        // item to Data + String, so the URL case fell to the empty-
        // payload branch and customers saw "Could not read the
        // dropped JSON (JSON payload was empty)" on what should have
        // been a successful drop. The dispatcher now walks
        // Data -> String -> URL -> NSURL -> empty, mirroring how
        // Branch B handles `urlData as? Data` + `URL(dataRepresentation:)`.
        // The resolution table itself lives in `resolveDroppedJSONItem(_:)`
        // so the fall-through order is testable byte-by-byte without
        // spinning up a real Finder drag-drop fixture.
        if provider.hasItemConformingToTypeIdentifier(UTType.json.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.json.identifier, options: nil) { item, error in
                DispatchQueue.main.async {
                    switch resolveDroppedJSONItem(item) {
                    case .data(let data):
                        self.verify(data: data, source: "drop-json")
                    case .string(let data):
                        self.verify(data: data, source: "drop-json-string")
                    case .url(let url):
                        self.loadFromURL(url)
                    case .empty:
                        self.errorMessage = ViewCopy.shared.string(
                            for: "license_entry.drop_json_load_error",
                            fills: ["reason": error?.localizedDescription ?? "JSON payload was empty"]
                        )
                        OstlerLog.lifecycle.error("license drop public.json load failed: \(error?.localizedDescription ?? "no error", privacy: .public)")
                    }
                }
            }
            return
        }

        // Branch D: plain-text payload. Apps that put JSON on the
        // pasteboard as text-only land here (e.g. dragging a text
        // selection out of a code editor).
        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, error in
                DispatchQueue.main.async {
                    if let s = item as? String, let data = s.data(using: .utf8) {
                        self.verify(data: data, source: "drop-text")
                    } else {
                        self.errorMessage = ViewCopy.shared.string(
                            for: "license_entry.drop_text_load_error",
                            fills: ["reason": error?.localizedDescription ?? "text payload was empty"]
                        )
                        OstlerLog.lifecycle.error("license drop public.plain-text load failed: \(error?.localizedDescription ?? "no error", privacy: .public)")
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

    private func loadFromURL(_ url: URL) {
        // Use do/try/catch (not `try?`) so the underlying read-error
        // reason surfaces to the customer. The pre-fix `try?` form
        // collapsed permission errors, missing-file, quarantine xattr
        // conflicts, and disconnected network volumes into the same
        // generic "Could not read the licence file at <name>" message,
        // which was a dead end for both customer and support.
        //
        // After the read succeeds we also guard against zero-byte
        // files. The pre-fix path let an empty `Data` slide into the
        // verifier, where `JSONSerialization` reported it as malformed
        // -- the bytes weren't malformed, there just weren't any. The
        // mismatched cause-and-effect was the most common silent-bail
        // shape on the drop-zone path (matches Andy's prior-retest
        // memory of "the previous time it said the file was empty or
        // something").
        do {
            let data = try readLicenceFile(at: url)
            OstlerLog.lifecycle.info("license drop file read \(data.count) bytes from \(url.lastPathComponent, privacy: .public)")
            verify(data: data, source: "drop-file")
        } catch LicenceFileError.empty(let filename) {
            errorMessage = ViewCopy.shared.string(
                for: "license_entry.drop_file_empty_error",
                fills: ["filename": filename]
            )
            OstlerLog.lifecycle.error("license drop file empty: \(filename, privacy: .public)")
        } catch {
            errorMessage = ViewCopy.shared.string(
                for: "license_entry.read_file_error",
                fills: [
                    "filename": url.lastPathComponent,
                    "reason": error.localizedDescription
                ]
            )
            OstlerLog.lifecycle.error("license drop file read failed \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
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

// Errors thrown by `readLicenceFile(at:)`. Distinct cases let the
// view layer surface a precise reason to the customer (the catalogue
// key differs for `empty` vs. underlying `Data(contentsOf:)` failures).
enum LicenceFileError: Error, Equatable {
    /// The file existed and read succeeded, but the byte count was 0.
    /// Carries the filename for the customer-facing copy.
    case empty(filename: String)
}

// Reads a licence file from disk and guards against zero-byte payloads.
// Lives at module scope so the OstlerInstallerTests target can exercise
// the read + empty-guard paths directly via `@testable import
// OstlerInstaller`, byte-by-byte (per locked memory
// `feedback_silent_bail_regression_test_shape`).
func readLicenceFile(at url: URL) throws -> Data {
    let data = try Data(contentsOf: url)
    guard !data.isEmpty else {
        throw LicenceFileError.empty(filename: url.lastPathComponent)
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

// MARK: - Branch C public.json item resolution
//
// CX-16 (2026-05-23): NSItemProvider.loadItem(forTypeIdentifier:options:)
// returns Any?, but the concrete type varies by drop source:
//
//   - Apps that put encoded JSON bytes on the pasteboard return `Data`.
//   - Apps that put a JSON string on the pasteboard return `String`.
//   - Finder (and most macOS file drops) return a file URL pointing
//     at the .json file on disk. The URL arrives as either `URL` or,
//     under certain Foundation paths, the bridged `NSURL`. In neither
//     case are the file bytes inlined.
//
// The pre-fix dispatcher only handled the first two, so Finder drops
// of a real `.json` file fell to the empty-payload branch and the
// customer saw "JSON payload was empty" on what should have been a
// successful drag-drop (Studio retest 2026-05-23). This pure-Swift
// helper makes the fall-through order explicit + testable; the view's
// Branch C dispatcher walks the cases in declared order and the
// regression suite walks the same cases byte-by-byte.
//
// Returns `.empty` for nil items, empty data, empty strings, and
// nil URLs -- every shape the customer might hit where there is
// genuinely nothing to read. The view turns `.empty` into the
// existing user-visible "JSON payload was empty" banner so the
// regression test for the old behaviour still passes.
enum DroppedJSONResolution: Equatable {
    case data(Data)
    case string(Data)
    case url(URL)
    case empty
}

func resolveDroppedJSONItem(_ item: Any?) -> DroppedJSONResolution {
    // 1. Data: caller already has the bytes -- shortest path.
    if let data = item as? Data {
        return data.isEmpty ? .empty : .data(data)
    }

    // 2. String: caller serialised JSON as text. Encode utf8 and
    //    treat as inline bytes.
    if let s = item as? String {
        guard !s.isEmpty, let data = s.data(using: .utf8) else {
            return .empty
        }
        return .string(data)
    }

    // 3. URL: file URL pointing at the .json on disk. Caller will
    //    open + read via loadFromURL, which routes through
    //    readLicenceFile(at:) (Shape 1 + Shape 2 guards from PR #155).
    if let url = item as? URL {
        return .url(url)
    }

    // 4. NSURL: Foundation occasionally returns the bridged NSURL
    //    class instead of the Swift URL value type. Coerce back to
    //    URL via `as URL` (the standard cast pattern). Falls through
    //    to the same loadFromURL path as Branch B's URL output.
    if let nsurl = item as? NSURL {
        return .url(nsurl as URL)
    }

    return .empty
}
