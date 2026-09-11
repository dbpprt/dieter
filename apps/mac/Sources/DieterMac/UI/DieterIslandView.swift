import AppKit
import DieterAPI
import Observation
import SwiftUI

struct DieterIslandActivity: Equatable {
    struct SourceCard: Equatable {
        let id: String
        let runtime: String
        let lane: String
        let runtimeUpdatedAt: String
        let lastActivityAt: String
        let updatedAt: String
        let title: String
        let summary: String
        let provider: String
        let chat: Bool
        let activeSubagentCount: Int

        init(_ card: Dieter_V1_Card) {
            id = card.id
            runtime = card.runtime.lowercased()
            lane = card.lane.lowercased()
            runtimeUpdatedAt = card.runtimeUpdatedAt
            lastActivityAt = card.lastActivityAt
            updatedAt = card.updatedAt
            title = card.title
            summary = card.summary
            provider = card.provider
            chat = card.scope.caseInsensitiveCompare("chat") == .orderedSame || card.boardID.isEmpty
            activeSubagentCount = card.activeSubagents.count
        }
    }

    struct Item: Identifiable, Equatable {
        enum Kind: Int, Equatable {
            case running
            case review
            case needsInput
            case completed
        }

        let id: String
        let cardID: String
        let chat: Bool
        let kind: Kind
        let title: String
        let detail: String
        let provider: String
        let timestamp: Date?
    }

    let runningCount: Int
    let reviewCount: Int
    let doneTodayCount: Int
    let subagentCount: Int
    let items: [Item]

    static let empty = Self(
        runningCount: 0,
        reviewCount: 0,
        doneTodayCount: 0,
        subagentCount: 0,
        items: []
    )

    static func resolve(
        cards: [Dieter_V1_Card],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Self {
        resolve(source: source(cards: cards), now: now, calendar: calendar)
    }

    static func source(cards: [Dieter_V1_Card]) -> [SourceCard] {
        var byID: [String: Dieter_V1_Card] = [:]
        for card in cards where !card.id.isEmpty { byID[card.id] = card }
        return byID.values.map(SourceCard.init).sorted { $0.id < $1.id }
    }

    static func resolve(
        source cards: [SourceCard],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Self {
        var runningCount = 0
        var reviewCount = 0
        var doneTodayCount = 0
        var subagentCount = 0

        var rows: [Item] = []
        for card in cards {
            let running = runningRuntimes.contains(card.runtime)
            let review = card.lane == "review"
            let completed = completedRuntimes.contains(card.runtime) || card.lane == "done"
            if running { runningCount += 1 }
            if review { reviewCount += 1 }
            subagentCount += card.activeSubagentCount

            let runtimeDate = DieterTimestamp.date(from: card.runtimeUpdatedAt)
            let updatedDate = DieterTimestamp.date(from: card.updatedAt)
            if completed, let date = runtimeDate ?? updatedDate,
                calendar.isDate(date, inSameDayAs: now)
            {
                doneTodayCount += 1
            }

            let kind: Item.Kind
            if running {
                kind = .running
            } else if review {
                kind = .review
            } else if needsInputRuntimes.contains(card.runtime) {
                kind = .needsInput
            } else if completed {
                kind = .completed
            } else {
                continue
            }
            let date = runtimeDate ?? DieterTimestamp.date(from: card.lastActivityAt) ?? updatedDate
            if kind == .completed, let date, !calendar.isDate(date, inSameDayAs: now) { continue }
            rows.append(
                Item(
                    id: "\(kind.rawValue)-\(card.id)",
                    cardID: card.id,
                    chat: card.chat,
                    kind: kind,
                    title: card.title.isEmpty ? "Untitled conversation" : card.title,
                    detail: detail(for: card, kind: kind),
                    provider: card.provider,
                    timestamp: date
                ))
        }
        rows.sort {
            if $0.kind.rawValue != $1.kind.rawValue { return $0.kind.rawValue < $1.kind.rawValue }
            let lhsTimestamp = $0.timestamp ?? .distantPast
            let rhsTimestamp = $1.timestamp ?? .distantPast
            if lhsTimestamp == rhsTimestamp { return $0.id < $1.id }
            return lhsTimestamp > rhsTimestamp
        }
        return Self(
            runningCount: runningCount,
            reviewCount: reviewCount,
            doneTodayCount: doneTodayCount,
            subagentCount: subagentCount,
            items: Array(rows.prefix(DieterIslandLayout.maximumVisibleRows))
        )
    }

    private static let runningRuntimes = Set(["running", "working", "starting"])
    private static let needsInputRuntimes = Set(["waiting_for_user", "needs_input"])
    private static let completedRuntimes = Set(["completed", "done"])

    private static func detail(for card: SourceCard, kind: Item.Kind) -> String {
        if !card.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return card.summary }
        switch kind {
        case .running:
            return card.activeSubagentCount == 0
                ? "Agent turn in progress"
                : "\(card.activeSubagentCount) subagent\(card.activeSubagentCount == 1 ? "" : "s") working"
        case .review: return "Ready for your review"
        case .needsInput: return "Waiting for your reply"
        case .completed: return "Completed today"
        }
    }
}

@MainActor
@Observable
final class DieterIslandPresentation {
    var expanded = false
    var hasPhysicalNotch = false
    var displays: [DieterIslandDisplay] = []
    var preferredDisplayID: String?
    var currentDisplayID: String?
}

struct DieterIslandShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + topRadius, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - topRadius, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + topRadius),
            control: CGPoint(x: rect.maxX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - bottomRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - bottomRadius, y: rect.maxY),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX + bottomRadius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY - bottomRadius),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + topRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topRadius, y: rect.minY),
            control: CGPoint(x: rect.minX, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }
}

