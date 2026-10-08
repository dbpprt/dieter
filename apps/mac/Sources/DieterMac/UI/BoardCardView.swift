import AppKit
import DieterAPI
import DieterShared
import SwiftUI
import UniformTypeIdentifiers

extension ClientBoardAgentStatus {
    /// The status dot's colour.
    @MainActor var color: Color {
        switch self {
        case .running: DieterTheme.running
        case .failed: DieterTheme.failed
        default: DieterTheme.tertiary
        }
    }
}

struct BoardCardDragPreview: View {
    let card: Dieter_V1_Card
    let flags: ClientBoardCardFlags

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.on.rectangle.angled").foregroundStyle(DieterTheme.shell)
            VStack(alignment: .leading, spacing: 3) {
                Text(card.title.isEmpty ? "Untitled card" : card.title).font(
                    .system(size: 12, weight: .semibold)
                )
                .lineLimit(2)
                HStack(spacing: 6) {
                    Circle().fill(flags.agent.color).frame(width: 5, height: 5)
                    Text(flags.runtimeLabel).font(.system(size: 9, weight: .medium)).foregroundStyle(
                        DieterTheme.tertiary)
                }
            }
            Spacer(minLength: 8)
        }
        .padding(12).frame(width: 240)
        .background(DieterTheme.panelSolid, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(DieterTheme.tileRimSelected)
        )
        .shadow(color: Color.black.opacity(0.42), radius: 18, y: 8)
    }
}

/// Open on the first click. The optional second click edits the retained row;
/// it must never make every ordinary click wait for the double-click timeout.
struct BoardCardClickStyle: PrimitiveButtonStyle {
    let edit: () -> Void

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .gesture(
                TapGesture(count: 1).onEnded {
                    BoardCardDoubleClickTracker.shared.arm(after: NSApp.currentEvent, edit: edit)
                    configuration.trigger()
                }
            )
            .simultaneousGesture(TapGesture(count: 2).onEnded { edit() })
            .focusable()
            .focusEffectDisabled()
            .onKeyPress(keys: [.return, .space]) { _ in
                configuration.trigger()
                return .handled
            }
            .accessibilityAction { configuration.trigger() }
            .accessibilityAction(named: "Edit card", edit)
    }
}

/// Selection changes only redraw decoration, not every visible card's rich content.
struct BoardCardBackground: View {
    @Environment(DieterStore.self) private var store
    let cardID: String
    let hovering: Bool
    var body: some View {
        RoundedRectangle(cornerRadius: DieterMetrics.cardRadius, style: .continuous)
            .fill(
                store.selectedCardID == cardID
                    ? DieterTheme.tileSelected
                    : (hovering ? DieterTheme.tileHover : DieterTheme.tile))
    }
}

struct BoardCardBorder: View {
    @Environment(DieterStore.self) private var store
    let cardID: String
    let labelDropTargeted: Bool
    var body: some View {
        RoundedRectangle(cornerRadius: DieterMetrics.cardRadius, style: .continuous)
            .strokeBorder(
                labelDropTargeted
                    ? DieterTheme.action.opacity(0.8)
                    : (store.selectedCardID == cardID ? DieterTheme.tileRimSelected : DieterTheme.tileRim),
                lineWidth: labelDropTargeted ? 1.5 : 1)
    }
}

/// Presence timestamps and harness directory refreshes must not invalidate the
/// entire rich card. These small subviews own the corresponding observations.
struct BoardCardMachineName: View {
    @Environment(DieterStore.self) private var store
    let card: Dieter_V1_Card

    var body: some View {
        if let machine = store.machine(for: card) {
            let online = store.machineIsAvailable(machine)
            Text(machine.name)
                .font(.system(size: 11))
                .foregroundStyle(online ? DieterTheme.tertiary : DieterTheme.tertiary.opacity(0.6))
                .lineLimit(1)
                .truncationMode(.middle)
                .help("Hosted on \(machine.name) · \(SharedRules.shared.machinePresence(online: online))")
                .accessibilityLabel("Hosted on \(machine.name), \(online ? "online" : "offline")")
        }
    }
}

/// "Codex · gpt-5", from the card's machine's harness directory.
struct BoardCardHarnessChip: View {
    @Environment(DieterStore.self) private var store
    let card: Dieter_V1_Card

