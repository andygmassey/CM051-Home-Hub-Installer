// PromptSheet.swift
//
// Generic prompt UI for every #OSTLER PROMPT marker. Phase 1
// renders all kinds via a TextField/SecureField/Toggle/Picker –
// Phase 2 adds bespoke UIs (passphrase strength meter, country
// picker, channel chooser).

import SwiftUI

struct PromptSheet: View {
    @EnvironmentObject private var coordinator: InstallerCoordinator
    let prompt: InstallerCoordinator.PendingPrompt

    @State private var textValue: String = ""
    @State private var secretValue: String = ""
    @State private var yesnoValue: Bool = true
    @State private var choiceValue: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(prompt.title)
                .font(.headline)
            if let help = prompt.help {
                Text(help)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            inputField

            HStack {
                Spacer()
                Button("Cancel") {
                    coordinator.respond(to: prompt, with: prompt.defaultValue ?? "")
                }
                Button("Continue") {
                    coordinator.respond(to: prompt, with: currentAnswer())
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 500)
        .onAppear {
            // Seed defaults.
            textValue = prompt.defaultValue ?? ""
            secretValue = ""
            yesnoValue = (prompt.defaultValue?.lowercased().hasPrefix("y") ?? true)
            choiceValue = prompt.defaultValue ?? prompt.choices.first ?? ""
            focused = true
        }
    }

    @ViewBuilder
    private var inputField: some View {
        switch prompt.kind {
        case .text:
            TextField("", text: $textValue)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
        case .secret:
            SecureField("", text: $secretValue)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
        case .yesno:
            Toggle(isOn: $yesnoValue) {
                Text(yesnoValue ? "Yes" : "No")
            }
            .toggleStyle(.switch)
        case .choice:
            Picker("", selection: $choiceValue) {
                ForEach(prompt.choices, id: \.self) { c in
                    Text(c).tag(c)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private func currentAnswer() -> String {
        switch prompt.kind {
        case .text:   return textValue
        case .secret: return secretValue
        case .yesno:  return yesnoValue ? "y" : "n"
        case .choice: return choiceValue
        }
    }
}
