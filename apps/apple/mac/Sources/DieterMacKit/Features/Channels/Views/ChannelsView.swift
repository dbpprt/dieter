import AppKit
import DieterClientAPI
import SwiftUI

/// Agent channels (experimental): the account's project channels, shared by
/// every machine, on the left, the selected channel's stream and composer in
/// the middle, and its claims, members and pins on the right.
struct ChannelsView: View {
    @Environment(DieterStore.self) private var store

    var body: some View {
        let model = store.channelsModel
        ChatPaneSplit(layout: .channels) {
            ChannelListPane(model: model) { store.openSettings(section: .experimental) }
                .environment(store)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("channels.list-pane")
                .e2eTarget("channels.list-pane")
        } detail: {
            ChannelDetailPane(model: model)
                .environment(store)
        }
        .defaultAppStorage(store.environment.defaults)
        .ignoresSafeArea(.container, edges: .top)
        .onAppear { Task { await model.setActive(true) } }
        .onDisappear { Task { await model.setActive(false) } }
    }
}

// MARK: - List

private struct ChannelListPane: View {
    let model: ChannelsModel
    let openSettings: () -> Void

    var body: some View {
        let slice = model.slice
        VStack(spacing: 0) {
            DieterPaneTopBar {
                DieterTitleCapsule(
                    title: "Channels", count: slice.unread > 0 ? Int(slice.unread) : nil, symbol: "number")
            } trailing: {
                Button {
                    Task { await model.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(DieterBarButtonStyle(shape: .circle))
                .help("Refresh channels")
                .accessibilityLabel("Refresh channels")
                .accessibilityIdentifier("channels.refresh")
            }
            if slice.channels.isEmpty {
                if slice.loading {
                    LoadFeedback(title: "Reading channels…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ChannelsEmptyState(
                        title: slice.emptyTitle, detail: slice.emptyDetail, showsSettings: !slice.enabled,
                        openSettings: openSettings)
                }
            } else {
                if !slice.error.isEmpty {
                    Text(slice.error).font(.caption2).foregroundStyle(DieterTheme.coral).lineLimit(2)
                        .padding(.horizontal, 16).padding(.top, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(slice.channels, id: \.projectID) { row in
                            ChannelListRowView(row: row) {
                                Task { await model.select(projectID: row.projectID) }
                            }
                        }
                    }
                    .padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 12)
                }
                .scrollIndicators(.automatic)
            }
        }
    }
}

private struct ChannelListRowView: View {
    let row: ClientChannelListRow
    let select: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: select) {
            HStack(alignment: .top, spacing: 8) {
                Text("#").font(.system(size: 14, weight: .semibold)).foregroundStyle(DieterTheme.tertiary)
                    .frame(width: 12)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.name)
                        .font(.system(size: 12.5, weight: row.unread > 0 || row.selected ? .semibold : .regular))
                        .foregroundStyle(row.enabled ? DieterTheme.text : DieterTheme.tertiary)
                        .lineLimit(1)
                    Text(row.detail).font(.system(size: 10.5)).foregroundStyle(DieterTheme.tertiary).lineLimit(1)
                }
                Spacer(minLength: 4)
                if row.claims > 0 {
                    Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(DieterTheme.amber)
                        .help("\(row.claims) live file claims")
                }
                if row.unread > 0 { DieterCountBadge(count: Int(row.unread), tint: DieterTheme.coral) }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: DieterMetrics.rowRadius, style: .continuous)
                    .fill(row.selected ? DieterTheme.tileSelected : (hovering ? DieterTheme.tileHover : .clear))
            }
            .overlay {
                RoundedRectangle(cornerRadius: DieterMetrics.rowRadius, style: .continuous)
                    .strokeBorder(row.selected ? DieterTheme.tileRim : .clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("#\(row.name), \(row.detail)\(row.unread > 0 ? ", \(row.unread) unread" : "")")
        .accessibilityAddTraits(row.selected ? .isSelected : [])
        .accessibilityIdentifier("channels.row.\(row.projectID)")
        .e2eTarget("channels.row.\(row.projectID)", text: row.name)
    }
}

private struct ChannelsEmptyState: View {
    let title: String
    let detail: String
    let showsSettings: Bool
    let openSettings: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "number.square")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(DieterTheme.shell)
                .frame(width: 60, height: 60)
                .background(DieterTheme.shell.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
            Text(title).font(.system(size: 15, weight: .semibold)).multilineTextAlignment(.center)
            Text(detail)
                .font(.system(size: 12)).foregroundStyle(DieterTheme.subtle)
                .multilineTextAlignment(.center).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            if showsSettings {
                Button("Open Experimental settings", action: openSettings)
                    .buttonStyle(DieterBarButtonStyle(prominent: true, size: 28))
                    .accessibilityIdentifier("channels.empty.settings")
                    .e2eTarget("channels.empty.settings")
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("channels.empty")
        .e2eTarget("channels.empty", text: title)
    }
}

