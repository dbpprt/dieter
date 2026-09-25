#if os(iOS)
    import SwiftUI

    struct IOSGatewayView: View {
        @Bindable var store: IOSStore
        @State private var token = ""
        @State private var tokenExpanded = false

        var body: some View {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 14) {
                        Image(systemName: "terminal")
                            .font(.system(size: 42, weight: .medium))
                            .foregroundStyle(.tint)
                            .accessibilityHidden(true)
                        Text("Your workspace, wherever you are")
                            .font(.title2.bold())
                        Text("Connect to your Dieter gateway to open projects and work with agents on your machines.")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 18)
                    .listRowBackground(Color.clear)
                }
                Section("Gateway") {
                    TextField("https://dieter.example.com", text: $store.gatewayAddress)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityLabel("Gateway address")
                        .accessibilityIdentifier("ios.auth.gateway")
                    Button {
                        Task { await store.signIn() }
                    } label: {
                        HStack {
                            Label("Sign in with GitHub", systemImage: "person.crop.circle.badge.checkmark")
                            Spacer()
                            if store.busy { ProgressView() }
                        }
                    }
                    .disabled(
                        store.busy || store.gatewayAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                    .accessibilityIdentifier("ios.auth.sign-in")
                    #if DEBUG
                        if ProcessInfo.processInfo.environment["DIETER_IOS_TEST_START_SIGNED_OUT"] == "1" {
                            Button("Connect isolated test session") {
                                let token = ProcessInfo.processInfo.environment["DIETER_IOS_TEST_TOKEN"] ?? ""
                                Task { await store.connectWithToken(token) }
                            }
                            .disabled(store.busy)
                            .accessibilityIdentifier("ios.auth.test-connect")
                        }
                    #endif
                }
                Section {
                    DisclosureGroup("Use an existing access token", isExpanded: $tokenExpanded) {
                        SecureField("Access token", text: $token)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("ios.auth.token-field")
                        Button("Connect with token") {
                            let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
                            Task {
                                await store.connectWithToken(value)
                                if store.isAuthenticated { token = "" }
                            }
                        }
                        .disabled(store.busy || token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("ios.auth.connect-token")
                    }
                    .accessibilityIdentifier("ios.auth.token-options")
                } footer: {
                    Text("Use a token issued by your gateway. Credentials are stored in your device’s Keychain.")
                }
                if store.busy {
                    Section { Label(store.phase.label, systemImage: "network").foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("Connect to Dieter")
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("ios.auth")
        }
    }

    struct IOSSettingsView: View {
        @Environment(\.dismiss) private var dismiss
        @Bindable var store: IOSStore
        @State private var signOutPresented = false

        var body: some View {
            Form {
                Section("Connection") {
                    LabeledContent("Gateway", value: store.gatewayAddress)
                        .lineLimit(2)
                    LabeledContent(
                        "Compatible machines",
                        value:
                            "\(store.supportedMachines.filter(\.online).count) online · \(store.supportedMachines.count) enrolled"
                    )
                    LabeledContent("Status", value: store.phase.label)
                    Button("Reconnect", systemImage: "arrow.clockwise") {
                        Task { await store.reconnect() }
                    }
                    .disabled(store.busy)
                    .accessibilityIdentifier("ios.settings.reconnect")
                    Button("Refresh machines", systemImage: "desktopcomputer") {
                        Task { await store.refreshMachines() }
                    }
                    .disabled(store.busy)
                }
                if !store.providerQuotaGroups.isEmpty || store.providerQuotasLoading {
                    Section("Provider quotas") {
                        ForEach(store.providerQuotaGroups, id: \.provider.rawValue) { group in
                            HStack {
                                Label(
                                    group.provider == .openaiCodex ? "OpenAI" : "Claude",
                                    systemImage: group.provider == .openaiCodex ? "sparkles" : "brain.head.profile")
                                Spacer()
                                if group.hasSummary, group.summary.hasRemainingPercent {
                                    Text("\(group.summary.remainingPercent)%")
                                        .monospacedDigit()
                                        .foregroundStyle(group.provider == .openaiCodex ? .blue : .orange)
                                }
                                Text("\(group.summary.includedAccountCount)/\(group.summary.totalAccountCount)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Button("Refresh quotas", systemImage: "arrow.clockwise") {
                            Task { await store.loadProviderQuotas(requestRefresh: true) }
                        }
                        .disabled(store.providerQuotasLoading)
                    }
                }
                Section {
                    Button("Sign out", role: .destructive) { signOutPresented = true }
                        .accessibilityIdentifier("ios.settings.sign-out")
                } footer: {
                    Text("Sign out to connect to another gateway. Running agents continue on their machines.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("ios.settings.done")
                }
            }
            .confirmationDialog("Sign out of Dieter?", isPresented: $signOutPresented, titleVisibility: .visible) {
                Button("Sign out", role: .destructive) {
                    Task {
                        await store.signOut(); dismiss()
                    }
                }
            } message: {
                Text("Your saved access token will be removed from this device.")
            }
        }
    }
#endif
