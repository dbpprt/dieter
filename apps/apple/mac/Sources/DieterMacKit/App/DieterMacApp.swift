import AppKit
import DieterCore
import SwiftUI

/// The app; the DieterMac executable's entry point runs it.
public struct DieterMacApp: App {
    @State private var store: DieterStore
    @State private var permissions = RequiredPermissions.live()
    private let islandController: DieterIslandController
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openWindow) private var openWindow
    #if DIETER_E2E
        @State private var didStartE2E = false
    #endif
    @AppStorage(DieterAppearance.storageKey, store: DieterAppearance.applicationDefaults())
    private var appearanceValue = DieterAppearance.defaultValue.rawValue
    @AppStorage(DieterPalette.storageKey, store: DieterAppearance.applicationDefaults())
    private var paletteValue = DieterPalette.defaultValue.rawValue
    @AppStorage(DieterTransparency.storageKey, store: DieterAppearance.applicationDefaults())
    private var transparencyEnabled = DieterTransparency.defaultEnabled
    @AppStorage(DieterIslandPreferences.enabledKey, store: DieterAppearance.applicationDefaults())
    private var islandEnabled = DieterIslandPreferences.defaultEnabled

    public init() {
        let store = DieterStore(liveCore: true)
        _store = State(initialValue: store)
        islandController = DieterIslandController(store: store)
    }

    public var body: some Scene {
        Window("Dieter", id: "workspace") {
            RequiredPermissionsGate { DieterRootView() }
                .modifier(WorkspaceMailFocus())
                .environment(permissions)
                .environment(store)
                .dieterThemeRoot(
                    palette: store.themeSelection.palette,
                    appearance: store.themeSelection.appearance
                )
                .onAppear {
                    store.reopenWorkspaceWindow = { openWindow(id: "workspace") }
                    store.themeSelection = DieterThemeSelection(
                        appearance: DieterAppearance.resolve(appearanceValue),
                        palette: DieterPalette.resolve(paletteValue),
                        transparencyEnabled: transparencyEnabled
                    )
                    let selected = DieterPalette.resolve(paletteValue)
                    if paletteValue != selected.rawValue { paletteValue = selected.rawValue }
                    DieterAppIcon.apply(selected)
                    islandController.start(enabled: islandEnabled && permissions.canUseApp)
                }
                .onChange(of: appearanceValue) { _, value in
                    store.themeSelection.appearance = DieterAppearance.resolve(value)
                }
                .onChange(of: paletteValue) { _, value in
                    store.themeSelection.palette = DieterPalette.resolve(value)
                }
                .onChange(of: transparencyEnabled) { _, enabled in
                    store.themeSelection.transparencyEnabled = enabled
                }
                .onChange(of: store.themeSelection.palette) { _, palette in
                    DieterAppIcon.apply(palette)
                }
                .onChange(of: islandEnabled) { _, enabled in
                    islandController.setEnabled(enabled && permissions.canUseApp)
                }
                .onOpenURL { store.completeAuthentication(url: $0) }
                .task {
                    #if DIETER_E2E
                        // Normal app startup is owned by the always-present menu
                        // bar label below. An E2E flow runs in the workspace
                        // window against its isolated fixture.
                        guard NativeTestSupport.isE2E, !didStartE2E else { return }
                        didStartE2E = true
                        await NativeUIFlowRunner.run(store: store)
                    #endif
                }
                .frame(minWidth: 1_080, minHeight: 680)
        }
        .defaultLaunchBehavior(.presented)
        .defaultSize(width: 1_380, height: 870)
        .windowStyle(.automatic)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    openWindow(id: "workspace")
                    NSApp.activate(ignoringOtherApps: true)
                    store.openSettings()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(before: .toolbar) {
                Button(store.sidebarCollapsed ? "Show Sidebar" : "Hide Sidebar") {
                    openWindow(id: "workspace"); store.sidebarCollapsed.toggle()
                }
                .keyboardShortcut("s", modifiers: [.command, .control])
                .disabled(!permissions.canUseApp)
                Divider()
            }
            CommandMenu("Dieter") {
                Button("Command Palette…") {
                    openWindow(id: "workspace"); store.commandPalettePresented = true
                }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(!permissions.canUseApp)
                Button("New Card…") {
                    openWindow(id: "workspace"); store.createConversationPresented = true
                }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(!permissions.canUseApp)
                Button("New Standalone Chat") {
                    openWindow(id: "workspace"); store.beginStandaloneChat()
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(!permissions.canUseApp)
                Button("New Terminal…") {
                    openWindow(id: "workspace")
                    Task {
                        await store.openTerminals()
                        store.terminalsModel.createTerminalPresented = true
                    }
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(!permissions.canUseApp)
                Divider()
                Button("Refresh") { Task { await store.refreshState() } }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(!permissions.canUseApp)
            }
            CommandMenu("Message") {
                MailMessageCommands { openWindow(id: MailWindow.id, value: $0) }
            }
        }

        // One agent mail message per window.
        WindowGroup("Message", id: MailWindow.id, for: MailMessageKey.self) { $key in
            MailMessageWindow(key: key)
                .environment(store)
                .dieterThemeRoot(
                    palette: store.themeSelection.palette,
                    appearance: store.themeSelection.appearance
                )
        }
        .defaultSize(width: 860, height: 760)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        MenuBarExtra {
            Group {
                if permissions.canUseApp {
                    MenuBarContent()
                } else {
                    VStack(spacing: 12) {
                        Text("Grant permissions or skip setup to use Dieter.")
                        Button("Finish Setup…") {
                            openWindow(id: "workspace")
                            NSApp.activate(ignoringOtherApps: true)
                        }
                        Button("Quit Dieter") { NSApp.terminate(nil) }
                    }.padding()
                }
            }
            .environment(store)
        } label: {
            MenuBarStatusIcon(store: store)
                .onAppear {
                    // MenuBarExtra survives when macOS restores Dieter without
                    // a workspace window, so it owns the island and sync
                    // lifetime rather than waiting for DieterRootView to open.
                    store.reopenWorkspaceWindow = { openWindow(id: "workspace") }
                    islandController.start(enabled: islandEnabled && permissions.canUseApp)
                }
                .onChange(of: islandEnabled) { _, enabled in
                    islandController.setEnabled(enabled && permissions.canUseApp)
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        permissions.refresh()
                        store.applicationDidBecomeActive()
                    } else {
                        store.applicationDidResignActive()
                    }
                }
                .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
                    store.systemDidWake()
                }
                .onChange(of: permissions.canUseApp) { _, canUseApp in
                    islandController.setEnabled(islandEnabled && canUseApp)
                    if !canUseApp { openWindow(id: "workspace") }
                }
                .task {
                    if !permissions.canUseApp { openWindow(id: "workspace") }
                    while !Task.isCancelled {
                        permissions.refresh()
                        do { try await DieterTaskSleep.seconds(2) } catch { return }
                    }
                }
                .task {
                    #if DIETER_E2E
                        // macOS can restore Dieter without its workspace window;
                        // the flow runs there and connects itself.
                        if NativeTestSupport.isE2E {
                            openWindow(id: "workspace")
                            return
                        }
                    #endif
                    await store.connect()
                }
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
enum DieterAppIcon {
    static func apply(_ palette: DieterPalette) {
        guard
            let url = Bundle.main.url(
                forResource: palette.rawValue,
                withExtension: "png",
                subdirectory: "PaletteIcons"
            ), let image = NSImage(contentsOf: url)
        else { return }
        NSApp.applicationIconImage = image
    }
}

/// Menu bar (status bar) glyph: the Dieter wheel drawn as a template alpha mask so
/// macOS tints it for light/dark menu bars instead of showing an opaque bitmap.
enum MenuBarIcon {
    static let template: NSImage = {
        let side: CGFloat = 18
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            let scale = side / 24
            NSColor.black.setStroke()
            NSColor.black.setFill()
            let center = CGPoint(x: 12 * scale, y: 12 * scale)
            let ring = NSBezierPath(
                ovalIn: CGRect(
                    x: center.x - 9.3 * scale, y: center.y - 9.3 * scale, width: 18.6 * scale, height: 18.6 * scale))
            ring.lineWidth = 1.8 * scale
            ring.stroke()
            NSBezierPath(
                ovalIn: CGRect(
                    x: center.x - 1.5 * scale, y: center.y - 1.5 * scale, width: 3 * scale, height: 3 * scale)
            ).fill()
            for rotation in [0.0, 120.0, 240.0] {
                let transform = NSAffineTransform()
                transform.translateX(by: center.x, yBy: center.y)
                transform.rotate(byDegrees: rotation)
                let card = NSBezierPath(
                    roundedRect: CGRect(x: -2.7 * scale, y: 3.2 * scale, width: 5.4 * scale, height: 3.6 * scale),
                    xRadius: 0.9 * scale, yRadius: 0.9 * scale)
                card.transform(using: transform as AffineTransform)
                card.fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }()
}

/// The menu bar glyph, dimmed while disconnected. It reads the phase itself,
/// so a connection change redraws the glyph rather than the app's scenes.
private struct MenuBarStatusIcon: View {
    let store: DieterStore

    var body: some View {
        Image(nsImage: MenuBarIcon.template)
            .opacity(store.phase.isConnected ? 1 : 0.55)
            .accessibilityLabel(store.phase.isConnected ? "Dieter connected" : "Dieter disconnected")
    }
}

/// The menu bar window. Each part reads only the session state it shows, so
/// a sync or an activity change redraws that part alone.
struct MenuBarContent: View {
    @Environment(DieterStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            MenuBarHeader()
            MenuBarEndpointRows()
            MenuBarChipRow()
            MenuBarEvents()
            MenuBarMailRow()
            Divider().overlay(DieterTheme.border)
            MenuBarActions()
            MenuBarFooter()
        }
        .padding(16)
        .frame(width: 384)
        .background(DieterTheme.background)
        .dieterThemeRoot(
            palette: store.themeSelection.palette,
            appearance: store.themeSelection.appearance
        )
    }
}

private struct MenuBarHeader: View {
    @Environment(DieterStore.self) private var store

    var body: some View {
        HStack(alignment: .center, spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(store.phase.isConnected ? DieterTheme.running.opacity(0.14) : DieterTheme.tile)
                Image(systemName: store.phase.isConnected ? "wifi" : "wifi.slash")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(store.phase.isConnected ? DieterTheme.eyes : DieterTheme.tertiary)
            }
            .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(store.phase.isConnected ? "Connected to \(store.activeGateway.name)" : store.session.phaseLabel)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DieterTheme.text)
                    .lineLimit(1)
                Text(headerDetail)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(DieterTheme.subtle)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            StatusPill(text: store.session.phaseLabel, color: phaseColor)
        }
    }

    /// How many machines can take work, or the gateway before any is listed.
    private var headerDetail: String {
        let machines = store.machines
        guard !machines.isEmpty else { return "\(store.activeGateway.host):\(store.activeGateway.port)" }
        return "\(machines.filter(store.machineIsAvailable).count) of \(machines.count) machines available"
    }

    private var phaseColor: Color { store.session.tone.color }
}

