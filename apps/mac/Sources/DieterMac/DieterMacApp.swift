import AppKit
import SwiftUI

@main
struct DieterMacApp: App {
    @State private var store: DieterStore
    private let islandController: DieterIslandController
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(DieterAppearance.storageKey, store: DieterAppearance.applicationDefaults())
    private var appearanceValue = DieterAppearance.defaultValue.rawValue
    @AppStorage(DieterPalette.storageKey, store: DieterAppearance.applicationDefaults())
    private var paletteValue = DieterPalette.defaultValue.rawValue
    @AppStorage(DieterIslandPreferences.enabledKey, store: DieterAppearance.applicationDefaults())
    private var islandEnabled = DieterIslandPreferences.defaultEnabled

    private var appearance: DieterAppearance { DieterAppearance.resolve(appearanceValue) }
    private var palette: DieterPalette { DieterPalette.resolve(paletteValue) }

    init() {
        let store = DieterStore()
        _store = State(initialValue: store)
        islandController = DieterIslandController(store: store)
        NativeUISmokeRunner.prepareWindowIfNeeded()
    }

    var body: some Scene {
        WindowGroup("Dieter") {
            DieterRootView()
                .environment(store)
                .id(paletteValue)
                .preferredColorScheme(appearance.colorScheme)
                .onAppear {
                    let selected = DieterPalette.resolve(paletteValue)
                    if paletteValue != selected.rawValue { paletteValue = selected.rawValue }
                    DieterAppIcon.apply(selected)
                    islandController.start(enabled: islandEnabled)
                }
                .onChange(of: paletteValue) { _, value in
                    DieterAppIcon.apply(DieterPalette.resolve(value))
                }
                .onChange(of: islandEnabled) { _, enabled in
                    islandController.setEnabled(enabled)
                }
                .onOpenURL { store.completeAuthentication(url: $0) }
                .task {
                    let arguments = ProcessInfo.processInfo.arguments
                    // Normal app startup is owned by the always-present menu
                    // bar label below. Keep this window task only for smoke
                    // modes, which install their own isolated test state.
                    guard arguments.contains(where: { $0.hasSuffix("-ui-smoke") }) else { return }
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
                        ConversationUISmokeRunner.progress("task fired, connecting", in: ConversationUISmokeRunner.outputDirectory())
                    }
                    await store.connect()
                    if arguments.contains("--machine-ui-smoke") {
                        await MachineUISmokeRunner.run(store: store)
                        return
                    }
                    if arguments.contains("--terminal-ui-smoke") {
                        await TerminalUISmokeRunner.run(store: store)
                        return
                    }
                    if arguments.contains("--ui-smoke") {
                        await NativeUISmokeRunner.run(store: store)
                    }
                    if conversationSmoke {
                        await ConversationUISmokeRunner.run(store: store)
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
            CommandMenu("Dieter") {
                Button("Command Palette…") { store.commandPalettePresented = true }
                    .keyboardShortcut("k", modifiers: .command)
                Button("New Card…") { store.createConversationPresented = true }
                    .keyboardShortcut("n", modifiers: .command)
                Button("New Standalone Chat") { store.beginStandaloneChat() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("New Terminal…") {
                    Task {
                        await store.openTerminals()
                        store.createTerminalPresented = true
                    }
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                Divider()
                Button("Refresh") { Task { await store.refreshState() } }
                    .keyboardShortcut("r", modifiers: .command)
            }
        }

        MenuBarExtra {
            MenuBarContent()
                .environment(store)
        } label: {
            Image(nsImage: MenuBarIcon.template)
                .opacity(store.phase.isConnected ? 1 : 0.55)
                .accessibilityLabel(store.phase.isConnected ? "Dieter connected" : "Dieter disconnected")
                .onAppear {
                    // MenuBarExtra survives when macOS restores Dieter without
                    // a workspace window, so it owns the island and sync
                    // lifetime rather than waiting for DieterRootView to open.
                    islandController.start(enabled: islandEnabled)
                }
                .onChange(of: islandEnabled) { _, enabled in
                    islandController.setEnabled(enabled)
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { store.applicationDidBecomeActive() }
                }
                .task {
                    let arguments = ProcessInfo.processInfo.arguments
                    guard !arguments.contains(where: { $0.hasSuffix("-ui-smoke") }) else { return }
                    await store.connect()
                }
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
enum DieterAppIcon {
    static func apply(_ palette: DieterPalette) {
        guard let url = Bundle.main.url(
            forResource: palette.rawValue,
            withExtension: "png",
            subdirectory: "PaletteIcons"
        ), let image = NSImage(contentsOf: url) else { return }
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
            let ring = NSBezierPath(ovalIn: CGRect(x: center.x - 9.3 * scale, y: center.y - 9.3 * scale, width: 18.6 * scale, height: 18.6 * scale))
            ring.lineWidth = 1.8 * scale
            ring.stroke()
            NSBezierPath(ovalIn: CGRect(x: center.x - 1.5 * scale, y: center.y - 1.5 * scale, width: 3 * scale, height: 3 * scale)).fill()
            for rotation in [0.0, 120.0, 240.0] {
                let transform = NSAffineTransform()
                transform.translateX(by: center.x, yBy: center.y)
                transform.rotate(byDegrees: rotation)
                let card = NSBezierPath(roundedRect: CGRect(x: -2.7 * scale, y: 3.2 * scale, width: 5.4 * scale, height: 3.6 * scale), xRadius: 0.9 * scale, yRadius: 0.9 * scale)
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
    @AppStorage(DieterAppearance.storageKey, store: DieterAppearance.applicationDefaults())
    private var appearanceValue = DieterAppearance.defaultValue.rawValue
    @AppStorage(DieterPalette.storageKey, store: DieterAppearance.applicationDefaults())
    private var paletteValue = DieterPalette.defaultValue.rawValue

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
                    background: DieterTheme.raised,
                ) {
                    if store.phase.isConnected { store.disconnect() } else { Task { await store.connect() } }
                }
                MenuBarActionButton(title: "Open Dieter", tint: .white, background: DieterTheme.primary) {
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
            footer
        }
        .padding(16)
        .frame(width: 384)
        .background(DieterTheme.background)
        .id(paletteValue)
        .preferredColorScheme(DieterAppearance.resolve(appearanceValue).colorScheme)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(store.phase.isConnected ? DieterTheme.eyes.opacity(0.14) : DieterTheme.surface)
                Image(systemName: store.phase.isConnected ? "wifi" : "wifi.slash")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(store.phase.isConnected ? DieterTheme.eyes : DieterTheme.tertiary)
            }
            .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(store.phase.isConnected ? "Connected to \(store.endpoint.name)" : store.phase.label)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DieterTheme.text)
                    .lineLimit(1)
                Text(headerDetail)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(DieterTheme.subtle)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            StatusPill(text: store.phase.isConnected ? "Connected" : store.phase.label, color: phaseColor)
        }
    }

    private var headerDetail: String {
        if let status = store.connectionStatus(for: store.endpoint) {
            return "\(status.route.rawValue) · \(store.endpoint.host) · \(status.latencyMilliseconds) ms"
        }
        return "\(store.endpoint.host):\(store.endpoint.port)"
    }

    private var phaseColor: Color {
        switch store.phase {
        case .connected: DieterTheme.eyes
        case .connecting, .authenticationRequired: DieterTheme.amber
        case .failed, .incompatible: DieterTheme.coral
        case .disconnected: DieterTheme.subtle
        }
    }

    @ViewBuilder private var endpointRows: some View {
        let rows = store.machines.isEmpty ? store.gateways : store.machines
        if !rows.isEmpty {
            VStack(spacing: 6) {
                ForEach(rows.prefix(4)) { machine in
                    let active = machine.id == store.endpoint.id
                    HStack(spacing: 8) {
                        Circle()
                            .fill(machine.online ? DieterTheme.eyes : DieterTheme.coral)
                            .frame(width: 6, height: 6)
                        Text(machine.name)
                            .font(.system(size: 12, weight: active ? .semibold : .regular))
                            .foregroundStyle(DieterTheme.text)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text("\(machine.host):\(String(machine.port))")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(DieterTheme.tertiary)
                            .lineLimit(1)
                        if active {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(DieterTheme.eyes)
                        } else if !machine.online {
                            Text("unavailable")
                                .font(.system(size: 10.5))
                                .foregroundStyle(DieterTheme.tertiary)
                        }
                    }
                    .padding(.horizontal, 11).frame(height: 34)
                    .background(
                        active ? DieterTheme.eyes.opacity(0.07) : DieterTheme.surface.opacity(0.72),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous),
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(active ? DieterTheme.eyes.opacity(0.45) : DieterTheme.border),
                    )
                }
            }
        }
    }

    private var chipRow: some View {
        HStack(spacing: 8) {
            MenuBarChip(text: boardCountLabel, color: DieterTheme.subtle)
            if reviewCount > 0 {
                MenuBarChip(text: "\(reviewCount) review\(reviewCount == 1 ? "" : "s")", color: DieterTheme.amber)
            }
            if subagentCount > 0 {
                MenuBarChip(text: "\(subagentCount) subagent\(subagentCount == 1 ? "" : "s")", color: DieterTheme.shellDeep, showDot: true)
            }
            Spacer(minLength: 0)
        }
    }

    private var footer: some View {
        HStack {
            Button {
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
        return "\(count) board\(count == 1 ? "" : "s")"
    }

    private var reviewCount: Int {
        store.state.cards.filter { $0.lane.caseInsensitiveCompare("review") == .orderedSame }.count
    }

    private var subagentCount: Int {
        (store.state.cards + store.chats).reduce(0) { $0 + $1.activeSubagents.count }
    }

    private var events: [MenuBarEvent] {
        let boardNames = Dictionary(store.state.boards.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        var rows: [MenuBarEvent] = []
        for card in store.state.cards where card.lane.caseInsensitiveCompare("review") == .orderedSame {
            rows.append(MenuBarEvent(
                id: "review-\(card.id)",
                symbol: "exclamationmark.circle",
                tint: DieterTheme.amber,
                title: "Ready for review",
                subtitle: [card.title, boardNames[card.boardID] ?? ""].filter { !$0.isEmpty }.joined(separator: " · "),
                timestamp: MenuBarEvent.parse(card.runtimeUpdatedAt) ?? MenuBarEvent.parse(card.updatedAt),
                cardID: card.id,
            ))
        }
        for card in store.state.cards + store.chats where card.lane.caseInsensitiveCompare("review") != .orderedSame {
            let (symbol, tint, title): (String, Color, String)
            switch card.runtime.lowercased() {
            case "waiting_for_user", "needs_input": (symbol, tint, title) = ("questionmark.circle", DieterTheme.amber, "Needs you")
            case "completed", "done": (symbol, tint, title) = ("checkmark.circle", DieterTheme.eyes, "Finished")
            case "failed", "error": (symbol, tint, title) = ("xmark.circle", DieterTheme.coral, "Failed")
            default: continue
            }
            let timestamp = MenuBarEvent.parse(card.runtimeUpdatedAt) ?? MenuBarEvent.parse(card.updatedAt)
            // Keep terminal outcomes fresh; stale done cards would crowd out actionable rows.
            if title != "Needs you", let timestamp, Date().timeIntervalSince(timestamp) > 6 * 3_600 { continue }
            rows.append(MenuBarEvent(
                id: "runtime-\(card.id)",
                symbol: symbol,
                tint: tint,
                title: title,
                subtitle: [card.title, boardNames[card.boardID] ?? ""].filter { !$0.isEmpty }.joined(separator: " · "),
                timestamp: timestamp,
                cardID: card.id,
            ))
        }
        // Actionable rows (review, needs-you) outrank terminal outcomes regardless of age.
        let actionable = Set(["Ready for review", "Needs you"])
        return Array(
            rows.sorted {
                let lhsActionable = actionable.contains($0.title)
                if lhsActionable != actionable.contains($1.title) { return lhsActionable }
                return ($0.timestamp ?? .distantPast) > ($1.timestamp ?? .distantPast)
            }.prefix(4),
        )
    }
}

private struct MenuBarEvent: Identifiable {
    let id: String
    let symbol: String
    let tint: Color
    let title: String
    let subtitle: String
    let timestamp: Date?
    let cardID: String

    var age: String? {
        guard let timestamp else { return nil }
        let seconds = max(0, Int(Date().timeIntervalSince(timestamp)))
        switch seconds {
        case ..<60: return "now"
        case ..<3_600: return "\(seconds / 60)m"
        case ..<86_400: return "\(seconds / 3_600)h"
        default: return "\(seconds / 86_400)d"
        }
    }

    static func parse(_ value: String) -> Date? {
        guard !value.isEmpty else { return nil }
        let precise = ISO8601DateFormatter()
        precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return precise.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

private struct EventRow: View {
    @Environment(DieterStore.self) private var store
    let event: MenuBarEvent

    var body: some View {
        Button {
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
