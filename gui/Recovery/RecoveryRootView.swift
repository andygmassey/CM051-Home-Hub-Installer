// RecoveryRootView.swift
//
// Three screens, one window, exactly per Andy's spec: "a text entry box
// with layman's explanation before and afterwards, with clear button(s)".
// No settings, no menus, no logs, no advanced options.

import SwiftUI

/// Customer copy, from the installer's catalogue (Resources/ViewCopy*.json,
/// bundled into this app) in the Mac's language (InstallerLanguage).
private func copy(_ key: String, _ fills: [String: String] = [:]) -> String {
    ViewCopy.shared.string(for: "recovery_app." + key, fills: fills)
}

struct RecoveryRootView: View {
    @EnvironmentObject private var coordinator: RecoveryCoordinator

    var body: some View {
        ZStack {
            Color.ostlerChassis.ignoresSafeArea()

            switch coordinator.screen {
            case .enterKey:
                EnterKeyView()
            case .working:
                WorkingView()
            case .success:
                ResultView(
                    title: copy("success_title"),
                    message: copy("success_message"),
                    isSuccess: true
                )
            case .failure:
                ResultView(
                    title: failureTitle,
                    message: failureMessage,
                    isSuccess: false
                )
            }
        }
        .environmentObject(coordinator)
    }

    private var failureTitle: String {
        switch coordinator.failureReason {
        case .wrongKey: return copy("wrong_key_title")
        case .toolMissing, .couldNotStart: return copy("tool_missing_title")
        }
    }

    private var failureMessage: String {
        switch coordinator.failureReason {
        case .wrongKey:
            return copy("wrong_key_message")
        case .toolMissing, .couldNotStart:
            return copy("tool_missing_message", ["email": "hello@ostler.ai"])
        }
    }
}

// MARK: - Screen 1: before

private struct EnterKeyView: View {
    @EnvironmentObject private var coordinator: RecoveryCoordinator
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: .ostlerSpace4) {
            Text(copy("heading"))
                .font(.ostlerH2)
                .foregroundColor(.ostlerInk)

            Text(copy("intro"))
            .font(.ostlerBody)
            .foregroundColor(.ostlerInkMuted)
            .fixedSize(horizontal: false, vertical: true)

            TextField(copy("key_placeholder"), text: $coordinator.keyInput)
                .textFieldStyle(.plain)
                .font(.ostlerMono)
                .padding(.ostlerSpace3)
                .background(Color.ostlerPanel)
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.ostlerHairlineSoft, lineWidth: 1)
                )
                .focused($fieldFocused)
                .onSubmit { coordinator.submit() }

            Button(copy("unlock_button")) { coordinator.submit() }
                .buttonStyle(.ostlerPrimary)
                .disabled(!coordinator.canSubmit)
                .frame(maxWidth: .infinity)

            Spacer(minLength: 0)
        }
        .padding(.ostlerSpace5)
        .onAppear { fieldFocused = true }
    }
}

// MARK: - Screen 2: working

private struct WorkingView: View {
    var body: some View {
        VStack(spacing: .ostlerSpace3) {
            ProgressView()
                .controlSize(.large)
                .tint(.ostlerOxblood)
            Text(copy("checking"))
                .font(.ostlerBody)
                .foregroundColor(.ostlerInkMuted)
        }
        .padding(.ostlerSpace5)
    }
}

// MARK: - Screen 3: after

private struct ResultView: View {
    @EnvironmentObject private var coordinator: RecoveryCoordinator
    let title: String
    let message: String
    let isSuccess: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: .ostlerSpace4) {
            Text(title)
                .font(.ostlerH2)
                .foregroundColor(.ostlerInk)

            Text(message)
                .font(.ostlerBody)
                .foregroundColor(.ostlerInkMuted)
                .fixedSize(horizontal: false, vertical: true)

            if isSuccess {
                Button(copy("done")) { NSApp.terminate(nil) }
                    .buttonStyle(.ostlerPrimary)
                    .frame(maxWidth: .infinity)
            } else {
                Button(copy("try_again")) { coordinator.tryAgain() }
                    .buttonStyle(.ostlerPrimary)
                    .frame(maxWidth: .infinity)
            }

            Spacer(minLength: 0)
        }
        .padding(.ostlerSpace5)
    }
}