/// Each machine with how current its part of the workspace is; the gateways
/// before any machine is listed.
private struct MenuBarEndpointRows: View {
    @Environment(DieterStore.self) private var store

    var body: some View {
        let rows = store.machines.isEmpty ? store.gateways : store.machines
        if !rows.isEmpty {
            VStack(spacing: 6) {
                ForEach(rows.prefix(4)) { machine in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(machine.online ? DieterTheme.eyes : DieterTheme.coral)
                            .frame(width: 6, height: 6)
                        Text(machine.name)
                            .font(.system(size: 12))
                            .foregroundStyle(DieterTheme.text)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(store.machineEntry(machine)?.syncLabel ?? "\(machine.host):\(String(machine.port))")
                            .font(.system(size: 10.5))
                            .foregroundStyle(DieterTheme.tertiary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 11).frame(height: 34)
                    .background(
                        DieterTheme.tile, in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                    )
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(DieterTheme.border))
                }
            }
        }
    }
}

private struct MenuBarChipRow: View {
    @Environment(DieterStore.self) private var store

    var body: some View {
        HStack(spacing: 8) {
            MenuBarChip(text: boardCountLabel, color: DieterTheme.subtle)
            if reviewCount > 0 {
                MenuBarChip(
                    text: SharedRules.shared.count(count: Int32(clamping: reviewCount), noun: "review", plural: ""),
                    color: DieterTheme.amber)
            }
            if subagentCount > 0 {
                MenuBarChip(
                    text: SharedRules.shared.count(count: Int32(clamping: subagentCount), noun: "subagent", plural: ""),
                    color: DieterTheme.shellDeep,
                    showDot: true)
            }
            Spacer(minLength: 0)
        }
    }