struct DieterIslandView: View {
    @Environment(DieterStore.self) private var store
    @Bindable var presentation: DieterIslandPresentation
    let onRequestExpansion: (Bool) -> Void
    var onDragChanged: (CGSize) -> Void = { _ in }
    var onDragEnded: () -> Void = {}
    var onSelectDisplay: (String?) -> Void = { _ in }
    var onDisplayPickerChanged: (Bool) -> Void = { _ in }
    var onCaptureTask: () -> Void = {}
    @State private var displayPickerPresented = false

    private var pushGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in onDragChanged(value.translation) }
            .onEnded { _ in onDragEnded() }
    }

    private var activity: DieterIslandActivity { store.islandActivity }

    var body: some View {
        Group {
            if presentation.expanded {
                expandedContent
                    .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .top)))
            } else {
                collapsedContent
                    .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .top)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .glassEffect(.regular, in: islandShape)
        .animation(.spring(response: 0.36, dampingFraction: 0.84), value: presentation.expanded)
        .preferredColorScheme(.dark)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("dieter.island")
        .onChange(of: displayPickerPresented) { _, presented in onDisplayPickerChanged(presented) }
        .onChange(of: presentation.expanded) { _, expanded in
            if !expanded { displayPickerPresented = false }
        }
        .onDisappear {
            displayPickerPresented = false
            onDisplayPickerChanged(false)
        }
    }

    private var islandShape: DieterIslandShape {
        DieterIslandShape(
            topRadius: presentation.expanded ? 18 : (presentation.hasPhysicalNotch ? 5 : 15),
            bottomRadius: presentation.expanded ? 28 : 16
        )
    }

    private var collapsedContent: some View {
        HStack(spacing: 9) {
            IslandCount(
                symbol: activity.runningCount > 0 ? "circle.dotted.circle" : connectionSymbol,
                count: activity.runningCount,
                color: activity.runningCount > 0 ? DieterTheme.primary : connectionColor,
                animated: activity.runningCount > 0
            )
            Spacer(minLength: presentation.hasPhysicalNotch ? 82 : 12)
            if activity.reviewCount > 0 {
                IslandCount(symbol: "sparkles", count: activity.reviewCount, color: DieterTheme.amber)
            }
            if activity.doneTodayCount > 0 {
                IslandCount(symbol: "checkmark", count: activity.doneTodayCount, color: DieterTheme.eyes)
            }
            if activity.runningCount == 0 && activity.reviewCount == 0 && activity.doneTodayCount == 0 {
                Text(store.phase.isConnected ? "All quiet" : store.phase.label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.58))
            }
        }
        .padding(.horizontal, presentation.hasPhysicalNotch ? 17 : 26)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .gesture(pushGesture)
        .accessibilityLabel(collapsedAccessibilityLabel)
    }

    private var expandedContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(DieterTheme.primary.opacity(0.16))
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(DieterTheme.primary.opacity(0.28), lineWidth: 0.75)
                    Image(systemName: activity.runningCount > 0 ? "sparkle" : connectionSymbol)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(activity.runningCount > 0 ? DieterTheme.primary : connectionColor)
                }
                .frame(width: 34, height: 34)
                .shadow(color: DieterTheme.primary.opacity(0.25), radius: 12)

                VStack(alignment: .leading, spacing: 2) {
                    Text(headerTitle)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.96))
                    Text("Dieter activity")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.38))
                }

                Spacer(minLength: 4)

                HStack(spacing: 0) {
                    IslandHeaderMetric(value: activity.runningCount, label: "running", color: DieterTheme.primary)
                    IslandMetricDivider()
                    IslandHeaderMetric(value: activity.reviewCount, label: "review", color: DieterTheme.amber)
                    IslandMetricDivider()
                    IslandHeaderMetric(value: activity.doneTodayCount, label: "done", color: DieterTheme.eyes)
                }
                .padding(.horizontal, 3)
                .frame(height: 34)
                .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(.white.opacity(0.06), lineWidth: 0.75)
                }

                HStack(spacing: 6) {
                    Circle().fill(connectionColor).frame(width: 5, height: 5)
                    Text(store.endpoint.name)
                        .lineLimit(1)
                }
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.52))
                .padding(.horizontal, 9)
                .frame(height: 30)
                .background(.white.opacity(0.035), in: Capsule())

                Button {
                    onRequestExpansion(false)
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 9.5, weight: .bold))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .foregroundStyle(.white.opacity(0.62))
                .accessibilityLabel("Collapse Dieter Island")
            }
            .font(.system(size: 10.5, weight: .medium))
            .smokeTarget("island.header")
            .padding(.horizontal, DieterIslandLayout.horizontalInset)
            .frame(height: DieterIslandLayout.headerHeight)
            .contentShape(Rectangle())
            .simultaneousGesture(pushGesture)
            .help("Drag to another display, or push toward the other side of this display and release")

            IslandSeparator()

            if activity.items.isEmpty {
                VStack(spacing: 10) {
                    ZStack {
                        Circle().fill(connectionColor.opacity(0.10)).frame(width: 46, height: 46)
                        Circle().stroke(connectionColor.opacity(0.22), lineWidth: 0.75).frame(width: 46, height: 46)
                        Image(systemName: store.phase.isConnected ? "checkmark" : "wifi.slash")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(connectionColor)
                    }
                    Text(store.phase.isConnected ? "No agent activity right now" : "Dieter is offline")
                        .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.88))
                    Text(
                        store.phase.isConnected
                            ? "Running turns and reviews will appear here."
                            : "The Island will update when Dieter reconnects."
                    )
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.40))
                }
                .padding(.horizontal, DieterIslandLayout.horizontalInset)
                .frame(maxWidth: .infinity)
                .frame(height: DieterIslandLayout.emptyActivityHeight)
            } else {
                VStack(spacing: DieterIslandLayout.rowSpacing) {
                    HStack(spacing: 7) {
                        Text("LIVE ACTIVITY")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .tracking(0.8)
                            .foregroundStyle(.white.opacity(0.38))
                        Text(String(activity.items.count))
                            .font(.system(size: 8.5, weight: .bold, design: .rounded))
                            .foregroundStyle(DieterTheme.primary)
                            .padding(.horizontal, 6)
                            .frame(height: 17)
                            .background(DieterTheme.primary.opacity(0.11), in: Capsule())
                        Spacer()
                        Text("Click a card to jump back in")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.28))
                    }
                    .frame(height: DieterIslandLayout.activityHeadingHeight)
                    .smokeTarget("island.activity-heading")

                    ForEach(activity.items) { item in
                        IslandActivityRow(item: item) {
                            open(item)
                        }
                        .smokeTarget("island.activity-row.\(item.id)")
                    }
                }
                .padding(.horizontal, DieterIslandLayout.horizontalInset)
                .padding(.vertical, DieterIslandLayout.activityVerticalInset)
            }

            IslandSeparator()

            HStack(spacing: 9) {
                Button {
                    store.reopenWorkspaceWindow()
                    NSApp.activate(ignoringOtherApps: true)
                    if let first = activity.items.first { open(first) }
                } label: {
                    Label("Open activity", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.glassProminent)
                .disabled(activity.items.isEmpty)

                Button {
                    store.reopenWorkspaceWindow()
                    NSApp.activate(ignoringOtherApps: true)
                    store.openSettings(section: .island)
                    onRequestExpansion(false)
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .buttonStyle(.glass)

                displayPicker

                Spacer()
                Button(action: onCaptureTask) {
                    Label("Capture task", systemImage: "viewfinder")
                }
                .buttonStyle(.glassProminent)
                .help("Select a screen area and create a Quick Task")
                .accessibilityIdentifier("island.capture-task")
                .smokeTarget("island.capture-task")
                if activity.subagentCount > 0 {
                    Label(
                        "\(activity.subagentCount) subagent\(activity.subagentCount == 1 ? "" : "s")",
                        systemImage: "person.2.fill"
                    )
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(DieterTheme.primary)
                    .padding(.horizontal, 9)
                    .frame(height: 28)
                    .background(DieterTheme.primary.opacity(0.09), in: Capsule())
                }
            }
            .smokeTarget("island.footer")
            .padding(.horizontal, DieterIslandLayout.horizontalInset)
            .frame(height: DieterIslandLayout.footerHeight)
        }
    }

    private var displayPicker: some View {
        let titles = DieterIslandDisplay.titles(for: presentation.displays)
        return Button {
            displayPickerPresented = true
        } label: {
            Image(systemName: "display")
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.glass)
        .quickHelp("Move to display")
        .accessibilityLabel("Move island to display")
        .accessibilityValue(presentation.currentDisplayID.flatMap { titles[$0] } ?? "Automatic")
        .accessibilityIdentifier("island.display-picker")
        .smokeTarget("island.display-picker")
        .popover(isPresented: $displayPickerPresented) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Move to display")
                    .font(.headline)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 5)
                displayChoice(
                    title: "Automatic", id: nil,
                    selected: presentation.preferredDisplayID == nil,
                    identifier: "island.display.automatic"
                )
                Divider().padding(.vertical, 3)
                ForEach(presentation.displays) { display in
                    displayChoice(
                        title: titles[display.id] ?? display.name, id: display.id,
                        selected: presentation.preferredDisplayID == display.id,
                        current: presentation.currentDisplayID == display.id,
                        identifier: "island.display.\(display.id)"
                    )
                }
            }
            .padding(12)
            .frame(minWidth: 230, maxWidth: 340)
            .fixedSize(horizontal: true, vertical: true)
            .accessibilityIdentifier("island.display-options")
            .smokeTarget("island.display-options")
        }
    }

    private func displayChoice(
        title: String, id: String?, selected: Bool, current: Bool = false, identifier: String
    ) -> some View {
        Button {
            displayPickerPresented = false
            onSelectDisplay(id)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: id == nil ? "sparkles" : "display").frame(width: 16)
                Text(title).lineLimit(1)
                Spacer(minLength: 12)
                if current && !selected {
                    Text("Current").font(.caption).foregroundStyle(.secondary).fixedSize()
                }
                Image(systemName: "checkmark")
                    .opacity(selected ? 1 : 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(selected ? "Selected" : (current ? "Current display" : ""))
        .accessibilityIdentifier(identifier)
        .smokeTarget(identifier)
    }

    private var headerTitle: String {
        if activity.runningCount > 0 { return "\(activity.runningCount) running" }
        if activity.reviewCount > 0 { return "Ready for you" }
        return store.phase.isConnected ? "All quiet" : store.phase.label
    }

    private var connectionSymbol: String { store.phase.isConnected ? "checkmark" : "wifi.slash" }
    private var connectionColor: Color { store.phase.isConnected ? DieterTheme.eyes : DieterTheme.coral }

    private var collapsedAccessibilityLabel: String {
        "Dieter Island. \(activity.runningCount) running, \(activity.reviewCount) in review, \(activity.doneTodayCount) done today."
    }

    private func open(_ item: DieterIslandActivity.Item) {
        store.reopenWorkspaceWindow()
        NSApp.activate(ignoringOtherApps: true)
        Task { await store.openConversation(cardID: item.cardID, chat: item.chat) }
        onRequestExpansion(false)
    }
}

