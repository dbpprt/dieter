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
                    if ProcessInfo.processInfo.arguments.contains("--sidebar-ui-smoke") {
                        await SidebarNavigationUISmokeRunner.run(store: store)
                        return
                    }
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
            Image(nsImage: MenuBarIcon.template)
                .opacity(store.phase.isConnected ? 1 : 0.55)
                .accessibilityLabel(store.phase.isConnected ? "Nauclio connected" : "Nauclio disconnected")
        }
        .menuBarExtraStyle(.window)
    }
}

/// Menu bar (status bar) glyph: the Nauclio wheel drawn as a template alpha mask so
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
    @Environment(NauclioStore.self) private var store

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
            Divider().overlay(NauclioTheme.border)
            HStack(spacing: 10) {
                MenuBarActionButton(
                    title: store.phase.isConnected ? "Disconnect" : "Connect",
                    tint: store.phase.isConnected ? NauclioTheme.coral : NauclioTheme.text,
                    background: NauclioTheme.raised,
                ) {
                    if store.phase.isConnected { store.disconnect() } else { Task { await store.connect() } }
                }
                MenuBarActionButton(title: "Open Nauclio", tint: .white, background: NauclioTheme.primary) {
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
            footer
        }
        .padding(16)
        .frame(width: 384)
        .background(NauclioTheme.background)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(store.phase.isConnected ? NauclioTheme.seafoam.opacity(0.14) : NauclioTheme.surface)
                Image(systemName: store.phase.isConnected ? "wifi" : "wifi.slash")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(store.phase.isConnected ? NauclioTheme.seafoam : NauclioTheme.tertiary)
            }
            .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(store.phase.isConnected ? "Connected to \(store.endpoint.name)" : store.phase.label)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(NauclioTheme.text)
                    .lineLimit(1)
                Text(headerDetail)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(NauclioTheme.subtle)
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
        case .connected: NauclioTheme.seafoam
        case .connecting, .authenticationRequired: NauclioTheme.amber
        case .failed, .incompatible: NauclioTheme.coral
        case .disconnected: NauclioTheme.subtle
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
                            .fill(machine.online ? NauclioTheme.seafoam : NauclioTheme.coral)
                            .frame(width: 6, height: 6)
                        Text(machine.name)
                            .font(.system(size: 12, weight: active ? .semibold : .regular))
                            .foregroundStyle(NauclioTheme.text)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text("\(machine.host):\(String(machine.port))")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(NauclioTheme.tertiary)
                            .lineLimit(1)
                        if active {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(NauclioTheme.seafoam)
                        } else if !machine.online {
                            Text("unavailable")
                                .font(.system(size: 10.5))
                                .foregroundStyle(NauclioTheme.tertiary)
                        }
                    }
                    .padding(.horizontal, 11).frame(height: 34)
                    .background(
                        active ? NauclioTheme.seafoam.opacity(0.07) : NauclioTheme.surface.opacity(0.72),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous),
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(active ? NauclioTheme.seafoam.opacity(0.45) : NauclioTheme.border),
                    )
                }
            }
        }
    }

    private var chipRow: some View {
        HStack(spacing: 8) {
            MenuBarChip(text: boardCountLabel, color: NauclioTheme.subtle)
            if reviewCount > 0 {
                MenuBarChip(text: "\(reviewCount) review\(reviewCount == 1 ? "" : "s")", color: NauclioTheme.amber)
            }
            if subagentCount > 0 {
                MenuBarChip(text: "\(subagentCount) subagent\(subagentCount == 1 ? "" : "s")", color: NauclioTheme.cobalt, showDot: true)
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
            Button("Quit Nauclio  ⌘Q") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .keyboardShortcut("q", modifiers: .command)
        }
        .font(.system(size: 11))
        .foregroundStyle(NauclioTheme.subtle)
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
                tint: NauclioTheme.amber,
                title: "Ready for review",
                subtitle: [card.title, boardNames[card.boardID] ?? ""].filter { !$0.isEmpty }.joined(separator: " · "),
                timestamp: MenuBarEvent.parse(card.runtimeUpdatedAt) ?? MenuBarEvent.parse(card.updatedAt),
                cardID: card.id,
            ))
        }
        for card in store.state.cards + store.chats where card.lane.caseInsensitiveCompare("review") != .orderedSame {
            let (symbol, tint, title): (String, Color, String)
            switch card.runtime.lowercased() {
            case "waiting_for_user", "needs_input": (symbol, tint, title) = ("questionmark.circle", NauclioTheme.amber, "Needs you")
            case "completed", "done": (symbol, tint, title) = ("checkmark.circle", NauclioTheme.seafoam, "Finished")
            case "failed", "error": (symbol, tint, title) = ("xmark.circle", NauclioTheme.coral, "Failed")
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
    @Environment(NauclioStore.self) private var store
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
                        .foregroundStyle(NauclioTheme.text)
                    Text(event.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(NauclioTheme.subtle)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if let age = event.age {
                    Text(age).font(.system(size: 10.5)).foregroundStyle(NauclioTheme.tertiary)
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
