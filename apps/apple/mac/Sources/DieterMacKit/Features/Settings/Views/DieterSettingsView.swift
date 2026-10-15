import DieterPlatform
import SwiftUI

enum DieterSettingsSection: String, CaseIterable, Identifiable, Hashable {
    case general = "General"
    case browser = "Browser"
    case connection = "Connection"
    case devices = "Devices"
    case usage = "Usage"
    case prompts = "Prompts"
    case notifications = "Notifications"
    case island = "Island"
    case agents = "Agents"
    case experimental = "Experimental"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .browser: "globe"
        case .connection: "network"
        case .devices: "lock.laptopcomputer"
        case .usage: "chart.bar.xaxis"
        case .prompts: "text.quote"
        case .notifications: "bell"
        case .island: "capsule.tophalf.filled"
        case .agents: "person.2"
        case .experimental: "flask"
        }
    }

    var subtitle: String {
        switch self {
        case .general: "Server, client, and project preferences"
        case .browser: "Choose which websites leave the workspace browser"
        case .connection: "Machines, gateways, and authentication"
        case .devices: "Trusted devices and end-to-end encryption"
        case .usage: "Provider accounts, limits, and reset windows"
        case .prompts: "Global and scoped agent instructions"
        case .notifications: "macOS alerts for agent activity"
        case .island: "Live activity around the notch"
        case .agents: "Harness capabilities"
        case .experimental: "Preview features that are still being refined"
        }
    }
}

struct DieterSettingsView: View {
    @Environment(DieterStore.self) private var store

    var body: some View {
        DieterSectionScaffold(showsQuickTask: false) {
            DieterTitleCapsule(title: "Settings", symbol: "gearshape", detail: "Dieter for macOS")
        } trailing: {
            EmptyView()
        } content: {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    VStack(spacing: 1) {
                        ForEach(DieterSettingsSection.allCases) { section in
                            Button {
                                store.settingsSection = section
                            } label: {
                                SettingsNavigationRow(section: section, selected: section == store.settingsSection)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("settings.\(section.rawValue.lowercased())")
                            .e2eTarget("settings.\(section.rawValue.lowercased())")
                        }
                    }
                    .padding(8)

                    Spacer(minLength: 10)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Dieter \(DieterRelease.current)")
                        Text(store.activeGateway.address).lineLimit(1).help(store.activeGateway.address)
                    }
                    .font(DieterFont.monoSmall).foregroundStyle(DieterTheme.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                }
                .frame(width: 210)

                Rectangle().fill(DieterTheme.hairline).frame(width: 1)

                VStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(store.settingsSection.rawValue).font(.system(size: 18, weight: .semibold))
                        Text(store.settingsSection.subtitle).font(DieterFont.subtitle).foregroundStyle(
                            DieterTheme.tertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 22).padding(.top, 18).padding(.bottom, 12)

                    Group {
                        switch store.settingsSection {
                        case .general: GeneralSettings()
                        case .browser: BrowserSettings()
                        case .connection: ConnectionSettings()
                        case .devices: DevicesSettings()
                        case .usage: UsageSettings()
                        case .prompts: PromptSettingsEditor()
                        case .notifications: NotificationSettings()
                        case .island: IslandSettings()
                        case .agents: AgentSettings()
                        case .experimental: ExperimentalSettings()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

private struct SettingsNavigationRow: View {
    let section: DieterSettingsSection
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: section.symbol).frame(width: 17)
            Text(section.rawValue)
            Spacer()
        }
        .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
        .foregroundStyle(selected ? DieterTheme.text : DieterTheme.subtle)
        .padding(.horizontal, 10)
        .frame(height: DieterMetrics.rowHeight)
        .contentShape(Rectangle())
        .background(
            selected ? DieterTheme.tileSelected : .clear,
            in: RoundedRectangle(cornerRadius: DieterMetrics.rowRadius, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: DieterMetrics.rowRadius, style: .continuous)
                .strokeBorder(selected ? DieterTheme.tileRim : .clear)
        }
    }
}

struct SettingsPage<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            content
                .frame(maxWidth: 860, alignment: .leading)
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .top)
        }
    }
}

struct SettingsPanel<Content: View>: View {
    let title: String
    var subtitle = ""
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title.uppercased()).font(DieterFont.sectionLabel).tracking(0.8).foregroundStyle(
                    DieterTheme.tertiary)
                if !subtitle.isEmpty { Text(subtitle).font(.system(size: 11)).foregroundStyle(DieterTheme.subtle) }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .dieterTile(radius: 12)
    }
}

struct SettingsValueRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 12) {
            Text(title).foregroundStyle(DieterTheme.subtle)
            Spacer()
            Text(value).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle).textSelection(
                .enabled)
        }
        .font(.system(size: 12))
        .padding(.vertical, 3)
    }
}
