import AppKit
import DieterAPI
import DieterShared
import SwiftUI

@main
struct DieterMacApp: App {
    @State private var store: DieterStore
    @State private var permissions = RequiredPermissions.live()
    private let islandController: DieterIslandController
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openWindow) private var openWindow
    @State private var didStartSmoke = false
    @AppStorage(DieterAppearance.storageKey, store: DieterAppearance.applicationDefaults())
    private var appearanceValue = DieterAppearance.defaultValue.rawValue
    @AppStorage(DieterPalette.storageKey, store: DieterAppearance.applicationDefaults())
    private var paletteValue = DieterPalette.defaultValue.rawValue
    @AppStorage(DieterTransparency.storageKey, store: DieterAppearance.applicationDefaults())
    private var transparencyEnabled = DieterTransparency.defaultEnabled
    @AppStorage(DieterIslandPreferences.enabledKey, store: DieterAppearance.applicationDefaults())
    private var islandEnabled = DieterIslandPreferences.defaultEnabled

    init() {
        let store = DieterStore(liveCore: true)
        _store = State(initialValue: store)
        islandController = DieterIslandController(store: store)
        #if DIETER_UI_SMOKE
            NativeUISmokeRunner.prepareWindowIfNeeded()
        #endif
    }

    var body: some Scene {
        Window("Dieter", id: "workspace") {
            RequiredPermissionsGate { DieterRootView() }
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
                    #if DIETER_UI_SMOKE
                        let arguments = ProcessInfo.processInfo.arguments
                        // Normal app startup is owned by the always-present menu
                        // bar label below. Keep this window task only for smoke
                        // modes, which install their own isolated test state.
                        guard arguments.contains(where: { $0.hasSuffix("-ui-smoke") }), !didStartSmoke else { return }
                        didStartSmoke = true
                        // macOS can restore a closed workspace while constructing
                        // its scene. Every UI suite needs that real window; the
                        // island must never become an accidental fallback target.
                        openWindow(id: "workspace")
                        guard await NativeUISmokeActivation.awaitForeground() else { return }
                        if arguments.contains("--island-ui-smoke") {
                            await IslandUISmokeRunner.run(store: store, controller: islandController)
                            return
                        }
                        if arguments.contains("--sidebar-ui-smoke") {
                            await SidebarNavigationUISmokeRunner.run(store: store)
                            return
                        }
                        let conversationSmoke = arguments.contains("--conversation-ui-smoke")
                        if conversationSmoke {
                            ConversationUISmokeRunner.progress(
                                "task fired, connecting", in: ConversationUISmokeRunner.outputDirectory())
                        }
                        await store.connect()
                        if arguments.contains("--flow-ui-smoke") {
                            await NativeUIFlowRunner.run(store: store)
                            return
                        }
                        if arguments.contains("--inbox-ui-smoke") {
                            await InboxUISmokeRunner.run(store: store)
                            return
                        }
                        if arguments.contains("--machine-ui-smoke") {
                            await MachineUISmokeRunner.run(store: store)
                            return
                        }
                        if arguments.contains("--terminal-ui-smoke") {
                            await TerminalUISmokeRunner.run(store: store)
                            return
                        }
                        if arguments.contains("--workspace-ui-smoke") {
                            await WorkspaceUISmokeRunner.run(store: store)
                            return
                        }
                        if arguments.contains("--ui-smoke") {
                            await NativeUISmokeRunner.run(store: store)
                        }
                        if conversationSmoke {
                            await ConversationUISmokeRunner.run(store: store)
                        }
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
        }

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
            Image(nsImage: MenuBarIcon.template)
                .opacity(store.phase.isConnected ? 1 : 0.55)
                .accessibilityLabel(store.phase.isConnected ? "Dieter connected" : "Dieter disconnected")
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
                    #if DIETER_UI_SMOKE
                        let arguments = ProcessInfo.processInfo.arguments
                        guard !arguments.contains(where: { $0.hasSuffix("-ui-smoke") }) else { return }
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

struct MenuBarContent: View {
    @Environment(DieterStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            endpointRows
            chipRow
            if !events.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(events) { EventRow(event: $0) }
                }
                .padding(.top, 2)
            }
            Divider().overlay(DieterTheme.border)
            HStack(spacing: 10) {
                MenuBarActionButton(
                    title: store.phase.isConnected ? "Disconnect" : "Connect",
                    tint: store.phase.isConnected ? DieterTheme.coral : DieterTheme.text,
                    background: DieterTheme.tileHover,
                ) {
                    if store.phase.isConnected { store.disconnect() } else { Task { await store.connect() } }
                }
                MenuBarActionButton(title: "Open Dieter", tint: .white, background: DieterTheme.primary) {
                    openWindow(id: "workspace")
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
            footer
        }
        .padding(16)
        .frame(width: 384)
        .background(DieterTheme.background)
        .dieterThemeRoot(
            palette: store.themeSelection.palette,
            appearance: store.themeSelection.appearance
        )
    }

    private var header: some View {
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

    /// Each machine with how current its part of the workspace is; the
    /// gateways before any machine is listed.
    @ViewBuilder private var endpointRows: some View {
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

    private var chipRow: some View {
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

    private var footer: some View {
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

    private var boardCountLabel: String {
        let count = store.state.boards.count
        return SharedRules.shared.count(count: Int32(clamping: count), noun: "board", plural: "")
    }

    private var reviewCount: Int { Int(store.activity.summary.review) }

    private var subagentCount: Int { Int(store.activity.summary.subagents) }

    /// The core's menu bar rows: what needs you or awaits review, then
    /// failures and results from the last six hours.
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
    let tint: Color
    let background: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .background(background, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
