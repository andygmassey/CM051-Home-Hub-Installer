// RecoveryRootView.swift
//
// Three screens, one window, exactly per Andy's spec: "a text entry box
// with layman's explanation before and afterwards, with clear button(s)".
// No settings, no menus, no logs, no advanced options.

import SwiftUI

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
                    title: "You're unlocked",
                    message: "Ostler can open your data again. "
                        + "Quit and reopen the Ostler app to keep going.",
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
        case .wrongKey: return "That key wasn't accepted"
        case .toolMissing, .couldNotStart: return "Couldn't check your key"
        }
    }

    private var failureMessage: String {
        switch coordinator.failureReason {
        case .wrongKey:
            return "The most common reason is a small typo. Check each "
                + "group of letters and numbers and try again."
        case .toolMissing, .couldNotStart:
            return "Ostler's recovery tool couldn't be found on this Mac. "
                + "If you've just installed Ostler, try again in a minute. "
                + "If this keeps happening, contact support."
        }
    }
}

// MARK: - Screen 1: before

private struct EnterKeyView: View {
    @EnvironmentObject private var coordinator: RecoveryCoordinator
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: .ostlerSpace4) {
            Text("Recover Ostler")
                .font(.ostlerH2)
                .foregroundColor(.ostlerInk)

            Text(
                "If Ostler has stopped opening your data, you can unlock it "
                + "yourself with the recovery key you were shown when Ostler "
                + "was set up. It's a code made of groups of four letters "
                + "and numbers, like ABCD-EFGH-JKLM-NPQR. Type it in below, "
                + "exactly as it was shown to you."
            )
            .font(.ostlerBody)
            .foregroundColor(.ostlerInkMuted)
            .fixedSize(horizontal: false, vertical: true)

            TextField("Recovery key", text: $coordinator.keyInput)
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

            Button("Unlock my data") { coordinator.submit() }
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
            Text("Checking your recovery key…")
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
                Button("Done") { NSApp.terminate(nil) }
                    .buttonStyle(.ostlerPrimary)
                    .frame(maxWidth: .infinity)
            } else {
                Button("Try again") { coordinator.tryAgain() }
                    .buttonStyle(.ostlerPrimary)
                    .frame(maxWidth: .infinity)
            }

            Spacer(minLength: 0)
        }
        .padding(.ostlerSpace5)
    }
}
