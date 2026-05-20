// LicenseEntryView.swift
//
// First-step view shown before the installer subprocess launches.
// Three input modes (task #351, 2026-05-21):
//   1. Drag a .json licence file onto the drop zone.
//   2. Paste the licence JSON text directly (fallback for email
//      clients that mangle attachments).
//   3. Paste a Stripe checkout session id (`cs_*`) or full licence
//      URL; the GUI fetches the canonical signed body from the CM050
//      Worker at appcast.ostler.ai. There is no licence-id-keyed
//      Worker endpoint at v1.0 launch, so pasting a short Licence ID
//      lands on the existing friendly steer toward the JSON file.
// Every path runs through `LicenseVerifier.verify`; on `.valid`
// the verified bytes are persisted via `LicensePersistence` and
// the coordinator's `licenseVerified` flag flips, letting
// ContentView advance to the install layout.

import SwiftUI
import UniformTypeIdentifiers

struct LicenseEntryView: View {
    @EnvironmentObject private var coordinator: InstallerCoordinator

    @State private var pasteText: String = ""
    @State private var idText: String = ""
    @State private var isTargeted: Bool = false
    @State private var errorMessage: String? = nil
    @State private var isFetching: Bool = false

    // Fetcher is held as a per-view instance so it picks up any
    // env-var override at first appearance, but we don't take the
    // hit of re-instantiating URLSession state every render pass.
    private let fetcher = LicenseFetcher()

    var body: some View {
        VStack(spacing: 24) {
            header
            dropZone
            pasteRow
            idRow
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

    // MARK: - Paste row (JSON)

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

    // MARK: - Paste row (Stripe session id / licence URL)
    //
    // Single text field that accepts either:
    //   * `cs_test_...` / `cs_live_...` Stripe checkout session id
    //   * Full licence URL (extracts the `cs_*` segment)
    //   * Short Licence ID (UUID-ish) -- handled by the friendly steer
    //
    // Anything else lands on the unrecognised-paste error.

    private var idRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(ViewCopy.shared.string(for: "license_entry.id_label"))
                .font(.ostlerCaption)
                .foregroundColor(.ostlerInkMuted)
            HStack(spacing: 8) {
                TextField(
                    ViewCopy.shared.string(for: "license_entry.id_placeholder"),
                    text: $idText
                )
                .textFieldStyle(.roundedBorder)
                .font(.custom(Font.OstlerFontName.monoRegular, size: 13, relativeTo: .body))
                .disabled(isFetching)
                Button(isFetching
                       ? ViewCopy.shared.string(for: "license_entry.fetch_button_busy")
                       : ViewCopy.shared.string(for: "license_entry.fetch_button")) {
                    fetchById()
                }
                .buttonStyle(.ostlerGhost)
                .disabled(idText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isFetching)
            }
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
    //
    // Order matters: Finder advertises a plain `.json` drag via
    // `kUTTypeFileURL` Data bookmark, which the high-level
    // `canLoadObject(ofClass: URL.self)` check does NOT pick up. The
    // pre-task-#351 implementation tried that branch first and
    // silently returned false for every Finder drag.
    //
    // Fix order:
    //   1. `hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)`
    //      + `loadItem(forTypeIdentifier:)` decoding both Data + String
    //      representations -- this catches every Finder drag.
    //   2. `canLoadObject(ofClass: URL.self)` as a belt-and-braces
    //      fallback for non-Finder providers that advertise via the
    //      Foundation class binding.
    //   3. Plain-text drag as a last-resort fallback for terminal +
    //      email-client paste patterns.

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }

        // 1. File URL via low-level type-identifier path. Catches
        // every Finder drag of a `.json` because Finder advertises
        // `kUTTypeFileURL` (UTType.fileURL.identifier on modern macOS).
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                // Two representations can land here:
                //   (a) Data bookmark -- the common Finder shape, decoded
                //       via URL(dataRepresentation:).
                //   (b) NSURL -- some non-Finder providers and the
                //       SwiftUI bridging path return this directly.
                //   (c) NSString -- terminal drag-and-drop on macOS
                //       sometimes hands a percent-encoded URL string.
                var resolved: URL? = nil
                if let data = item as? Data {
                    resolved = URL(dataRepresentation: data, relativeTo: nil)
                } else if let url = item as? URL {
                    resolved = url
                } else if let nsurl = item as? NSURL {
                    resolved = nsurl as URL
                } else if let s = item as? String, let url = URL(string: s) {
                    resolved = url
                }
                guard let url = resolved else { return }
                DispatchQueue.main.async {
                    self.loadFromURL(url)
                }
            }
            return true
        }

        // 2. Foundation class binding -- belt-and-braces. Modern
        // SwiftUI providers expose `URL.self` in addition to the
        // type-identifier path, but the legacy Finder bookmark path
        // above is the durable catch.
        if provider.canLoadObject(ofClass: URL.self) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async {
                    self.loadFromURL(url)
                }
            }
            return true
        }

        // 3. Plain-text drag as a last resort. Used when the customer
        // drags raw text from a terminal or email client rather than
        // a file from Finder.
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
        // App is unsandboxed (entitlements: app-sandbox = false), so
        // security-scoped resource access is not required. Belt-and-
        // braces only: if a future build flips sandboxing on, this
        // pair will keep the read working without further surgery.
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }

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

    // MARK: - Fetch by Stripe session id / licence URL

    private func fetchById() {
        errorMessage = nil
        let shape = classifyLicensePaste(idText)
        switch shape {
        case .stripeSessionId(let sid):
            startFetch(sessionId: sid)
        case .licenseUrl(let sid):
            startFetch(sessionId: sid)
        case .shortLicenseId:
            // No licence-id-keyed Worker endpoint at v1.0. Steer the
            // customer to the JSON file in their welcome email.
            errorMessage = LicenseEntryView.shortIdGuidanceMessage
        case .rawJson(let data):
            // Customer pasted JSON into the id field by accident --
            // verify it anyway.
            verify(data: data, source: "id-paste-json")
        case .unrecognised:
            errorMessage = ViewCopy.shared.string(for: "license_entry.id_unrecognised")
        }
    }

    private func startFetch(sessionId: String) {
        isFetching = true
        Task { @MainActor in
            let outcome = await fetcher.fetch(sessionId: sessionId)
            isFetching = false
            handleFetchOutcome(outcome)
        }
    }

    private func handleFetchOutcome(_ outcome: LicenseFetchOutcome) {
        switch outcome {
        case .fetched(let signedJson):
            verify(data: signedJson, source: "fetch")
        case .notReady:
            errorMessage = ViewCopy.shared.string(for: "license_entry.fetch_not_ready")
        case .revoked:
            errorMessage = ViewCopy.shared.string(for: "license_entry.fetch_revoked")
        case .envelopeMissing:
            errorMessage = ViewCopy.shared.string(for: "license_entry.fetch_signed_json_missing")
        case .httpError(let status):
            errorMessage = ViewCopy.shared.string(
                for: "license_entry.fetch_http_error",
                fills: ["status": "\(status)"]
            )
        case .transportError(let reason):
            errorMessage = ViewCopy.shared.string(
                for: "license_entry.fetch_transport_error",
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