// MARK: - Detail

private struct ChannelDetailPane: View {
    let model: ChannelsModel
    @AppStorage("dieter.channelsInspectorVisible") private var inspectorVisible = true

    var body: some View {
        if let stream = model.stream {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    ChannelStreamHeader(stream: stream, inspectorVisible: $inspectorVisible)
                    Rectangle().fill(DieterTheme.hairline).frame(height: 1)
                    ChannelStreamList(model: model, stream: stream)
                    ChannelComposer(model: model, stream: stream)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if inspectorVisible {
                    Rectangle().fill(DieterTheme.hairline).frame(width: 1)
                    ChannelInspector(model: model, stream: stream)
                        .frame(width: 280)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("channels.stream")
            .e2eTarget("channels.stream", text: stream.title)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .font(.system(size: 30, weight: .light)).foregroundStyle(DieterTheme.shell)
                Text("Agents talk here").font(.system(size: 18, weight: .semibold))
                Text("Choose a channel to read what its agents tell each other, and to message them.")
                    .font(.system(size: 12.5)).foregroundStyle(DieterTheme.subtle).multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("channels.empty-detail")
        }
    }
}

private struct ChannelStreamHeader: View {
    let stream: ClientChannelStreamView
    @Binding var inspectorVisible: Bool

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(stream.title).font(DieterFont.paneTitle).lineLimit(1)
                    if !stream.enabled {
                        StatusPill(text: "Off", color: DieterTheme.tertiary, showsDot: false)
                    }
                    if !stream.claimsSummary.isEmpty {
                        StatusPill(text: stream.claimsSummary, color: DieterTheme.amber)
                    }
                }
                Text(stream.subtitle).font(DieterFont.subtitle).foregroundStyle(DieterTheme.tertiary).lineLimit(1)
            }
            Spacer(minLength: 8)
            HStack(spacing: -6) {
                ForEach(stream.members.prefix(5), id: \.cardID) { member in
                    ChannelAvatar(
                        initials: member.initials, colorIndex: member.colorIndex, harness: member.harness, size: 22
                    )
                    .help("\(member.title) · \(member.presenceLabel)")
                }
            }
            Button {
                inspectorVisible.toggle()
            } label: {
                Image(systemName: "sidebar.right").font(.system(size: 12.5, weight: .medium))
            }
            .buttonStyle(DieterBarButtonStyle(shape: .circle))
            .help(inspectorVisible ? "Hide claims, members and pins" : "Show claims, members and pins")
            .accessibilityLabel("Toggle channel inspector")
            .accessibilityIdentifier("channels.inspector.toggle")
        }
        .padding(.horizontal, 16)
        .padding(.top, DieterMetrics.headerTopPadding)
        .padding(.bottom, 10)
    }
}

/// The stream: messages grouped by author, compact coordination events, the
/// "New" divider, and receipts. The read position moves when its end shows.
private struct ChannelStreamList: View {
    let model: ChannelsModel
    let stream: ClientChannelStreamView
    @State private var endVisible = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if stream.loading {
                    LoadFeedback(title: "Opening \(stream.title)…").padding(.top, 30)
                } else if stream.rows.isEmpty {
                    Text("No messages yet. Agents post here when they coordinate; you can write first.")
                        .font(.system(size: 12)).foregroundStyle(DieterTheme.tertiary)
                        .frame(maxWidth: .infinity).padding(.top, 40)
                }
                ForEach(stream.rows, id: \.id) { row in
                    if row.id == stream.firstUnreadRowID { ChannelNewDivider() }
                    if row.event {
                        ChannelEventRow(row: row)
                    } else {
                        ChannelMessageRow(row: row) { pinned in
                            Task { await model.pin(row.id, pinned: pinned) }
                        }
                    }
                }
                Color.clear.frame(height: 1)
                    .onAppear { endVisible = true }
                    .onDisappear { endVisible = false }
            }
            .padding(.vertical, 10)
        }
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .overlay(alignment: .top) {
            if !stream.error.isEmpty {
                DieterCallout(text: "Reconnecting: \(stream.error)", symbol: "wifi.exclamationmark")
                    .padding(10)
            }
        }
        .task(id: "\(stream.rows.last?.id ?? "")|\(endVisible)|\(stream.unread)") {
            guard endVisible, stream.unread > 0, NSApp.isActive else { return }
            await model.markRead()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard endVisible else { return }
            Task { await model.markRead() }
        }
    }
}

