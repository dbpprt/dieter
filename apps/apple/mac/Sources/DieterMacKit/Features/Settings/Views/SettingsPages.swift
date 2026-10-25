import DieterClientAPI
import SwiftUI

struct UsageSettings: View {
    var body: some View {
        SettingsPage {
            SettingsPanel(
                title: "Provider quotas",
                subtitle: "Usage limits discovered across all online enrolled machines."
            ) {
                ProviderQuotaDetailsView()
            }
        }
    }
}

struct BrowserSettings: View {
    @State private var externalURLs: [String] = []
    @State private var newURL = ""
    @State private var invalidURL = false

    var body: some View {
        SettingsPage {
            SettingsPanel(
                title: "Always open externally",
                subtitle: "Matching links and sign-in redirects open in your default browser on this Mac."
            ) {
                Text(
                    "Add a host (github.com), a host and its subdomains (*.amazonaws.com), or an HTTP(S) URL path. Full URLs match that path and its children; hosts match exactly unless prefixed with *. "
                )
                .font(.caption).foregroundStyle(DieterTheme.subtle)
                .fixedSize(horizontal: false, vertical: true)
                ForEach(externalURLs, id: \.self) { entry in
                    HStack {
                        Text(entry).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                        Spacer()
                        Button("Remove", systemImage: "minus") {
                            externalURLs.removeAll { $0 == entry }
                            save()
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(DieterBarButtonStyle(shape: .circle, destructive: true, size: 24))
                        .accessibilityLabel("Remove \(entry)")
                    }
                    Divider().overlay(DieterTheme.border)
                }
                HStack {
                    TextField("Host or URL", text: $newURL)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addURL)
                        .accessibilityIdentifier("settings.browser.externalURL")
                    Button("Add", action: addURL)
                        .buttonStyle(DieterBarButtonStyle(size: 28))
                        .disabled(newURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("settings.browser.addExternalURL")
                }
                if invalidURL {
                    Text("Enter a valid host or HTTP(S) URL without a query or fragment.")
                        .font(.caption).foregroundStyle(DieterTheme.coral)
                }
            }
        }
        .onAppear { externalURLs = ExternalBrowserRules.entries() }
    }

    private func addURL() {
        guard let value = ExternalBrowserRules.normalized(newURL) else {
            invalidURL = true
            return
        }
        if !externalURLs.contains(value) { externalURLs.append(value) }
        save()
        newURL = ""
        invalidURL = false
    }

    private func save() {
        DieterAppearance.applicationDefaults().set(externalURLs, forKey: ExternalBrowserRules.storageKey)
    }
}

struct NotificationSettings: View {
    @Environment(DieterStore.self) private var store
    @State private var enabled = false

    var body: some View {
        SettingsPage {
            VStack(spacing: 14) {
                SettingsPanel(title: "Agent activity", subtitle: "Choose whether Dieter can alert you outside the app.")
                {
                    Toggle("Show macOS notifications", isOn: $enabled)
                        .onAppear { enabled = store.notificationsEnabled }
                        .onChange(of: enabled) { _, value in
                            guard value != store.notificationsEnabled else { return }
                            store.notificationsEnabled = value
                            if value { store.requestNotifications() }
                        }
                }
                MailNotificationSettings(model: store.mailModel)
                SettingsPanel(title: "Delivery") {
                    Text(
                        "Notifications come from state transitions on the synchronized Dieter stream. Clicking one opens the same durable conversation, or the message in Mail."
                    )
                    .font(.caption).foregroundStyle(DieterTheme.tertiary)
                }
            }
        }
    }
}

/// This Mac's mail preferences, kept by the core: a notification per new
/// message (or only important ones) and the unread count on the Dock icon.
private struct MailNotificationSettings: View {
    let model: MailModel

    var body: some View {
        let preferences = model.slice.preferences
        SettingsPanel(title: "Mail", subtitle: "Reports your agents send you.") {
            Toggle("New mail", isOn: binding(preferences.notify) { $0.notify = $1 })
                .toggleStyle(.switch)
                .accessibilityIdentifier("settings.notifications.mail")
            Toggle(
                "Only important mail", isOn: binding(preferences.notifyImportantOnly) { $0.notifyImportantOnly = $1 }
            )
            .toggleStyle(.switch)
            .disabled(!preferences.notify)
            .accessibilityIdentifier("settings.notifications.mail-important")
            Divider().overlay(DieterTheme.border)
            Toggle("Show unread mail count on the Dock icon", isOn: binding(preferences.appBadge) { $0.appBadge = $1 })
                .toggleStyle(.switch)
                .accessibilityIdentifier("settings.notifications.mail-badge")
        }
    }

