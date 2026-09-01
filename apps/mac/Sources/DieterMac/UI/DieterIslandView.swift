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
               calendar.isDate(date, inSameDayAs: now) {
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
            rows.append(Item(
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
            items: Array(rows.prefix(4))
        )
    }

    private static let runningRuntimes = Set(["running", "working", "starting"])
    private static let needsInputRuntimes = Set(["waiting_for_user", "needs_input"])
    private static let completedRuntimes = Set(["completed", "done"])

    private static func detail(for card: SourceCard, kind: Item.Kind) -> String {
        if !card.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return card.summary }
        switch kind {
        case .running: return card.activeSubagentCount == 0 ? "Agent turn in progress" : "\(card.activeSubagentCount) subagent\(card.activeSubagentCount == 1 ? "" : "s") working"
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
        .background(islandBackground)
        .clipShape(islandShape)
        .overlay(islandShape.stroke(.white.opacity(presentation.expanded ? 0.12 : 0.08), lineWidth: 0.75))
        .overlay(alignment: .top) {
            LinearGradient(
                colors: [.clear, .white.opacity(presentation.expanded ? 0.16 : 0.10), .clear],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(height: 1)
            .padding(.horizontal, presentation.expanded ? 42 : 28)
        }
        .shadow(color: DieterTheme.primary.opacity(presentation.expanded ? 0.12 : 0.05), radius: presentation.expanded ? 38 : 18, y: 8)
        .shadow(color: .black.opacity(presentation.expanded ? 0.52 : 0.30), radius: presentation.expanded ? 30 : 14, y: presentation.expanded ? 16 : 7)
        .animation(.spring(response: 0.36, dampingFraction: 0.84), value: presentation.expanded)
        .preferredColorScheme(.dark)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("dieter.island")
    }

    private var islandBackground: some View {
        ZStack {
            Color(nsColor: NSColor(calibratedRed: 0.012, green: 0.020, blue: 0.033, alpha: 0.992))
            if presentation.expanded {
                RadialGradient(
                    colors: [DieterTheme.primary.opacity(0.19), .clear],
                    center: .topLeading,
                    startRadius: 0,
                    endRadius: 330
                )
                RadialGradient(
                    colors: [DieterTheme.eyes.opacity(0.08), .clear],
                    center: .bottomTrailing,
                    startRadius: 0,
                    endRadius: 250
                )
                LinearGradient(
                    colors: [.white.opacity(0.025), .clear, .black.opacity(0.16)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
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
                        .background(.white.opacity(0.06), in: Circle())
                        .overlay(Circle().stroke(.white.opacity(0.07), lineWidth: 0.75))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.62))
                .accessibilityLabel("Collapse Dieter Island")
            }
            .font(.system(size: 10.5, weight: .medium))
            // The expanded shape's vertical sides begin 15 points in from the
            // window frame. Keep another 15 points between that visible edge
            // and the content instead of measuring padding from the clear area.
            .padding(.horizontal, 30)
            .frame(height: 45)

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
                    Text(store.phase.isConnected ? "Running turns and reviews will appear here." : "The Island will update when Dieter reconnects.")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.40))
                }
                .padding(.horizontal, 30)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 7) {
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
                    .frame(height: 19)
                    .padding(.horizontal, 4)

                    ForEach(activity.items) { item in
                        IslandActivityRow(item: item) {
                            open(item)
                        }
                    }
                }
                // Rows add their own 9-point inset, aligning their icons and
                // trailing chevrons with the header and footer at 30 points.
                .padding(.horizontal, 21)
                .padding(.vertical, 8)
                .frame(maxHeight: .infinity, alignment: .top)
            }

            IslandSeparator()

            HStack(spacing: 9) {
                Button {
                    NSApp.activate(ignoringOtherApps: true)
                    if let first = activity.items.first { open(first) }
                } label: {
                    Label("Open activity", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(IslandActionButtonStyle(primary: true))
                .disabled(activity.items.isEmpty)

                Button {
                    NSApp.activate(ignoringOtherApps: true)
                    store.openSettings(section: .island)
                    onRequestExpansion(false)
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .buttonStyle(IslandActionButtonStyle(primary: false))

                Spacer()
                if activity.subagentCount > 0 {
                    Label("\(activity.subagentCount) subagent\(activity.subagentCount == 1 ? "" : "s")", systemImage: "person.2.fill")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(DieterTheme.primary)
                        .padding(.horizontal, 9)
                        .frame(height: 28)
                        .background(DieterTheme.primary.opacity(0.09), in: Capsule())
                }
            }
            .padding(.horizontal, 30)
            .frame(height: 51)
        }
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
        .frame(height: 1)
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
            .padding(.horizontal, 11)
            .frame(height: 56)
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

private struct IslandActionButtonStyle: ButtonStyle {
    let primary: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
            .foregroundStyle(primary ? Color.white.opacity(0.88) : Color.white.opacity(0.64))
            .padding(.horizontal, 13)
            .frame(height: 34)
            .background(
                primary ? DieterTheme.primary.opacity(configuration.isPressed ? 0.23 : 0.16) : Color.white.opacity(configuration.isPressed ? 0.10 : 0.052),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(primary ? DieterTheme.primary.opacity(0.38) : .white.opacity(0.07), lineWidth: 0.75)
            }
            .shadow(color: primary ? DieterTheme.primary.opacity(0.12) : .clear, radius: 10)
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