private struct IslandCount: View {
    let symbol: String
    let count: Int
    let color: Color
    var animated = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .bold))
            if count > 0 { Text(String(count)).contentTransition(.numericText()) }
        }
        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
        .foregroundStyle(color)
        .shadow(color: color.opacity(animated ? 0.28 : 0.18), radius: animated ? 7 : 4)
        .fixedSize()
    }
}

private struct IslandHeaderMetric: View {
    let value: Int
    let label: String
    let color: Color

    var body: some View {
        VStack(spacing: 0) {
            Text(String(value))
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(value > 0 ? color : .white.opacity(0.42))
                .contentTransition(.numericText())
            Text(label)
                .font(.system(size: 8, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.32))
        }
        .frame(minWidth: 49)
    }
}

private struct IslandMetricDivider: View {
    var body: some View {
        Rectangle()
            .fill(.white.opacity(0.07))
            .frame(width: 1, height: 18)
    }
}

private struct IslandSeparator: View {
    var body: some View {
        LinearGradient(
            colors: [.clear, .white.opacity(0.09), .white.opacity(0.09), .clear],
            startPoint: .leading,
            endPoint: .trailing
        )
        .frame(height: DieterIslandLayout.separatorHeight)
    }
}

private struct IslandActivityRow: View {
    let item: DieterIslandActivity.Item
    let action: () -> Void
    @State private var isHovering = false