    var body: some View {
        if !card.provider.isEmpty {
            let harness = store.machineMetadata[card.ownerDaemonID]?.harnesses.harnesses.first {
                $0.id == card.provider
            }
            let provider = harness?.name ?? card.provider
            let model = card.model.isEmpty ? "" : (harness?.models.first { $0.id == card.model }?.name ?? card.model)
            DieterChip(text: model.isEmpty ? provider : "\(provider) · \(model)")
                .layoutPriority(-1)
        }
    }
}

/// The branch line and the mono footer: diff stats, agents, and the age. The
/// age joins the branch line when there are no stats, so no row is mostly empty.
struct BoardCardFooter: View {
    let card: Dieter_V1_Card
    let flags: ClientBoardCardFlags
    let reservesRunAction: Bool

    var body: some View {
        let summary = card.workspace
        let branch = summary.branch.isEmpty ? card.workspaceBranch : summary.branch
        let badge = WorkspaceBadge.of(card)
        let hasStats =
            summary.additions > 0 || summary.deletions > 0 || summary.changedFiles > 0
            || !card.activeSubagents.isEmpty
        let age = SharedRules.shared.cardAge(
            updatedAt: card.updatedAt, lastActivityAt: card.lastActivityAt, nowMillis: Date.now.epochMillis)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if badge.conflicted {
                    DieterBranchLabel(text: badge.fullTitle).foregroundStyle(DieterTheme.failed)
                } else if !branch.isEmpty {
                    DieterBranchLabel(text: branch)
                } else if flags.tone != .attention, !flags.runtimeLabel.isEmpty {
                    Text(flags.runtimeLabel.lowercased())
                        .font(DieterFont.mono)
                        .foregroundStyle(flags.tone == .active ? DieterTheme.running : DieterTheme.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if !hasStats { ageText(age) }
                if !hasStats && reservesRunAction { Color.clear.frame(width: 24, height: 14) }
            }
            .help(badge.shown ? badge.accessibilityLabel : "")
            if hasStats {
                HStack(spacing: 8) {
                    if summary.additions > 0 || summary.deletions > 0 || summary.changedFiles > 0 {
                        DieterDiffStat(
                            additions: Int(summary.additions), deletions: Int(summary.deletions),
                            files: Int(summary.changedFiles))
                    }
                    if !card.activeSubagents.isEmpty {
                        Text("\(card.activeSubagents.count) agents")
                            .font(DieterFont.mono).foregroundStyle(DieterTheme.tertiary)
                    }
                    Spacer(minLength: 0)
                    ageText(age)
                    if reservesRunAction { Color.clear.frame(width: 24, height: 14) }
                }
            }
        }
    }

    @ViewBuilder private func ageText(_ age: String) -> some View {
        if !age.isEmpty {
            Text(age)
                .font(DieterFont.mono)
                .fixedSize()
                .foregroundStyle(DieterTheme.tertiary)
                .accessibilityLabel("Last activity \(age)")
        }
    }
}

struct BoardCardAvailability: ViewModifier {
    @Environment(DieterStore.self) private var store
    let projectID: String

    func body(content: Content) -> some View {
        content.disabled(!store.projectIsAvailable(projectID))
    }
}

struct BoardCardHelp: ViewModifier {
    @Environment(DieterStore.self) private var store
    let card: Dieter_V1_Card
    let flags: ClientBoardCardFlags
    let labels: [Dieter_V1_Label]
    let accessibility: Bool

    func body(content: Content) -> some View {
        if accessibility {
            content.accessibilityValue(accessibilityDetails)
        } else {
            content.quickHelp(metadataHelp, maximumWidth: 320)
        }
    }

    private var metadataHelp: String {
        let harness = store.machineMetadata[card.ownerDaemonID]?.harnesses.harnesses.first {
            $0.id == card.provider
        }
        var details = [flags.agentLabel]
        if !card.provider.isEmpty { details.append("Provider: \(harness?.name ?? card.provider)") }
        if !card.model.isEmpty {
            let name = harness?.models.first { $0.id == card.model }?.name ?? card.model
            details.append("Model: \(name)")
        }
        let workspace = WorkspaceBadge.of(card)
        if workspace.shown { details.append(workspace.accessibilityLabel) }
        if card.hasTokenUsage {
            details.append(
                SharedRules.shared.tokenUsageLabel(
                    totalTokens: card.tokenUsage.totalTokens, reportedMessages: card.tokenUsage.reportedMessages,
                    partial: card.tokenUsage.partial))
        }
        return details.joined(separator: "\n")
    }

