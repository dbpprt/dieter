import DieterClientAPI
import DieterCore
import SwiftUI

struct GeneralSettings: View {
    @Environment(DieterStore.self) private var store
    @State private var archiveConfirmation = false

    /// The machine that runs the selected project's work.
    private var projectMachine: MachineEndpoint? { store.projectMachine(forProjectID: store.selectedProjectID) }

    /// What the selected project's machine reports about itself; empty until it does.
    private var projectMetadata: ClientMachineMetadata {
        projectMachine?.daemonID.flatMap { store.machineMetadata[$0] } ?? ClientMachineMetadata()
    }

    var body: some View {
        SettingsPage {
            VStack(spacing: 14) {
                if !store.failedOutboxItems.isEmpty {
                    SettingsPanel(
                        title: "Failed queued operations",
                        subtitle: "Queued prompt data is preserved until you explicitly retry or discard it."
                    ) {
                        ForEach(store.failedOutboxItems) { item in
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.operation).font(.system(size: 12, weight: .semibold))
                                    Text(item.targetID).font(.caption2.monospaced()).foregroundStyle(
                                        DieterTheme.tertiary)
                                    Text(item.failure).font(.caption).foregroundStyle(DieterTheme.coral).textSelection(
                                        .enabled)
                                    Text(item.createdAt.formatted()).font(.caption2).foregroundStyle(
                                        DieterTheme.tertiary)
                                }
                                Spacer()
                                Button("Retry") { Task { await store.retryOutboxItem(item.id) } }
                                    .buttonStyle(DieterBarButtonStyle(size: 28))
                                Button("Discard", role: .destructive) {
                                    Task { await store.discardOutboxItem(item.id) }
                                }
                                .buttonStyle(DieterBarButtonStyle(destructive: true, size: 28))
                            }
                            if item.id != store.failedOutboxItems.last?.id { Divider().overlay(DieterTheme.border) }
                        }
                    }
                }
                SettingsPanel(
                    title: "Appearance",
                    subtitle: "Choose how Dieter looks on this Mac. Changes apply immediately to every window."
                ) {
                    HStack(spacing: 9) {
                        ForEach(DieterAppearance.allCases) { appearance in
                            AppearanceOption(
                                appearance: appearance,
                                selected: appearance == store.themeSelection.appearance
                            ) {
                                store.themeSelection.appearance = appearance
                            }
                        }
                    }
                    Divider().overlay(DieterTheme.border)
                    Toggle(
                        "Window transparency",
                        isOn: Binding(
                            get: { store.themeSelection.transparencyEnabled },
                            set: { store.themeSelection.transparencyEnabled = $0 }
                        )
                    )
                    .accessibilityIdentifier("settings.windowTransparency")
                    .e2eTarget("settings.windowTransparency")
                    Text("Let the desktop show through blurred workspace surfaces.")
                        .font(.caption)
                        .foregroundStyle(DieterTheme.tertiary)
                    if DieterTransparencyAccessibility.shared.reduceTransparency {
                        Text("macOS Reduce Transparency is on. Dieter uses solid surfaces and keeps your preference.")
                            .font(.caption)
                            .foregroundStyle(DieterTheme.subtle)
                    }
                }
                SettingsPanel(
                    title: "Design",
                    subtitle: "Changes every Dieter surface, terminal, accent, and the running app icon."
                ) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 9), count: 4), spacing: 9) {
                        ForEach(DieterPalette.allCases) { palette in
                            PaletteOption(
                                palette: palette,
                                selected: palette == store.themeSelection.palette
                            ) {
                                store.themeSelection.palette = palette
                            }
                        }
                    }
                }
                SettingsPanel(
                    title: "Conversations",
                    subtitle:
                        "Choose what appears in every conversation timeline. This preference is saved on this Mac."
                ) {
                    HStack(spacing: 10) {
                        Text("Default layout")
                        Spacer(minLength: 0)
                        DieterSegmentedPicker(
                            "Default layout",
                            selection: Binding(
                                get: { store.defaultConversationMode },
                                set: { store.defaultConversationMode = $0 }
                            ),
                            options: ConversationDefaultMode.allCases,
                            optionTitle: { $0 == .tabs ? "Tabs" : "Workspace" }
                        )
                        .accessibilityIdentifier("settings.conversation.defaultMode")
                    }
                    Text("Applies when you open a different card or chat. You can still switch layouts in its header.")
                        .font(.caption)
                        .foregroundStyle(DieterTheme.tertiary)
                    Divider().overlay(DieterTheme.border)
                    Toggle(
                        "Show reasoning traces",
                        isOn: Binding(
                            get: { store.showReasoning },
                            set: { store.showReasoning = $0 }
                        )
                    )
                    .accessibilityIdentifier("settings.showReasoningTraces")
                    Text(
                        "Reasoning traces are hidden by default. Turn this on to show them alongside messages and tool calls."
                    )
                    .font(.caption)
                    .foregroundStyle(DieterTheme.tertiary)
                }
                SettingsPanel(
                    title: "Screen sharing",
                    subtitle: "Control fullscreen input and unattended connections."
                ) {
                    Toggle(
                        "Capture keyboard in fullscreen",
                        isOn: Binding(
                            get: { store.screensModel.captureFullscreenKeyboard },
                            set: { store.screensModel.captureFullscreenKeyboard = $0 })
                    )
                    .toggleStyle(.switch)
                    .accessibilityIdentifier("settings.screenShare.captureKeyboard")
                    .e2eTarget("settings.screenShare.captureKeyboard")
                    Text("Forward system shortcuts such as ⌘Tab to the remote Mac. Press ⌘⇧Esc to release input.")
                        .font(.caption).foregroundStyle(DieterTheme.tertiary)
                    Text(
                        "Accessibility access is required and checked automatically. Manage it in System Settings → Privacy & Security → Accessibility."
                    )
                    .font(.caption).foregroundStyle(DieterTheme.tertiary)
                    Divider().overlay(DieterTheme.border)
                    Toggle(
                        "Disconnect inactive screen shares",
                        isOn: Binding(
                            get: { store.screensModel.inactivityTimeoutEnabled },
                            set: { store.screensModel.inactivityTimeoutEnabled = $0 }
                        )
                    )
                    .toggleStyle(.switch)
                    .accessibilityIdentifier("settings.screenShare.inactivityTimeoutEnabled")
                    .e2eTarget("settings.screenShare.inactivityTimeoutEnabled")
                    if store.screensModel.inactivityTimeoutEnabled {
                        Divider().overlay(DieterTheme.border)
                        Stepper(
                            "Disconnect after \(SharedRules.shared.count(count: Int32(clamping: store.screensModel.inactivityTimeoutMinutes), noun: "minute", plural: ""))",
                            value: Binding(
                                get: { store.screensModel.inactivityTimeoutMinutes },
                                set: { store.screensModel.inactivityTimeoutMinutes = $0 }
                            ),
                            in: 1...240
                        )
                        .accessibilityIdentifier("settings.screenShare.inactivityTimeoutMinutes")
                        .e2eTarget("settings.screenShare.inactivityTimeoutMinutes")
                    }
                    Text(
                        store.screensModel.inactivityTimeoutEnabled
                            ? "Mouse, keyboard, tab, and screen-option activity reset the timer. Open shares continue when you navigate elsewhere in Dieter."
                            : "Automatic disconnection is off. Screen shares stay open until you disconnect or close their tab."
                    )
                    .font(.caption)
                    .foregroundStyle(DieterTheme.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                SettingsPanel(
                    title: "Current project route",
                    subtitle: projectMachine.map { "Runs on \($0.name)" }
                        ?? "No machine has a checkout of this project."
                ) {
                    SettingsValueRow(title: "Runtime", value: projectMetadata.runtime.mode)
                    SettingsValueRow(title: "Ready", value: projectMetadata.runtime.ready ? "Yes" : "No")
                    SettingsValueRow(title: "Sandboxed", value: projectMetadata.runtime.sandboxed ? "Yes" : "No")
                }
                SettingsPanel(title: "Client") {
                    Toggle("Open Dieter at login", isOn: .constant(false)).disabled(true)
                    Text(
                        "The macOS client keeps no project metadata in working trees and communicates only through Dieter's authenticated API."
                    )
                    .font(.caption).foregroundStyle(DieterTheme.tertiary)
                }
                SettingsPanel(title: "Current project", subtitle: store.selectedProject?.name ?? "No project selected")
                {
                    HStack {
                        Text("Archiving hides the project without deleting Dieter data or its Git working tree.")
                            .font(.caption).foregroundStyle(DieterTheme.tertiary)
                        Spacer()
                        Button("Archive project…", role: .destructive) { archiveConfirmation = true }
                            .buttonStyle(DieterBarButtonStyle(destructive: true, size: 28))
                            .disabled(store.selectedProjectID.isEmpty)
                    }
                }
            }
        }
        .confirmationDialog("Archive \(store.selectedProject?.name ?? "project")?", isPresented: $archiveConfirmation) {
            Button("Archive project", role: .destructive) {
                Task { await store.setProjectArchived(id: store.selectedProjectID, archived: true) }
            }
        }
    }
}