    private var color: Color {
        switch item.kind {
        case .running: DieterTheme.primary
        case .review, .needsInput: DieterTheme.amber
        case .completed: DieterTheme.eyes
        }
    }

    private var symbol: String {
        switch item.kind {
        case .running: "circle.dotted.circle"
        case .review: "sparkles"
        case .needsInput: "questionmark"
        case .completed: "checkmark"
        }
    }

    private var status: String {
        switch item.kind {
        case .running: "RUNNING"
        case .review: "REVIEW"
        case .needsInput: "NEEDS YOU"
        case .completed: "DONE"
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(color.opacity(0.13))
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(color.opacity(0.18), lineWidth: 0.75)
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(color)
                }
                .frame(width: 36, height: 36)

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.94))
                        .lineLimit(1)
                    Text(item.detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(item.kind == .running ? color.opacity(0.86) : .white.opacity(0.42))
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if !item.provider.isEmpty {
                    Text(item.provider)
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(.horizontal, 7)
                        .frame(height: 23)
                        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(.white.opacity(0.06), lineWidth: 0.75)
                        }
                }
                Text(status)
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .tracking(0.35)
                    .foregroundStyle(color)
                    .padding(.horizontal, 7)
                    .frame(height: 23)
                    .background(color.opacity(0.11), in: Capsule())
                if let timestamp = item.timestamp {
                    Text(relativeAge(since: timestamp))
                        .font(.system(size: 9.5))
                        .foregroundStyle(.white.opacity(0.3))
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white.opacity(0.22))
            }
            .padding(.horizontal, 10)
            .frame(height: DieterIslandLayout.rowHeight)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .background(
            isHovering ? Color.white.opacity(0.075) : color.opacity(item.kind == .running ? 0.065 : 0.022),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(item.kind == .running ? color.opacity(0.15) : .white.opacity(0.045), lineWidth: 0.75)
        }
        .shadow(color: item.kind == .running ? color.opacity(0.08) : .clear, radius: 10)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.14), value: isHovering)
    }

    private func relativeAge(since timestamp: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(timestamp)))
        switch seconds {
        case ..<60: return "now"
        case ..<3_600: return "\(seconds / 60)m"
        case ..<86_400: return "\(seconds / 3_600)h"
        default: return "\(seconds / 86_400)d"
        }
    }
}

struct DieterIslandSettingsPreview: View {
    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Label("2", systemImage: "circle.dotted.circle").foregroundStyle(DieterTheme.primary)
                Spacer()
                Label("1", systemImage: "sparkles").foregroundStyle(DieterTheme.amber)
                Label("5", systemImage: "checkmark").foregroundStyle(DieterTheme.eyes)
            }
            .font(.system(size: 11.5, weight: .semibold, design: .rounded))
            .padding(.horizontal, 18)
            .frame(width: 282, height: 40)
            .background(
                Color(nsColor: NSColor(calibratedRed: 0.012, green: 0.020, blue: 0.033, alpha: 1)),
                in: DieterIslandShape(topRadius: 5, bottomRadius: 16)
            )
            .overlay(DieterIslandShape(topRadius: 5, bottomRadius: 16).stroke(.white.opacity(0.08), lineWidth: 0.75))
            Text("Hover the notch to expand live activity")
                .font(.caption2)
                .foregroundStyle(DieterTheme.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}