private struct ChannelNewDivider: View {
    var body: some View {
        HStack(spacing: 8) {
            Text("New").font(.system(size: 10.5, weight: .bold)).foregroundStyle(DieterTheme.coral)
            Rectangle().fill(DieterTheme.coral.opacity(0.6)).frame(height: 1)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .accessibilityLabel("New messages")
    }
}

private struct ChannelEventRow: View {
    let row: ClientChannelStreamRow

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(ChannelStyle.kindColor(row.kind)).frame(width: 5, height: 5)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            VStack(alignment: .leading, spacing: 2) {
                Text(row.body).font(.system(size: 11.5)).foregroundStyle(DieterTheme.subtle)
                    .fixedSize(horizontal: false, vertical: true)
                if !row.receipt.isEmpty {
                    Text("→ \(row.receipt)").font(.system(size: 10.5)).foregroundStyle(DieterTheme.tertiary)
                }
            }
            Spacer(minLength: 6)
            Text(ChannelStyle.time(row.createdAtMillis)).font(.system(size: 10)).foregroundStyle(
                DieterTheme.tertiary)
        }
        .padding(.leading, 30).padding(.trailing, 16).padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .e2eTarget("channels.event.\(row.id)", text: row.body)
    }
}

private struct ChannelMessageRow: View {
    let row: ClientChannelStreamRow
    let pin: (Bool) -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                if row.continued {
                    Text(ChannelStyle.time(row.createdAtMillis))
                        .font(.system(size: 9.5)).foregroundStyle(DieterTheme.tertiary)
                        .opacity(hovering ? 1 : 0)
                } else {
                    ChannelAvatar(author: row.author)
                }
            }
            .frame(width: 32, alignment: .center)
            VStack(alignment: .leading, spacing: 4) {
                if !row.continued {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(row.author.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        if !row.kindLabel.isEmpty { ChannelKindBadge(label: row.kindLabel, kind: row.kind) }
                        Text(
                            [row.meta, ChannelStyle.time(row.createdAtMillis)].filter { !$0.isEmpty }
                                .joined(separator: " · ")
                        )
                        .font(.system(size: 10.5)).foregroundStyle(DieterTheme.tertiary).lineLimit(1)
                        if row.pinned {
                            Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(DieterTheme.decision)
                                .help("Pinned")
                        }
                    }
                } else if !row.kindLabel.isEmpty {
                    ChannelKindBadge(label: row.kindLabel, kind: row.kind)
                }
                if !row.recipients.isEmpty {
                    Label(row.recipients, systemImage: row.here ? "at" : "arrowshape.turn.up.right")
                        .font(.system(size: 10.5, weight: .medium)).foregroundStyle(DieterTheme.action)
                }
                Text(row.body)
                    .font(DieterFont.body)
                    .foregroundStyle(DieterTheme.text)
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if !row.files.isEmpty {
                    DieterFlowLayout(horizontalSpacing: 5, verticalSpacing: 5) {
                        ForEach(row.files, id: \.self) { ChannelFileChip(path: $0) }
                    }
                }
                if !row.repliesLabel.isEmpty {
                    Label(row.repliesLabel, systemImage: "bubble.left.and.bubble.right")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(DieterTheme.action)
                }
                if !row.receipt.isEmpty {
                    Text("→ \(row.receipt)").font(.system(size: 10.5)).foregroundStyle(DieterTheme.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, row.continued ? 2 : 9)
        .padding(.bottom, 2)
        .background(hovering ? DieterTheme.tileHover.opacity(0.5) : .clear)
        .onHover { hovering = $0 }
        .contextMenu {
            Button(row.pinned ? "Unpin" : "Pin as decision") { pin(!row.pinned) }
            Button("Copy message") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(row.body, forType: .string)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("channels.message.\(row.id)")
        .e2eTarget("channels.message.\(row.id)", text: row.body)
    }
}

// MARK: - Composer

/// What the user writes: the body, who it is for (everyone, @here, or direct
/// recipients from the channel's members on any machine) and what that does,
/// the kind, and whether to wake idle recipients.
private struct ChannelComposer: View {
    let model: ChannelsModel
    let stream: ClientChannelStreamView
    @State private var text = ""
    @State private var recipients: Set<String> = []
    @State private var here = false
    @State private var kind = ClientChannelMessageKind.note
    @State private var wake = false
    @FocusState private var focused: Bool

    private var composer: ClientChannelComposerState { stream.composer }
    private var canSend: Bool {
        composer.canPost && !composer.sending && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private var audience: String {
        here ? "@here" : recipients.isEmpty ? "Everyone" : "\(recipients.count) recipients"
    }
    private var audienceHint: String {
        here ? composer.hereHint : recipients.isEmpty ? composer.everyoneHint : composer.directHint
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = model.errorMessage ?? (stream.actionError.isEmpty ? nil : stream.actionError) {
                DieterCallout(text: error, tint: DieterTheme.coral)
            }
            if !composer.canPost, !composer.disabledReason.isEmpty {
                Text(composer.disabledReason).font(.caption).foregroundStyle(DieterTheme.tertiary)
            }
            VStack(alignment: .leading, spacing: 8) {
                if !recipients.isEmpty {
                    DieterFlowLayout(horizontalSpacing: 5, verticalSpacing: 5) {
                        ForEach(composer.recipients.filter { recipients.contains($0.cardID) }, id: \.cardID) {
                            recipient in
                            Button {
                                recipients.remove(recipient.cardID)
                            } label: {
                                HStack(spacing: 4) {
                                    Text("@\(recipient.title)").lineLimit(1)
                                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                                }
                                .font(.system(size: 11, weight: .medium)).foregroundStyle(DieterTheme.action)
                                .padding(.horizontal, 7).frame(height: 20)
                                .background(DieterTheme.action.opacity(0.12), in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .help("Remove \(recipient.title)")
                        }
                    }
                }
                TextField(composer.placeholder, text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(DieterFont.body)
                    .lineLimit(1...8)
                    .focused($focused)
                    .disabled(!composer.canPost)
                    .onSubmit(send)
                    .accessibilityIdentifier("channels.composer")
                    .e2eTarget("channels.composer")
                HStack(spacing: 8) {
                    Menu {
                        Toggle(
                            "Everyone",
                            isOn: Binding(
                                get: { !here && recipients.isEmpty },
                                set: { on in
                                    if on {
                                        here = false
                                        recipients = []
                                    }
                                }))
                        Toggle(
                            "@here",
                            isOn: Binding(
                                get: { here },
                                set: { on in
                                    here = on
                                    if on { recipients = [] }
                                }))
                        Section("Agents") {
                            ForEach(composer.recipients, id: \.cardID) { recipient in
                                Toggle(
                                    recipient.machine.isEmpty
                                        ? recipient.title : "\(recipient.title) · \(recipient.machine)",
                                    isOn: Binding(
                                        get: { recipients.contains(recipient.cardID) },
                                        set: { on in
                                            if on {
                                                here = false
                                                recipients.insert(recipient.cardID)
                                            } else {
                                                recipients.remove(recipient.cardID)
                                            }
                                        }))
                            }
                            if composer.recipients.isEmpty { Text("No agents in this channel") }
                        }
                    } label: {
                        Label(audience, systemImage: "at")
                            .font(.system(size: 11.5, weight: .medium))
                    }
                    .menuStyle(.button)
                    .buttonStyle(DieterBarButtonStyle(size: 24))
                    .fixedSize()
                    .help(audienceHint)
                    .accessibilityIdentifier("channels.composer.recipients")

                    DieterSegmentedPicker(
                        "Kind", selection: $kind, options: composer.kinds.map(\.kind), height: 24
                    ) { option in
                        composer.kinds.first { $0.kind == option }?.label ?? ""
                    }
                    .help(composer.kinds.first { $0.kind == kind }?.detail ?? "")
                    .accessibilityIdentifier("channels.composer.kind")

                    Toggle("Wake", isOn: $wake)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 11.5))
                        .disabled(recipients.isEmpty)
                        .help(composer.wakeHint)
                        .accessibilityIdentifier("channels.composer.wake")
                    Spacer(minLength: 4)
                    Button(action: send) {
                        Image(systemName: composer.sending ? "ellipsis" : "arrow.up")
                            .font(.system(size: 12, weight: .bold))
                    }
                    .buttonStyle(DieterBarButtonStyle(shape: .circle, prominent: true, size: 28))
                    .disabled(!canSend)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Send (⌘↩)")
                    .accessibilityLabel("Send")
                    .accessibilityIdentifier("channels.composer.send")
                    .e2eTarget("channels.composer.send")
                }
                Text(audienceHint)
                    .font(.system(size: 10.5)).foregroundStyle(DieterTheme.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("channels.composer.audience")
            }
            .padding(12)
            .dieterInset(radius: 12)
        }
        .padding(.horizontal, 14).padding(.bottom, 14).padding(.top, 6)
        .onChange(of: stream.channel) { _, _ in
            recipients = []
            here = false
            wake = false
        }
        .onChange(of: recipients) { _, value in if value.isEmpty { wake = false } }
    }

    private func send() {
        guard canSend else { return }
        let body = text, to = composer.recipients.map(\.cardID).filter(recipients.contains)
        let here = here, kind = kind, wake = wake && !here && !to.isEmpty
        Task {
            if await model.post(body: body, to: to, here: here, kind: kind, wake: wake) {
                if text == body { text = "" }
                self.kind = .note
                // @here interrupts every running agent: never keep it for the next message.
                self.here = false
            }
        }
    }
}