    private var accessibilityDetails: String {
        var details = [metadataHelp]
        if !card.summary.isEmpty { details.append(card.summary) }
        if !labels.isEmpty { details.append("Labels: \(labels.map(\.name).joined(separator: ", "))") }
        let age = SharedRules.shared.cardAge(
            updatedAt: card.updatedAt, lastActivityAt: card.lastActivityAt, nowMillis: Date.now.epochMillis)
        if !age.isEmpty { details.append("Last activity \(age)") }
        if !card.activeSubagents.isEmpty { details.append("\(card.activeSubagents.count) active subagents") }
        return details.joined(separator: ". ")
    }

}

struct BoardCardView: View {
    @Environment(DieterStore.self) private var store
    let card: Dieter_V1_Card
    let board: Dieter_V1_Board?
    /// The lane the card shows in; a card dropped on it lands there, above it.
    let laneID: String
    private var currentBoard: Dieter_V1_Board? { board ?? store.selectedBoard }
    @State private var renamePresented = false
    @State private var editPresented = false
    @State private var renameText = ""
    @State private var hovering = false
    @State private var cardDrop = BoardCardDropState()
    private var labelDropTargeted: Bool {
        cardDrop.targeted && cardDrop.payload.flatMap(BoardLabelDragPayload.init) != nil
    }

    init(
        card: Dieter_V1_Card, board: Dieter_V1_Board? = nil, laneID: String? = nil,
        dropState: BoardCardDropState = BoardCardDropState()
    ) {
        self.card = card
        self.board = board
        self.laneID = laneID ?? card.lane
        _cardDrop = State(initialValue: dropState)
    }

    var labels: [Dieter_V1_Label] {
        currentBoard?.labels.filter { card.labelIds.contains($0.id) } ?? []
    }
    /// What the board shows for this card and offers on it.
    private var flags: ClientBoardCardFlags { store.cardFlags(card, board: currentBoard) }
    private func canMergePayload(_ value: String) -> Bool {
        guard let payload = BoardCardDragPayload(value), payload.cardID != card.id,
            let source = store.state.cards.first(where: { $0.id == payload.cardID })
        else { return false }
        return store.cardFlags(source, board: currentBoard).merges(into: flags)
    }

    private func performCardDrop(_ value: String, merge: Bool) -> Bool {
        if let payload = BoardLabelDragPayload(value) {
            guard payload.boardID == store.selectedBoardID,
                currentBoard?.labels.contains(where: { $0.id == payload.labelID }) == true
            else { return false }
            Task { await store.addLabel(card, labelID: payload.labelID) }
            return true
        }
        guard let payload = BoardCardDragPayload(value),
            payload.boardID == store.selectedBoardID,
            let dragged = store.state.cards.first(where: { $0.id == payload.cardID })
        else { return false }
        if merge, payload.cardID != card.id {
            Task { await store.merge(dragged, into: card) }
            return true
        }
        Task { await store.drop(cardID: dragged.id, laneID: laneID, beforeCardID: card.id) }
        return true
    }