    private func binding(
        _ value: Bool, _ set: @escaping (inout ClientMailPreferences, Bool) -> Void
    ) -> Binding<Bool> {
        Binding(
            get: { value },
            set: { on in Task { await model.updatePreferences { set(&$0, on) } } })
    }
}

struct IslandSettings: View {
    @AppStorage(DieterIslandPreferences.enabledKey, store: DieterAppearance.applicationDefaults())
    private var enabled = DieterIslandPreferences.defaultEnabled

    var body: some View {
        SettingsPage {
            VStack(spacing: 14) {
                SettingsPanel(
                    title: "Dieter Island",
                    subtitle: "See running conversations and replies needing attention while you work."
                ) {
                    Toggle("Show live activity around the notch", isOn: $enabled)
                        .font(.system(size: 12, weight: .semibold))
                        .toggleStyle(.switch)
                        .accessibilityIdentifier("settings.island.enabled")
                    Text(
                        "Hover the Island to expand a compact activity list. Choose a card or chat to open its conversation in Inbox."
                    )
                    .font(.caption)
                    .foregroundStyle(DieterTheme.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    DieterIslandSettingsPreview()
                        .opacity(enabled ? 1 : 0.42)
                        .animation(.easeOut(duration: 0.18), value: enabled)
                }
                SettingsPanel(title: "Display behavior") {
                    HStack(alignment: .top, spacing: 11) {
                        Image(systemName: "macbook")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(DieterTheme.primary)
                            .frame(width: 25)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Notch-aware on MacBook")
                                .font(.system(size: 12, weight: .semibold))
                            Text(
                                "Dieter aligns to the built-in camera housing. On a display without a notch, it becomes a floating pill at the top right."
                            )
                            .font(.caption)
                            .foregroundStyle(DieterTheme.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Divider().overlay(DieterTheme.border)
                    HStack(alignment: .top, spacing: 11) {
                        Image(systemName: "rectangle.on.rectangle")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(DieterTheme.eyes)
                            .frame(width: 25)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Available across Spaces")
                                .font(.system(size: 12, weight: .semibold))
                            Text(
                                "The Island follows macOS Spaces and remains available beside full-screen apps without taking keyboard focus."
                            )
                            .font(.caption)
                            .foregroundStyle(DieterTheme.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                SettingsPanel(title: "Activity source") {
                    Text(
                        "The Island shows the same running conversations, replies needing attention, and recent activity as Inbox."
                    )
                    .font(.caption)
                    .foregroundStyle(DieterTheme.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

struct ExperimentalSettings: View {
    @Environment(DieterStore.self) private var store

    var body: some View {
        SettingsPage {
            VStack(spacing: 14) {
                SettingsPanel(
                    title: "Agent channels",
                    subtitle: "Let agents of one project coordinate in a shared channel."
                ) {
                    ChannelsGlobalSetting(model: store.channelsModel)
                }
                SettingsPanel(
                    title: "Screen sharing resolution",
                    subtitle: "Match the remote desktop to your fullscreen display."
                ) {
                    HStack {
                        Text("Match remote resolution in fullscreen")
                            .font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Toggle(
                            "Match remote resolution in fullscreen",
                            isOn: Binding(
                                get: { store.screensModel.matchClientResolution },
                                set: { store.screensModel.matchClientResolution = $0 })
                        )
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .accessibilityLabel("Match remote resolution in fullscreen")
                        .accessibilityIdentifier("settings.experimental.screenResolution")
                        .e2eTarget("settings.experimental.screenResolution")
                    }
                    Text(
                        "Off by default. Temporarily changes the remote monitor for everyone using it, using the closest supported resolution and Retina scale. Restores on fullscreen exit or disconnect. Video quality limits still apply."
                    )
                    .font(.caption).foregroundStyle(DieterTheme.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

struct AgentSettings: View {
    @Environment(DieterStore.self) private var store

    var body: some View {
        SettingsPage {
            VStack(spacing: 14) {
                if store.machines.isEmpty {
                    SettingsPanel(title: "Harness capabilities") {
                        Text("No machines discovered yet.").font(.caption).foregroundStyle(DieterTheme.tertiary)
                    }
                }
                // Each machine runs its own agents.
                ForEach(store.machines) { machine in
                    let harnesses = store.harnessCatalog(forDaemon: machine.daemonID ?? "").harnesses
                    SettingsPanel(
                        title: machine.name,
                        subtitle: harnesses.isEmpty
                            ? (store.unavailableReason(machine) ?? "Loading agents…") : "Harness capabilities"
                    ) {
                        ForEach(harnesses, id: \.id) { harness in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(harness.name).font(.system(size: 12, weight: .semibold))
                                Text(harness.models.map(\.name).joined(separator: ", ")).font(.caption)
                                    .foregroundStyle(DieterTheme.tertiary)
                            }
                            if harness.id != harnesses.last?.id {
                                Divider().overlay(DieterTheme.border)
                            }
                        }
                    }
                }
            }
        }
    }
}
