import AppKit
import DieterAPI
import Observation
import SwiftUI

struct DieterIslandActivity: Equatable {
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

    static func resolve(
        cards: [Dieter_V1_Card],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Self {
        let cards = deduplicated(cards)
        let running = cards.filter { runningRuntimes.contains($0.runtime.lowercased()) }
        let reviews = cards.filter { $0.lane.caseInsensitiveCompare("review") == .orderedSame }
        let doneToday = cards.filter { card in
            guard card.lane.caseInsensitiveCompare("done") == .orderedSame ||
                    completedRuntimes.contains(card.runtime.lowercased()),
                  let date = timestamp(card.runtimeUpdatedAt) ?? timestamp(card.updatedAt) else { return false }
            return calendar.isDate(date, inSameDayAs: now)
        }

        var rows: [Item] = []
        for card in cards {
            let kind: Item.Kind
            if runningRuntimes.contains(card.runtime.lowercased()) {
                kind = .running
            } else if card.lane.caseInsensitiveCompare("review") == .orderedSame {
                kind = .review
            } else if needsInputRuntimes.contains(card.runtime.lowercased()) {
                kind = .needsInput
            } else if completedRuntimes.contains(card.runtime.lowercased()) ||
                        card.lane.caseInsensitiveCompare("done") == .orderedSame {
                kind = .completed
            } else {
                continue
            }
            let date = timestamp(card.runtimeUpdatedAt) ?? timestamp(card.lastActivityAt) ?? timestamp(card.updatedAt)
            if kind == .completed, let date, !calendar.isDate(date, inSameDayAs: now) { continue }
            rows.append(Item(
                id: "\(kind.rawValue)-\(card.id)",
                cardID: card.id,
                chat: card.scope.caseInsensitiveCompare("chat") == .orderedSame || card.boardID.isEmpty,
                kind: kind,
                title: card.title.isEmpty ? "Untitled conversation" : card.title,
                detail: detail(for: card, kind: kind),
                provider: card.provider,
                timestamp: date
            ))
        }
        rows.sort {
            if $0.kind.rawValue != $1.kind.rawValue { return $0.kind.rawValue < $1.kind.rawValue }
            return ($0.timestamp ?? .distantPast) > ($1.timestamp ?? .distantPast)
        }
        return Self(
            runningCount: running.count,
            reviewCount: reviews.count,
            doneTodayCount: doneToday.count,
            subagentCount: cards.reduce(0) { $0 + $1.activeSubagents.count },
            items: Array(rows.prefix(4))
        )
    }

    private static let runningRuntimes = Set(["running", "working", "starting"])
    private static let needsInputRuntimes = Set(["waiting_for_user", "needs_input"])
    private static let completedRuntimes = Set(["completed", "done"])

    private static func deduplicated(_ cards: [Dieter_V1_Card]) -> [Dieter_V1_Card] {
        var byID: [String: Dieter_V1_Card] = [:]
        for card in cards where !card.id.isEmpty { byID[card.id] = card }
        return Array(byID.values)
    }

    private static func detail(for card: Dieter_V1_Card, kind: Item.Kind) -> String {
        if !card.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return card.summary }
        switch kind {
        case .running: return card.activeSubagents.isEmpty ? "Agent turn in progress" : "\(card.activeSubagents.count) subagent\(card.activeSubagents.count == 1 ? "" : "s") working"
        case .review: return "Ready for your review"
        case .needsInput: return "Waiting for your reply"
        case .completed: return "Completed today"
        }
    }

    private static func timestamp(_ value: String) -> Date? {
        guard !value.isEmpty else { return nil }
        let precise = ISO8601DateFormatter()
        precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return precise.date(from: value) ?? ISO8601DateFormatter().date(from: value)
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
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topRadius, y: rect.minY + topRadius),
            control: CGPoint(x: rect.minX + topRadius, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.minX + topRadius, y: rect.maxY - bottomRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topRadius + bottomRadius, y: rect.maxY),
            control: CGPoint(x: rect.minX + topRadius, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - topRadius - bottomRadius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - topRadius, y: rect.maxY - bottomRadius),
            control: CGPoint(x: rect.maxX - topRadius, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - topRadius, y: rect.minY + topRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - topRadius, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }
}

struct DieterIslandView: View {
    @Environment(DieterStore.self) private var store
    @Bindable var presentation: DieterIslandPresentation
    let onRequestExpansion: (Bool) -> Void
    @AppStorage(DieterAppearance.storageKey, store: DieterAppearance.applicationDefaults())
    private var appearanceValue = DieterAppearance.defaultValue.rawValue
    @AppStorage(DieterPalette.storageKey, store: DieterAppearance.applicationDefaults())
    private var paletteValue = DieterPalette.defaultValue.rawValue

