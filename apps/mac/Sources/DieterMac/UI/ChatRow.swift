import AppKit
import DieterAPI
import DieterShared
import SwiftUI
import UniformTypeIdentifiers

struct ChatRow: View {
    @Environment(DieterStore.self) private var store
    let card: Dieter_V1_Card
    var showsPinnedDragHandle = false

    var body: some View {
        ChatRowContent(card: card, showsPinnedDragHandle: showsPinnedDragHandle, unread: store.isChatUnread(card))
            .equatable()
    }
}

struct ChatRowContent: View, Equatable {
    @Environment(DieterStore.self) private var store
    let card: Dieter_V1_Card
    let showsPinnedDragHandle: Bool
    let unread: Bool

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.card == rhs.card && lhs.showsPinnedDragHandle == rhs.showsPinnedDragHandle && lhs.unread == rhs.unread
    }

    var body: some View {
        let _ = BoardRenderingDiagnostics.record(.chatRowBody)
        let running = SharedRules.shared.runtimeActive(runtime: card.runtime)
        let tint = runtimeColor(card.runtime)
        Button {
            Task {
                if card.archived { await store.archive(card, archived: false) }
                await store.openConversation(cardID: card.id, chat: true)
            }
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Group {
                    if running {
                        ChatRunningIndicator(color: tint)
                            .accessibilityLabel("Running")
                    } else {
                        ZStack {
                            Circle().stroke(tint.opacity(0.35), lineWidth: 1.5).frame(
                                width: 11, height: 11)
                            Circle().fill(tint).frame(width: 5, height: 5)
                        }
                    }
                }
                .frame(width: 15, height: 15)
                .padding(.top, 3)
                HStack(alignment: .top, spacing: 6) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 5) {
                            Text(card.title.isEmpty ? "Untitled chat" : card.title)
                                .font(.system(size: 12.5, weight: unread ? .semibold : .medium))
                                .lineLimit(1)
                            if card.pinned {
                                Image(systemName: "pin.fill").font(.system(size: 8)).foregroundStyle(
                                    DieterTheme.shell)
                            }
                            if card.archived {
                                Image(systemName: "archivebox.fill").font(.system(size: 8)).foregroundStyle(
                                    DieterTheme.tertiary)
                            }
                        }
                        HStack(spacing: 6) {
                            if running {
                                Text("Running")
                                    .fontWeight(.semibold)
                                    .foregroundStyle(DieterTheme.primary)
                            } else if !card.summary.isEmpty {
                                Text(card.summary).lineLimit(1)
                            }
                            if WorkspaceBadge.of(card).shown { WorkspaceSummaryBadge(card: card, compact: true) }
                            if !card.activeSubagents.isEmpty {
                                Text(
                                    "· \(SharedRules.shared.count(count: Int32(clamping: card.activeSubagents.count), noun: "subagent", plural: ""))"
                                ).foregroundStyle(DieterTheme.subtle)
                            }
                        }
                        .font(.system(size: 10)).foregroundStyle(DieterTheme.tertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .trailing, spacing: 3) {
                        HStack(spacing: 5) {
                            if unread {
                                Circle().fill(DieterTheme.primary).frame(width: 6.5, height: 6.5)
                                    .accessibilityLabel("Unread")
                            }
                            Text(
                                SharedRules.shared.compactAge(
                                    sinceMillis: SharedRules.shared.epochMillis(
                                        value: card.lastActivityAt.isEmpty ? card.updatedAt : card.lastActivityAt),
                                    nowMillis: Date.now.epochMillis, weeks: true)
                            )
                            .fixedSize()
                            if showsPinnedDragHandle {
                                Image(systemName: "line.3.horizontal")
                                    .font(.system(size: 10, weight: .semibold))
                                    .help("Drag to reorder pinned chats")
                            }
                        }
                        .font(.system(size: 10, weight: unread ? .semibold : .medium))
                        .foregroundStyle(unread ? DieterTheme.primary : DieterTheme.tertiary)
                        ChatRowMachineBadge(card: card)
                    }
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 7)
            .background { ChatRowBackground(cardID: card.id) }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .opacity(store.isPendingCard(card.id) ? 0.52 : 1)
            .overlay(alignment: .bottomTrailing) {
                if store.isPendingCard(card.id) {
                    Image(
                        systemName: store.isFailedOutboxItem(card.id) ? "exclamationmark.circle.fill" : "clock"
                    )
                    .font(.caption2)
                    .foregroundStyle(
                        store.isFailedOutboxItem(card.id) ? DieterTheme.coral : DieterTheme.tertiary
                    )
                    .padding(5)
                }
            }
        }
        .buttonStyle(.plain)
        .draggable(PinnedChatDragPayload(chatID: card.id).encoded) {
            PinnedChatDragPreview(card: card)
        }
        .modifier(ChatContextMenu(card: card))
        .accessibilityIdentifier("chat.\(card.id)")
        .smokeTarget("chat.\(card.id)")
    }

}

