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
            Text("Your licence")
                .font(.ostlerH1)
                .foregroundColor(.ostlerInk)
            Text("Ostler needs a licence file before it can install. The licence arrived in your welcome email from hello@ostler.ai. Save the attached file (it looks like `ostler-licence.json`), then drag it here -- or paste the JSON contents below.")
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
            Text(isTargeted ? "Drop to verify" : "Drag your licence file here")
                .font(.ostlerBodyLg)
                .foregroundColor(.ostlerInk)
            Text("Looks for ostler-licence.json (or similar)")
                .font(.ostlerCaption)
                .foregroundColor(.ostlerInkMuted)
        }
    }

    // MARK: - Paste row

    private var pasteRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Or paste the licence text")
                .font(.ostlerCaption)
                .foregroundColor(.ostlerInkMuted)
            TextEditor(text: $pasteText)
                .font(.system(.body, design: .monospaced))
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
            Button("Verify Licence") {
                errorMessage = nil
                guard let data = pasteText.data(using: .utf8), !pasteText.isEmpty else {
                    errorMessage = "Paste the licence JSON above first, or drop the file onto the box."
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
                Text("Need help? Email hello@ostler.ai")
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
        Text("Your licence stays on this Mac. It is verified locally with a key built into this installer -- no network call is made during this step.")
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
            errorMessage = "Could not read the licence file at \(url.lastPathComponent)."
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
            errorMessage = "Signature check failed. This file is not a licence we signed, or it was edited after delivery."
        case .expired(let expiresAt):
            errorMessage = "Your licence expired on \(expiresAt). Email hello@ostler.ai to renew."
        case .malformed(let reason):
            errorMessage = "Could not read this licence: \(reason)"
        }
    }
}
