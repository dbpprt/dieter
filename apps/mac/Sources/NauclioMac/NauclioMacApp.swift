import AppKit
import SwiftUI

@main
struct NauclioMacApp: App {
    @State private var store = NauclioStore()

    var body: some Scene {
        WindowGroup("Nauclio") {
            NauclioRootView()
                .environment(store)
                .preferredColorScheme(.dark)
                .onOpenURL { store.completeAuthentication(url: $0) }
                .task {
                    await store.connect()
                    if ProcessInfo.processInfo.arguments.contains("--ui-smoke") {
                        await NativeUISmokeRunner.run(store: store)
                    }
                }
                .frame(minWidth: 1_080, minHeight: 680)
        }
        .defaultSize(width: 1_380, height: 870)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    NSApp.activate(ignoringOtherApps: true)
                    store.openSettings()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            CommandMenu("Nauclio") {
                Button("Command Palette…") { store.commandPalettePresented = true }
                    .keyboardShortcut("k", modifiers: .command)
                Button("New Card…") { store.createConversationPresented = true }
                    .keyboardShortcut("n", modifiers: .command)
                Button("New Standalone Chat") { store.beginStandaloneChat() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Divider()
                Button("Refresh") { Task { await store.refreshState() } }
                    .keyboardShortcut("r", modifiers: .command)
            }
        }

        MenuBarExtra {
            MenuBarContent()
                .environment(store)
        } label: {
            NauclioBrandIcon(size: 18)
                .opacity(store.phase.isConnected ? 1 : 0.58)
                .accessibilityLabel(store.phase.isConnected ? "Nauclio connected" : "Nauclio disconnected")
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarContent: View {
    @Environment(NauclioStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Circle().fill(store.phase.isConnected ? NauclioTheme.seafoam : NauclioTheme.coral).frame(width: 8, height: 8)
                Text(store.phase.label).font(.headline)
                Spacer()
                Text(store.endpoint.address).foregroundStyle(.secondary)
            }
            if !store.state.cards.filter({ ["running", "review", "waiting"].contains($0.runtime) }).isEmpty {
                Divider()
                ForEach(store.state.cards.filter { ["running", "review", "waiting"].contains($0.runtime) }.prefix(5), id: \.id) { card in
                    Button {
                        NSApp.activate(ignoringOtherApps: true)
                        Task { await store.openConversation(cardID: card.id) }
                    } label: {
                        HStack {
                            StatusPill(text: card.runtime, color: runtimeColor(card.runtime))
                            Text(card.title).lineLimit(1)
                        }
                    }.buttonStyle(.plain)
                }
            }
            Divider()
            Button("Open Nauclio") { NSApp.activate(ignoringOtherApps: true) }
            Button(store.phase.isConnected ? "Reconnect" : "Connect") { Task { await store.connect() } }
            Button("Settings…") {
                NSApp.activate(ignoringOtherApps: true)
                store.openSettings()
            }
            Divider()
            Button("Quit Nauclio") { NSApp.terminate(nil) }
        }
        .padding(14)
        .frame(width: 340)
    }
}