struct ChatContextMenu: ViewModifier {
    @Environment(DieterStore.self) private var store
    @State private var renamePresented = false
    @State private var renameText = ""
    let card: Dieter_V1_Card

    func body(content: Content) -> some View {
        content
            .contextMenu {
                if store.isFailedOutboxItem(card.id) {
                    Button("Retry queued creation") { Task { await store.retryOutboxItem(card.id) } }
                    Button("Discard queued creation", role: .destructive) {
                        Task { await store.discardOutboxItem(card.id) }
                    }
                    Divider()
                }
                if card.archived {
                    Button("Restore") { Task { await store.archive(card, archived: false) } }
                } else {
                    Button(card.pinned ? "Unpin" : "Pin") {
                        Task { await store.pin(card, pinned: !card.pinned) }
                    }
                }
                let folders = store.navigation.chatFolders
                if !folders.isEmpty {
                    Menu("Move to folder", systemImage: "folder") {
                        ForEach(folders, id: \.id) { folder in
                            Button {
                                moveChat(to: folder.id)
                            } label: {
                                if folder.itemIds.contains(card.id) {
                                    Label(folder.name, systemImage: "checkmark")
                                } else {
                                    Text(folder.name)
                                }
                            }
                        }
                        if folders.folder(containing: card.id) != nil {
                            Divider()
                            Button("No folder", systemImage: "arrow.up.backward") {
                                moveChat(to: nil)
                            }
                        }
                    }
                }
                Button("Rename…", systemImage: "pencil") {
                    renameText = card.title
                    renamePresented = true
                }
                if !card.archived {
                    Divider()
                    Button("Archive", role: .destructive) { Task { await store.archive(card, archived: true) } }
                }
            }
            .sheet(isPresented: $renamePresented) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Rename chat").font(.title2.weight(.bold))
                    TextField("Title", text: $renameText)
                        .accessibilityIdentifier("chat.rename.title")
                        .onSubmit { rename() }
                    HStack {
                        Spacer()
                        Button("Cancel") { renamePresented = false }.buttonStyle(DieterBarButtonStyle())
                        Button("Rename") { rename() }
                            .buttonStyle(DieterBarButtonStyle(prominent: true))
                            .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityIdentifier("chat.rename.confirm")
                    }
                }
                .padding(22)
                .frame(width: 440)
            }
    }
    private func rename() {
        let title = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        Task { await store.rename(card, title: title) }
        renamePresented = false
    }

    private func moveChat(to folderID: String?) {
        store.moveToFolder(.chats, itemID: card.id, folderID: folderID)
    }
}

struct ChatRowBackground: View {
    @Environment(DieterStore.self) private var store
    let cardID: String
    @State private var hovering = false

    var body: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(
                store.selectedChatID == cardID
                    ? DieterTheme.tileSelected : (hovering ? DieterTheme.tileHover : .clear)
            )
            .onHover { hovering = $0 }
    }
}

struct ChatRowMachineBadge: View {
    @Environment(DieterStore.self) private var store
    let card: Dieter_V1_Card

    var body: some View {
        if let machine = store.machine(for: card) {
            let online = store.machineIsAvailable(machine)
            ProjectMachineBadge(machine: machine, online: online, compact: true)
                .frame(maxWidth: 72, alignment: .trailing)
                .accessibilityIdentifier("chat.\(card.id).machine")
                .smokeTarget("chat.\(card.id).machine.\(online ? "online" : "offline")")
        }
    }
}

/// The All Chats list can show several active conversations at once. Keep its
/// motion on Core Animation's compositor instead of installing one SwiftUI
/// animation driver per row.
struct ChatRunningIndicator: NSViewRepresentable {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let color: Color