    private var boardCountLabel: String {
        let count = store.state.boards.count
        return SharedRules.shared.count(count: Int32(clamping: count), noun: "board", plural: "")
    }

    private var reviewCount: Int { Int(store.activity.summary.review) }

    private var subagentCount: Int { Int(store.activity.summary.subagents) }
}

/// The core's menu bar rows: what needs you or awaits review, then failures
/// and results from the last six hours.
private struct MenuBarEvents: View {
    @Environment(DieterStore.self) private var store

    var body: some View {
        let events = self.events
        if !events.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(events) { EventRow(event: $0) }
            }
            .padding(.top, 2)
        }
    }

    private var events: [MenuBarEvent] {
        let rows = Dictionary(
            store.activity.rows.map { ($0.card.id, $0) }, uniquingKeysWith: { first, _ in first })
        return store.activity.menuBarIds.compactMap { rows[$0] }.map { row in
            let (symbol, tint): (String, Color) =
                switch InboxActivityKind(core: row.kind) {
                case .answer: ("questionmark.circle", DieterTheme.amber)
                case .unread: ("envelope.badge", DieterTheme.amber)
                case .review: ("exclamationmark.circle", DieterTheme.amber)
                case .failed: ("xmark.circle", DieterTheme.coral)
                default: ("checkmark.circle", DieterTheme.eyes)
                }
            return MenuBarEvent(
                id: "\(row.kind)-\(row.card.id)", symbol: symbol, tint: tint, title: row.menuBarTitle,
                subtitle: [row.title, row.boardName].filter { !$0.isEmpty }.joined(separator: " · "),
                atMillis: row.atMillis, cardID: row.card.id)
        }
    }
}