private struct PaletteOption: View {
    let palette: DieterPalette
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: palette.previewColors, startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                    .overlay(Circle().stroke(.white.opacity(0.24)))
                    .frame(width: 24, height: 24)
                Text(palette.title)
                    .font(.system(size: 11, weight: selected ? .semibold : .medium))
                    .lineLimit(1)
                Spacer(minLength: 2)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(selected ? DieterTheme.shell : DieterTheme.tertiary)
            }
            .foregroundStyle(DieterTheme.text)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 44)
            .dieterTile(DieterTileState(selected: selected, hovering: hovering))
            .contentShape(RoundedRectangle(cornerRadius: DieterMetrics.cardRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("\(palette.title) design")
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityIdentifier("settings.palette.\(palette.rawValue)")
        .e2eTarget("settings.palette.\(palette.rawValue)")
    }
}

private struct AppearanceOption: View {
    let appearance: DieterAppearance
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: appearance.symbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(selected ? DieterTheme.shell : DieterTheme.subtle)
                    .frame(width: 24)
                Text(appearance.title)
                    .font(.system(size: 12, weight: selected ? .semibold : .medium))
                Spacer(minLength: 4)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(selected ? DieterTheme.shell : DieterTheme.tertiary)
            }
            .foregroundStyle(DieterTheme.text)
            .padding(.horizontal, 11)
            .frame(maxWidth: .infinity, minHeight: 46)
            .dieterTile(DieterTileState(selected: selected, hovering: hovering))
            .contentShape(RoundedRectangle(cornerRadius: DieterMetrics.cardRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("\(appearance.title) appearance")
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityIdentifier("settings.appearance.\(appearance.rawValue)")
        .e2eTarget("settings.appearance.\(appearance.rawValue)")
    }
}