    var body: some View {
        let _ = BoardRenderingDiagnostics.record(.cardBody)
        let flags = flags
        let starting = flags.starting
        let showsRunAction = flags.canStart || starting
        let runTitle = card.title.isEmpty ? "card" : card.title
        ZStack(alignment: .bottomTrailing) {
            Button {
                Task {
                    if store.selectedCardID != card.id { await store.openConversation(cardID: card.id) }
                }
            } label: {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        if let dot = statusColor(flags) {
                            DieterStatusDot(color: dot)
                                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                        }
                        Text(card.title.isEmpty ? "Untitled card" : card.title)
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(DieterTheme.text)
                            .multilineTextAlignment(.leading).lineLimit(2)
                        Spacer(minLength: 0)
                    }
                    .accessibilityLabel(flags.agentLabel)
                    if flags.tone == .attention {
                        DieterCallout(text: flags.runtimeLabel)
                    }
                    if !card.summary.isEmpty {
                        Text(card.summary).font(.system(size: 12)).foregroundStyle(DieterTheme.subtle)
                            .lineLimit(2).multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 7) {
                        BoardCardHarnessChip(card: card)
                        ForEach(labels.prefix(2), id: \.id) { label in
                            Text("#\(label.name)")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Color(hex: label.color) ?? DieterTheme.subtle)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        BoardCardMachineName(card: card)
                    }
                    BoardCardFooter(card: card, flags: flags, reservesRunAction: showsRunAction)
                }
                .padding(.horizontal, 12).padding(.top, 11).padding(.bottom, 10)
                .padding(.bottom, card.mergedIntoCardID.isEmpty ? 0 : 28)
                .background { BoardCardBackground(cardID: card.id, hovering: hovering) }
                .overlay(alignment: .bottom) {
                    if flags.tone == .active {
                        // A running agent: a thin line along the bottom edge.
                        Capsule().fill(DieterTheme.running.opacity(0.85)).frame(height: 2)
                            .padding(.horizontal, 10).padding(.bottom, 0.5)
                            .accessibilityHidden(true)
                    }
                }
                .overlay { BoardCardBorder(cardID: card.id, labelDropTargeted: labelDropTargeted) }
                .overlay(alignment: .topTrailing) {
                    if labelDropTargeted {
                        Image(systemName: "tag.fill")
                            .font(.system(size: 10, weight: .bold)).foregroundStyle(DieterTheme.action)
                            .padding(7)
                            .background(DieterTheme.panelSolid, in: Circle())
                            .padding(5)
                            .transition(.scale.combined(with: .opacity))
                    } else if store.labelUpdatingCardIDs.contains(card.id) {
                        ProgressView().controlSize(.mini).padding(8)
                    }
                }
                .scaleEffect(labelDropTargeted ? 1.012 : 1)
                .opacity(store.isPendingCard(card.id) ? 0.52 : 1)
                .overlay(alignment: .bottomTrailing) {
                    if store.isPendingCard(card.id) {
                        Image(
                            systemName: store.isFailedOutboxItem(card.id)
                                ? "exclamationmark.circle.fill" : "clock"
                        )
                        .font(.caption2)
                        .foregroundStyle(
                            store.isFailedOutboxItem(card.id) ? DieterTheme.coral : DieterTheme.tertiary
                        )
                        .padding(7)
                    }
                }
                .draggable(
                    BoardCardDragPayload(cardID: card.id, boardID: card.boardID, sourceLane: card.lane)
                        .encoded
                ) {
                    BoardCardDragPreview(card: card, flags: flags)
                }
                .onDrop(
                    of: [.text],
                    delegate: BoardCardDropDelegate(
                        state: cardDrop, eligible: canMergePayload, drop: performCardDrop)
                )
                .overlay {
                    if cardDrop.mergeReady {
                        VStack(spacing: 6) {
                            Image(systemName: "arrow.triangle.merge")
                                .font(.system(size: 26, weight: .semibold))
                            Text("Release to merge request").font(.caption.weight(.semibold))
                            Text("Move source to Done").font(.caption2)
                        }
                        .foregroundStyle(DieterTheme.text)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(
                            DieterTheme.panelSolid.opacity(0.96),
                            in: RoundedRectangle(cornerRadius: DieterMetrics.cardRadius, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: DieterMetrics.cardRadius, style: .continuous)
                                .strokeBorder(DieterTheme.action, lineWidth: 2)
                        )
                        .allowsHitTesting(false)
                        .accessibilityLabel("Release to merge the initial request and move the source to Done")
                        .accessibilityIdentifier("card-merge.\(card.id)")
                    }
                }
                .onDisappear { cardDrop.reset() }
                .animation(.easeOut(duration: 0.14), value: labelDropTargeted)
            }
            .buttonStyle(BoardCardClickStyle(edit: openEditor))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(card.title.isEmpty ? "Untitled card" : card.title)
            .modifier(BoardCardHelp(card: card, flags: flags, labels: labels, accessibility: true))
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("card.open.\(card.id)")
            if !card.mergedIntoCardID.isEmpty {
                Button {
                    Task { await store.openConversation(cardID: card.mergedIntoCardID) }
                } label: {
                    Label("Merged into task", systemImage: "arrow.triangle.merge").font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 4)
                .quickHelp("Open merged task")
                .accessibilityIdentifier("card-merge-link.\(card.id)")
                .padding(6)
            }
            if showsRunAction && hovering {
                Button {
                    Task { await store.start(card) }
                } label: {
                    Group {
                        if starting {
                            ProgressView().controlSize(.mini).tint(.white).scaleEffect(0.75)
                        } else {
                            Image(systemName: "play.fill").font(.system(size: 8, weight: .bold))
                        }
                    }
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .dieterCircleChrome(prominent: true)
                .disabled(starting)
                .quickHelp(starting ? "Starting task" : "Run task")
                .accessibilityLabel(starting ? "Starting \(runTitle)" : "Run \(runTitle)")
                .accessibilityIdentifier("card-run.\(card.id)")
                .padding(.trailing, 10).padding(.bottom, 8)
                .transition(.scale(scale: 0.85).combined(with: .opacity))
            }
        }
        .onHover { hovering = $0 }
        .modifier(BoardCardHelp(card: card, flags: flags, labels: labels, accessibility: false))
        .animation(.easeOut(duration: 0.12), value: hovering)
        .modifier(
            BoardCardContextMenu(
                card: card, currentBoard: currentBoard, flags: flags,
                open: { Task { await store.openConversation(cardID: card.id) } },
                renamePresented: $renamePresented, editPresented: $editPresented, renameText: $renameText
            )
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("card.\(card.id)")
        .accessibilityHint("Click to open chat. Double-click to edit.")
        .smokeTarget("card.\(card.id)")
    }