    func makeNSView(context: Context) -> ChatRunningIndicatorView {
        ChatRunningIndicatorView(frame: .zero)
    }

    func updateNSView(_ view: ChatRunningIndicatorView, context: Context) {
        view.configure(color: color, animates: !reduceMotion)
    }

    static func dismantleNSView(_ view: ChatRunningIndicatorView, coordinator: Void) {
        view.stopAnimating()
    }
}

final class ChatRunningIndicatorView: NSView {
    private enum AnimationKey {
        static let pulse = "dieter.chat-running.pulse"
        static let orbit = "dieter.chat-running.orbit"
    }

    private let pulseLayer = CAShapeLayer()
    private let orbitLayer = CAShapeLayer()
    private let coreLayer = CAShapeLayer()
    private var configuredColor: Color?
    private var resolvedColor: NSColor?
    private var hasConfiguration = false
    private var animates = false
    private(set) var appliedConfigurationCount = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        [pulseLayer, orbitLayer, coreLayer].forEach { layer?.addSublayer($0) }
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 15, height: 15) }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let layerBounds = CGRect(origin: .zero, size: bounds.size)
        let center = CGPoint(x: layerBounds.midX, y: layerBounds.midY)
        let coreRect = CGRect(x: center.x - 2.5, y: center.y - 2.5, width: 5, height: 5)
        pulseLayer.frame = layerBounds
        pulseLayer.path = CGPath(ellipseIn: coreRect, transform: nil)
        orbitLayer.frame = layerBounds
        orbitLayer.path = CGPath(ellipseIn: layerBounds.insetBy(dx: 1.5, dy: 1.5), transform: nil)
        coreLayer.frame = layerBounds
        coreLayer.path = CGPath(ellipseIn: coreRect, transform: nil)
        CATransaction.commit()
    }

    func configure(color: Color, animates: Bool) {
        let colorChanged = configuredColor != color
        let animationChanged = !hasConfiguration || self.animates != animates
        guard colorChanged || animationChanged else { return }

        if colorChanged || resolvedColor == nil {
            configuredColor = color
            let appKitColor = NSColor(color)
            resolvedColor = appKitColor.usingColorSpace(.deviceRGB) ?? appKitColor
        }
        guard let resolvedColor else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pulseLayer.fillColor = resolvedColor.withAlphaComponent(animates ? 0.45 : 0.18).cgColor
        orbitLayer.fillColor = nil
        orbitLayer.strokeColor = resolvedColor.withAlphaComponent(animates ? 0.82 : 0.38).cgColor
        orbitLayer.lineWidth = 1.25
        orbitLayer.lineCap = .round
        orbitLayer.strokeStart = animates ? 0.08 : 0
        orbitLayer.strokeEnd = animates ? 0.67 : 1
        coreLayer.fillColor = resolvedColor.cgColor
        coreLayer.shadowColor = resolvedColor.cgColor
        coreLayer.shadowOpacity = animates ? 0.55 : 0
        coreLayer.shadowRadius = animates ? 3 : 0
        coreLayer.shadowOffset = .zero
        CATransaction.commit()
        hasConfiguration = true
        appliedConfigurationCount += 1

        guard animationChanged else { return }
        if animates {
            self.animates = true
            startAnimating()
        } else {
            stopAnimating()
        }
    }

    func stopAnimating() {
        animates = false
        pulseLayer.removeAnimation(forKey: AnimationKey.pulse)
        orbitLayer.removeAnimation(forKey: AnimationKey.orbit)
    }

    private func startAnimating() {
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.8
        scale.toValue = 2.7
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.72
        fade.toValue = 0
        let pulse = CAAnimationGroup()
        pulse.animations = [scale, fade]
        pulse.duration = 1.35
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeOut)
        pulseLayer.add(pulse, forKey: AnimationKey.pulse)

        let orbit = CABasicAnimation(keyPath: "transform.rotation.z")
        orbit.fromValue = 0
        orbit.toValue = CGFloat.pi * 2
        orbit.duration = 1.8
        orbit.repeatCount = .infinity
        orbit.timingFunction = CAMediaTimingFunction(name: .linear)
        orbitLayer.add(orbit, forKey: AnimationKey.orbit)
    }
}