/// "Mail · 4 unread": opens Mail in the workspace window.
private struct MenuBarMailRow: View {
    @Environment(DieterStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let slice = store.mailModel.slice
        Button {
            openWindow(id: "workspace")
            NSApp.activate(ignoringOtherApps: true)
            store.openMail()
        } label: {
            HStack(spacing: 9) {
                Image(systemName: slice.unread > 0 ? "envelope.badge" : "envelope")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(slice.unread > 0 ? DieterTheme.action : DieterTheme.subtle)
                    .frame(width: 16)
                Text("Mail").font(.system(size: 12, weight: .semibold)).foregroundStyle(DieterTheme.text)
                if !slice.unreadLabel.isEmpty {
                    Text("· \(slice.unreadLabel) unread").font(.system(size: 12)).foregroundStyle(DieterTheme.subtle)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(DieterTheme.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("menubar.mail")
    }
}

private struct MenuBarActions: View {
    @Environment(DieterStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 10) {
            MenuBarActionButton(
                title: store.phase.isConnected ? "Disconnect" : "Connect", destructive: store.phase.isConnected
            ) {
                if store.phase.isConnected { store.disconnect() } else { Task { await store.connect() } }
            }
            MenuBarActionButton(title: "Open Dieter", prominent: true) {
                openWindow(id: "workspace")
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
}

private struct MenuBarFooter: View {
    @Environment(DieterStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack {
            Button {
                openWindow(id: "workspace")
                NSApp.activate(ignoringOtherApps: true)
                store.openSettings()
            } label: {
                Text("Settings…  ⌘,")
            }
            .buttonStyle(.plain)
            .keyboardShortcut(",", modifiers: .command)
            Spacer()
            Button("Quit Dieter  ⌘Q") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .keyboardShortcut("q", modifiers: .command)
        }
        .font(.system(size: 11))
        .foregroundStyle(DieterTheme.subtle)
    }
}

private struct MenuBarEvent: Identifiable {
    let id: String
    let symbol: String
    let tint: Color
    let title: String
    let subtitle: String
    let atMillis: Int64
    let cardID: String

    var age: String? {
        let age = SharedRules.shared.compactAge(sinceMillis: atMillis, nowMillis: Date.now.epochMillis)
        return age.isEmpty ? nil : age
    }
}

private struct EventRow: View {
    @Environment(DieterStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    let event: MenuBarEvent

    var body: some View {
        Button {
            openWindow(id: "workspace")
            NSApp.activate(ignoringOtherApps: true)
            Task { await store.openConversation(cardID: event.cardID) }
        } label: {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: event.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(event.tint)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(event.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DieterTheme.text)
                    Text(event.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(DieterTheme.subtle)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if let age = event.age {
                    Text(age).font(.system(size: 10.5)).foregroundStyle(DieterTheme.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct MenuBarChip: View {
    let text: String
    let color: Color
    var showDot = false

    var body: some View {
        HStack(spacing: 5) {
            if showDot { Circle().fill(color).frame(width: 5, height: 5) }
            Text(text)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(color.opacity(0.12), in: Capsule())
        .fixedSize()
    }
}

private struct MenuBarActionButton: View {
    let title: String
    var prominent = false
    var destructive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).frame(maxWidth: .infinity)
        }
        .buttonStyle(DieterBarButtonStyle(prominent: prominent, destructive: destructive))
    }
}
