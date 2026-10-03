#if os(iOS)
    import DieterAPI
    import DieterShared
    import SharedCore
    import SwiftUI

    /// Sign-in: GitHub through the gateway in the native sheet, or a session
    /// token issued by the gateway. The core owns the exchange and keeps the
    /// session in the Keychain.
    struct IOSGatewayView: View {
        @Environment(IOSAppModel.self) private var app
        @State private var address = ""
        @State private var token = ""
        @State private var tokenExpanded = false
        @State private var adopting = false

        private var origin: String { app.gatewayOrigin(address) }
        private var busy: Bool { app.signingIn || adopting }

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
                Section {
                    TextField("https://dieter.example.com", text: $address)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityLabel("Gateway address")
                        .accessibilityIdentifier("ios.auth.gateway")
                    Button {
                        Task { await app.signIn(gatewayAddress: address) }
                    } label: {
                        HStack {
                            Label("Sign in with GitHub", systemImage: "person.crop.circle.badge.checkmark")
                            Spacer()
                            if busy { ProgressView() }
                        }
                    }
                    .disabled(busy || origin.isEmpty)
                    .accessibilityIdentifier("ios.auth.sign-in")
                    #if DEBUG
                        if let test = app.launch.signedOutTestSession {
                            Button("Connect isolated test session") {
                                Task { await adopt(gatewayAddress: test.gatewayURL, token: test.token) }
                            }
                            .disabled(busy)
                            .accessibilityIdentifier("ios.auth.test-connect")
                        }
                    #endif
                } header: {
                    Text("Gateway")
                } footer: {
                    if !app.session.error.isEmpty {
                        Text(app.session.error)
                            .foregroundStyle(.orange)
                            .accessibilityIdentifier("ios.auth.error")
                    }
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
                                if await adopt(gatewayAddress: address, token: value) { token = "" }
                            }
                        }
                        .disabled(busy || origin.isEmpty || token.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("ios.auth.connect-token")
                    }
                    .accessibilityIdentifier("ios.auth.token-options")
                } footer: {
                    Text("Use a token issued by your gateway. Credentials are stored in your device’s Keychain.")
                }
            }
            .navigationTitle("Connect to Dieter")
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("ios.auth")
            .onAppear {
                if address.isEmpty { address = app.session.gatewayOrigin }
            }
            .onChange(of: app.session.gatewayOrigin) { _, origin in
                if address.isEmpty { address = origin }
            }
        }

        @discardableResult
        private func adopt(gatewayAddress: String, token: String) async -> Bool {
            adopting = true
            defer { adopting = false }
            return await app.adoptSession(gatewayAddress: gatewayAddress, token: token)
        }
    }

    /// The connection, the gateways this device knows, and sign-out.
    struct IOSSettingsView: View {
        @Environment(\.dismiss) private var dismiss
        @Environment(IOSAppModel.self) private var app
        @Environment(IOSWorkspaceNavigation.self) private var navigation
        @State private var signOutPresented = false
        @State private var addingGateway = false

        var body: some View {
            let session = app.session
            Form {
                Section("Connection") {
                    LabeledContent("Status", value: session.phaseLabel)
                        .accessibilityIdentifier("ios.settings.status")
                    if session.hasGatewayBuild {
                        LabeledContent(
                            "Gateway version",
                            value: SharedRules.shared.softwareVersion(
                                version: session.gatewayBuild.releaseVersion,
                                revision: session.gatewayBuild.sourceRevision))
                    }
                    Button("Reconnect", systemImage: "arrow.clockwise") {
                        Task { await app.reconnect() }
                    }
                    .accessibilityIdentifier("ios.settings.reconnect")
                    Button("Machines", systemImage: "desktopcomputer") {
                        navigation.sheet = .machines
                    }
                    .accessibilityIdentifier("ios.settings.machines")
                }
                Section {
                    ForEach(session.gateways, id: \.origin) { gateway in
                        Button {
                            Task { await app.selectGateway(gateway.origin) }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(gateway.name.isEmpty ? gateway.origin : gateway.name)
                                        .foregroundStyle(.primary)
                                    if !gateway.name.isEmpty {
                                        Text(gateway.origin).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if gateway.active {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                        .accessibilityLabel("Active")
                                }
                            }
                        }
                        .accessibilityIdentifier("ios.settings.gateway.\(gateway.origin)")
                        .swipeActions {
                            Button("Remove", role: .destructive) {
                                Task { await app.removeGateway(gateway.origin) }
                            }
                        }
                    }
                    Button("Add gateway", systemImage: "plus") { addingGateway = true }
                        .accessibilityIdentifier("ios.settings.add-gateway")
                } header: {
                    Text("Gateways")
                } footer: {
                    Text("Each gateway signs in separately.")
                }
                Section {
                    Button("Sign out", role: .destructive) { signOutPresented = true }
                        .accessibilityIdentifier("ios.settings.sign-out")
                } footer: {
                    Text("Sign out to connect to another account. Running agents continue on their machines.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("ios.settings.done")
                }
            }
            .sheet(isPresented: $addingGateway) {
                NavigationStack { IOSAddGatewayView() }
                    .presentationDetents([.medium])
            }
            .confirmationDialog("Sign out of Dieter?", isPresented: $signOutPresented, titleVisibility: .visible) {
                Button("Sign out", role: .destructive) {
                    Task {
                        await app.signOut()
                        dismiss()
                    }
                }
            } message: {
                Text("Your session and this device’s unsent changes for this account are removed.")
            }
        }
    }

    /// Adds a gateway and makes it active; it then asks to sign in.
    private struct IOSAddGatewayView: View {
        @Environment(\.dismiss) private var dismiss
        @Environment(IOSAppModel.self) private var app
        @State private var address = ""
        @State private var name = ""
        @State private var saving = false

        var body: some View {
            Form {
                TextField("https://dieter.example.com", text: $address)
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityLabel("Gateway address")
                    .accessibilityIdentifier("ios.settings.gateway-address")
                TextField("Name (optional)", text: $name)
                    .accessibilityIdentifier("ios.settings.gateway-name")
            }
            .navigationTitle("Add Gateway")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        saving = true
                        Task {
                            let added = await app.useGateway(
                                address: address, name: name.trimmingCharacters(in: .whitespacesAndNewlines))
                            saving = false
                            if added { dismiss() }
                        }
                    }
                    .disabled(saving || app.gatewayOrigin(address).isEmpty)
                    .accessibilityIdentifier("ios.settings.gateway-add")
                }
            }
        }
    }
#endif
