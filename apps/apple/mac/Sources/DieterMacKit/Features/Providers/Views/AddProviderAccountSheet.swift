import DieterClientAPI
import SwiftUI

/// Adds a Claude or ChatGPT account, then goes straight into its first
/// sign-in on the machine the user picks: this Mac's own machine when it has
/// one. The sign-in continues in this sheet, so no second sheet stacks on it.
struct AddProviderAccountSheet: View {
    @Environment(DieterStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var provider: String
    @State private var label = ""
    @State private var method = AddProviderAccountSheet.codex
    @State private var daemonID = ""
    @State private var adding = false
    /// The first sign-in, once it started.
    @State private var sessionID: String?
    /// The account exists, but its first sign-in could not start; adding
    /// again would add a second account.
    @State private var added = false

    static let claude = "claude"
    static let chatGPT = "chatgpt"
    static let codex = "codex"
    static let signInWithChatGPT = "siwc"

    init(provider: String) {
        _provider = State(initialValue: provider == Self.chatGPT ? Self.chatGPT : Self.claude)
    }

    private var providers: ProvidersModel { store.providersModel }
    private var normalized: String { label.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var onlineMachines: [MachineEndpoint] { store.machines.filter(\.online) }
    /// Sign in with ChatGPT carries OpenAI's own button wording.
    private var continueTitle: String {
        if provider == Self.chatGPT && method == Self.signInWithChatGPT { return "Continue with ChatGPT" }
        return daemonID.isEmpty ? "Add account" : "Add and sign in"
    }

    var body: some View {
        if let sessionID {
            ProviderSignInSheet(sessionID: sessionID, replace: { self.sessionID = $0 }, close: { dismiss() })
                .environment(store)
        } else {
            form
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add account").font(.title2.weight(.bold))
            Text("Agent turns run on the account you choose. Dieter never sees its password or tokens.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 12) {
                Picker("Provider", selection: $provider) {
                    Text("Claude").tag(Self.claude)
                    Text("ChatGPT").tag(Self.chatGPT)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("Provider")
                .accessibilityIdentifier("providers.add.provider")
                TextField(
                    "Name", text: $label,
                    prompt: Text(provider == Self.claude ? "Name, e.g. Work" : "Name, e.g. Personal")
                )
                .textFieldStyle(.roundedBorder)
                .onSubmit { add() }
                .accessibilityIdentifier("providers.add.label")
                .e2eTarget("providers.add.label")
                if provider == Self.chatGPT {
                    Picker("Sign in with", selection: $method) {
                        Text("Codex sign-in").tag(Self.codex)
                        Text("Sign in with ChatGPT").tag(Self.signInWithChatGPT)
                    }
                    .accessibilityIdentifier("providers.add.method")
                }
                Picker("Sign in on", selection: $daemonID) {
                    ForEach(onlineMachines) { machine in
                        Text(
                            machine.daemonID == store.localMachine?.daemonID
                                ? "\(machine.name) (this Mac)" : machine.name
                        )
                        .tag(machine.daemonID ?? "")
                    }
                    Text("Later").tag("")
                }
                .accessibilityIdentifier("providers.add.machine")
            }
            .disabled(added)
            if let failure = providers.failure {
                Text(failure).font(.caption).foregroundStyle(DieterTheme.coral)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("providers.add.failure")
            }
            HStack {
                if adding { ProgressView().controlSize(.small) }
                Spacer()
                if !added {
                    Button("Cancel") { dismiss() }
                        .buttonStyle(DieterBarButtonStyle())
                        .keyboardShortcut(.cancelAction)
                }
                if added {
                    Button("Done") { dismiss() }
                        .buttonStyle(DieterBarButtonStyle(prominent: true))
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(continueTitle) { add() }
                        .buttonStyle(DieterBarButtonStyle(prominent: true))
                        .keyboardShortcut(.defaultAction)
                        .disabled(adding || normalized.isEmpty)
                        .accessibilityIdentifier("providers.add.submit")
                        .e2eTarget("providers.add.submit", text: continueTitle)
                }
            }
        }
        .padding(24)
        .frame(width: 480)
        .onAppear {
            providers.failure = nil
            let local = onlineMachines.first { $0.daemonID == store.localMachine?.daemonID }
            daemonID = (local ?? onlineMachines.first)?.daemonID ?? ""
        }
    }

    private func add() {
        guard !adding, !normalized.isEmpty else { return }
        adding = true
        let chosenMethod = provider == Self.chatGPT ? method : ""
        Task {
            let result = await providers.add(
                provider: provider, label: normalized, method: chosenMethod, daemonID: daemonID)
            adding = false
            guard let result else { return }
            if let session = result.sessionID {
                sessionID = session
            } else if providers.failure == nil {
                dismiss()
            } else {
                added = true
            }
        }
    }
}
