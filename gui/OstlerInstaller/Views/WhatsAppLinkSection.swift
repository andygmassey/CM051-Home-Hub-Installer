// WhatsAppLinkSection.swift
//
// v1.0.103: the "Connect WhatsApp" step on the install-complete screen.
// Replaces "open Terminal and run ostler-assistant setup channels" as the
// way a customer links WhatsApp. Logic and the reasons for it live in
// WhatsAppLink.swift; this file is only the rendering and the polling.
//
// All copy routes through ViewCopy (Rule 0.9), under `whatsapp_link.*`.

import SwiftUI
import AppKit

struct WhatsAppLinkSection: View {
    private let io: WhatsAppLinkIO

    /// How long to wait for a new code after asking before saying so.
    /// Measured on macstudio: the code file lands 3 s after the kickstart.
    static let requestTimeoutSeconds = 60

    @State private var config: WhatsAppConfig = .notEnabled
    @State private var linked: WhatsAppLinkedState = .notLinked
    @State private var pair: WhatsAppPairCode = .notRequested
    @State private var now: Int = Int(Date().timeIntervalSince1970)
    @State private var skipped = false
    @State private var requestStartedAt: Int? = nil
    @State private var loaded = false

    /// `previewPhase` pins the section to one phase with no IO at all. Used
    /// by the snapshot harness so every state can be rendered on a CI host
    /// with no daemon.
    private let previewPhase: WhatsAppLinkPhase?

    init(io: WhatsAppLinkIO = .live(), previewPhase: WhatsAppLinkPhase? = nil) {
        self.io = io
        self.previewPhase = previewPhase
    }

    private var phase: WhatsAppLinkPhase {
        if let p = previewPhase { return p }
        if !loaded { return .hidden }
        let timedOut = requestStartedAt.map { now - $0 >= Self.requestTimeoutSeconds } ?? false
        return WhatsAppLinkPhase.derive(
            config: config, linked: linked, pair: pair, now: now,
            skipped: skipped, requestStartedAt: requestStartedAt,
            requestTimedOut: timedOut
        )
    }

    private func copy(_ key: String) -> String {
        ViewCopy.shared.string(for: "whatsapp_link.\(key)")
    }

    var body: some View {
        Group {
            if phase != .hidden {
                VStack(alignment: .leading, spacing: .ostlerSpace2) {
                    Divider()
                    Text(copy("title"))
                        .font(.ostlerStrap)
                        .tracking(1.2)
                        .foregroundStyle(Color.ostlerInkMuted)
                    content
                }
                .padding(.vertical, .ostlerSpace1)
            }
        }
        .task {
            guard previewPhase == nil else { return }
            await pollLoop()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .hidden:
            EmptyView()

        case .linked:
            HStack(spacing: .ostlerSpace2) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.ostlerForest)
                    .font(.system(size: 22))
                para(copy("linked"))
            }

        case .ready:
            para(copy("intro"))
            HStack(spacing: .ostlerSpace2) {
                primaryButton(copy("get_code_button"), action: askForCode)
                skipButton
                Spacer()
            }

        case .requesting:
            para(copy("intro"))
            HStack(spacing: .ostlerSpace2) {
                ProgressView().controlSize(.small)
                caption(copy("requesting"))
                Spacer()
            }

        case .showing(let code, let secondsLeft):
            para(copy("steps_heading"))
            VStack(alignment: .leading, spacing: 4) {
                caption("1. " + copy("step1"))
                caption("2. " + copy("step2"))
                caption("3. " + copy("step3"))
            }
            Text(WhatsAppPairCode.display(code))
                .font(.system(size: 40, weight: .semibold, design: .monospaced))
                .tracking(4)
                .foregroundStyle(Color.ostlerInk)
                .textSelection(.enabled)
                .padding(.vertical, .ostlerSpace1)
                .padding(.horizontal, .ostlerSpace3)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.ostlerOxblood.opacity(0.5), lineWidth: 2)
                )
            caption(ViewCopy.shared.string(
                for: "whatsapp_link.expires_in",
                fills: ["seconds": String(secondsLeft)]))
            HStack(spacing: .ostlerSpace2) {
                ProgressView().controlSize(.small)
                caption(copy("waiting"))
                Spacer()
            }
            HStack(spacing: .ostlerSpace2) {
                skipButton
                Spacer()
            }

        case .expired:
            para(copy("expired"))
            HStack(spacing: .ostlerSpace2) {
                primaryButton(copy("new_code_button"), action: askForCode)
                skipButton
                Spacer()
            }

        case .failed:
            para(copy("failed"))
            HStack(spacing: .ostlerSpace2) {
                primaryButton(copy("try_again_button"), action: askForCode)
                skipButton
                Spacer()
            }

        case .skipped:
            para(copy("skipped"))
            commandLine
            HStack(spacing: .ostlerSpace2) {
                Button(copy("connect_now_button")) { skipped = false }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Spacer()
            }

        case .noPhoneNumber:
            para(copy("no_phone"))
            commandLine
        }
    }

    // MARK: - Pieces

    private func para(_ text: String) -> some View {
        Text(text)
            .font(.ostlerBody)
            .foregroundStyle(Color.ostlerInk)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.ostlerCaption)
            .foregroundStyle(Color.ostlerInkSubdued)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .padding(.horizontal, .ostlerSpace2)
                .padding(.vertical, 4)
        }
        .buttonStyle(.borderedProminent)
        .tint(.ostlerOxblood)
    }

    private var skipButton: some View {
        Button(copy("skip_button")) { skipped = true }
            .buttonStyle(.bordered)
    }

    private var commandLine: some View {
        Text(copy("later_command"))
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(Color.ostlerInk)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Behaviour

    private func askForCode() {
        requestStartedAt = Int(Date().timeIntervalSince1970)
        now = requestStartedAt ?? now
        let io = self.io
        // launchctl blocks for the length of the restart; keep it off the
        // main actor so the spinner keeps turning.
        Task.detached(priority: .userInitiated) {
            io.requestNewCode()
        }
    }

    /// Re-read the three surfaces once a second while the section is on
    /// screen. The pair file and config are tiny; the session DB is a single
    /// COUNT on a read-only connection, so it is read every third tick.
    private func pollLoop() async {
        var tick = 0
        while !Task.isCancelled {
            let t = Int(Date().timeIntervalSince1970)
            let io = self.io
            let readLinked = (tick % 3 == 0)
            let snapshot = await Task.detached(priority: .utility) { () -> (WhatsAppConfig, WhatsAppPairCode, WhatsAppLinkedState?) in
                let cfg = io.readConfig()
                let p = io.readPair(now: t)
                let l = readLinked ? cfg.sessionPath.map { WhatsAppSession.linkedState(sessionPath: $0) } : nil
                return (cfg, p, l)
            }.value
            config = snapshot.0
            pair = snapshot.1
            if let l = snapshot.2 { linked = l }
            now = t
            loaded = true
            if linked == .linked { return }
            tick += 1
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }
}