    private var activity: DieterIslandActivity {
        DieterIslandActivity.resolve(cards: store.state.cards + store.chats)
    }

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
        .shadow(color: .black.opacity(presentation.expanded ? 0.42 : 0.24), radius: presentation.expanded ? 28 : 12, y: presentation.expanded ? 15 : 6)
        .animation(.spring(response: 0.36, dampingFraction: 0.84), value: presentation.expanded)
        .id(paletteValue)
        .preferredColorScheme(.dark)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("dieter.island")
    }

    private var islandBackground: some View {
        ZStack {
            Color(nsColor: NSColor(calibratedWhite: 0.018, alpha: 0.985))
            if presentation.expanded {
                LinearGradient(
                    colors: [DieterTheme.primary.opacity(0.11), .clear, DieterTheme.eyes.opacity(0.055)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
    }

    private var islandShape: DieterIslandShape {
        DieterIslandShape(
            topRadius: presentation.expanded ? 15 : (presentation.hasPhysicalNotch ? 5 : 14),
            bottomRadius: presentation.expanded ? 23 : 14
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
                    .font(.system(size: 10.5, weight: .medium))
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
            HStack(spacing: 9) {
                HStack(spacing: 7) {
                    Circle().fill(connectionColor).frame(width: 6, height: 6)
                    Text(headerTitle)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.94))
                }
                Text("·").foregroundStyle(.white.opacity(0.2))
                Text("\(activity.reviewCount) review")
                    .foregroundStyle(activity.reviewCount > 0 ? DieterTheme.amber : .white.opacity(0.42))
                Text("·").foregroundStyle(.white.opacity(0.2))
                Text("\(activity.doneTodayCount) done today")
                    .foregroundStyle(activity.doneTodayCount > 0 ? DieterTheme.eyes : .white.opacity(0.42))
                Spacer(minLength: 8)
                Text(store.endpoint.name)
                    .lineLimit(1)
                    .foregroundStyle(.white.opacity(0.42))
                Button {
                    onRequestExpansion(false)
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 22, height: 22)
                        .background(.white.opacity(0.07), in: Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.58))
                .accessibilityLabel("Collapse Dieter Island")
            }
            .font(.system(size: 10.5, weight: .medium))
            // The expanded shape's vertical sides begin 15 points in from the
            // window frame. Keep another 15 points between that visible edge
            // and the content instead of measuring padding from the clear area.
            .padding(.horizontal, 30)
            .frame(height: 45)

            Rectangle().fill(.white.opacity(0.08)).frame(height: 1)

            if activity.items.isEmpty {
                VStack(spacing: 9) {
                    Image(systemName: store.phase.isConnected ? "checkmark.circle" : "wifi.slash")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(connectionColor)
                    Text(store.phase.isConnected ? "No agent activity right now" : "Dieter is offline")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.88))
                    Text(store.phase.isConnected ? "Running turns and reviews will appear here." : "The Island will update when Dieter reconnects.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.42))
                }
                .padding(.horizontal, 30)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 1) {
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

            Rectangle().fill(.white.opacity(0.08)).frame(height: 1)

            HStack(spacing: 8) {
                Button {
                    NSApp.activate(ignoringOtherApps: true)
                    if let first = activity.items.first { open(first) }
                } label: {
                    Label("Open activity", systemImage: "rectangle.grid.1x2")
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
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(DieterTheme.primary)
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
        TimelineView(.animation(minimumInterval: animated ? 0.08 : 1, paused: !animated)) { context in
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 9.5, weight: .bold))
                    .rotationEffect(.degrees(animated ? context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4 * 360 : 0))
                if count > 0 { Text(String(count)).contentTransition(.numericText()) }
            }
            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
            .foregroundStyle(color)
        }
        .fixedSize()
    }
}

private struct IslandActivityRow: View {
    let item: DieterIslandActivity.Item
    let action: () -> Void

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

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                ZStack {
                    Circle().fill(color.opacity(0.14)).frame(width: 30, height: 30)
                    Image(systemName: symbol)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(color)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(1)
                    Text(item.detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(item.kind == .running ? color.opacity(0.9) : .white.opacity(0.42))
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if !item.provider.isEmpty {
                    Text(item.provider)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(.horizontal, 7)
                        .frame(height: 22)
                        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                if let timestamp = item.timestamp {
                    Text(relativeAge(since: timestamp))
                        .font(.system(size: 9.5))
                        .foregroundStyle(.white.opacity(0.3))
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white.opacity(0.22))
            }
            .padding(.horizontal, 9)
            .frame(height: 49)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .background(.white.opacity(0.001), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(primary ? Color.black.opacity(0.82) : Color.white.opacity(0.68))
            .padding(.horizontal, 11)
            .frame(height: 29)
            .background(
                primary ? DieterTheme.primary.opacity(configuration.isPressed ? 0.72 : 0.94) : Color.white.opacity(configuration.isPressed ? 0.11 : 0.07),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
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
            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
            .padding(.horizontal, 14)
            .frame(width: 250, height: 36)
            .background(Color.black, in: DieterIslandShape(topRadius: 5, bottomRadius: 14))
            Text("Hover the notch to expand live activity")
                .font(.caption2)
                .foregroundStyle(DieterTheme.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}