    /// A leading dot only while the agent works, waits, or failed.
    private func statusColor(_ flags: ClientBoardCardFlags) -> Color? {
        switch flags.tone {
        case .active: DieterTheme.running
        case .attention: DieterTheme.attention
        case .failed: DieterTheme.failed
        default: nil
        }
    }

    private func openEditor() {
        if flags.canEditDraft {
            editPresented = true
        } else {
            renameText = card.title
            renamePresented = true
        }
    }
}

struct BoardCardContextMenu: ViewModifier {
    @Environment(DieterStore.self) private var store
    let card: Dieter_V1_Card
    let currentBoard: Dieter_V1_Board?
    let flags: ClientBoardCardFlags
    let open: () -> Void
    @Binding var renamePresented: Bool
    @Binding var editPresented: Bool
    @Binding var renameText: String

    func body(content: Content) -> some View {
        let starting = flags.starting
        return
            content
            .contextMenu {
                if store.isFailedOutboxItem(card.id) {
                    Button("Retry queued creation") { Task { await store.retryOutboxItem(card.id) } }
                    Button("Discard queued creation", role: .destructive) {
                        Task { await store.discardOutboxItem(card.id) }
                    }
                    Divider()
                }
                Button("Open conversation", action: open)
                if flags.canStart || starting {
                    Button(starting ? "Starting task…" : "Run task", systemImage: "play.fill") {
                        Task { await store.start(card) }
                    }
                    .disabled(starting)
                }
                Group {
                    if flags.canEditDraft { Button("Edit card…") { editPresented = true } }
                    Button("Rename…") {
                        renameText = card.title
                        renamePresented = true
                    }
                    Menu("Move to") {
                        ForEach(currentBoard?.lanes ?? [], id: \.id) { lane in
                            Button(lane.name) { Task { await store.move(card, lane: lane.id) } }
                        }
                    }
                    if let labels = currentBoard?.labels, !labels.isEmpty {
                        Menu("Labels") {
                            ForEach(labels, id: \.id) { label in
                                Button {
                                    var ids = card.labelIds
                                    if let index = ids.firstIndex(of: label.id) {
                                        ids.remove(at: index)
                                    } else {
                                        ids.append(label.id)
                                    }
                                    Task { await store.setLabels(card, ids: ids) }
                                } label: {
                                    Label(
                                        label.name,
                                        systemImage: card.labelIds.contains(label.id)
                                            ? "checkmark.circle.fill" : "circle"
                                    )
                                }
                            }
                        }
                    }
                    if flags.canCancel {
                        Button("Cancel turn", role: .destructive) { Task { await store.cancel(card) } }
                    }
                    Divider()
                    Button("Archive", role: .destructive) { Task { await store.archive(card, archived: true) } }
                }.modifier(BoardCardAvailability(projectID: card.projectID))
            }
            .sheet(isPresented: $renamePresented) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Rename card").font(.title2.weight(.bold))
                    TextField("Title", text: $renameText)
                    HStack {
                        Spacer()
                        Button("Cancel") { renamePresented = false }
                            .smokeTarget("card-editor.cancel")
                        Button("Rename") {
                            Task {
                                await store.rename(card, title: renameText)
                                renamePresented = false
                            }
                        }.buttonStyle(.borderedProminent).disabled(
                            renameText.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }.padding(22).frame(width: 440)
                    .smokeTarget("card-editor.\(card.id)")
            }
            .sheet(isPresented: $editPresented) {
                EditCardSheet(card: card).environment(store)
            }
    }
}

extension Color {
    init?(hex: String) {
        var value = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        if value.count == 3 { value = value.map { "\($0)\($0)" }.joined() }
        guard value.count == 6, let int = UInt64(value, radix: 16) else { return nil }
        self.init(
            red: Double((int >> 16) & 0xff) / 255, green: Double((int >> 8) & 0xff) / 255,
            blue: Double(int & 0xff) / 255)
    }
}
