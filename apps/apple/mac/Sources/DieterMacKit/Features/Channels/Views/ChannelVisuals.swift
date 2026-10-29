import DieterClientAPI
import SwiftUI

/// Colours and glyphs of agent channels. Wording, grouping and every count
/// come from the shared core; this maps its enums onto the theme.
@MainActor
enum ChannelStyle {
    /// The core's stable avatar colour index (0–7) of a card.
    static func avatarColor(_ index: Int32) -> Color {
        let colors: [Color] = [
            DieterTheme.eyes, DieterTheme.amber, DieterTheme.coral, DieterTheme.running,
            DieterTheme.action, DieterTheme.reviewAccent, DieterTheme.decision, DieterTheme.openAIQuota,
        ]
        return colors[Int(index.magnitude) % colors.count]
    }

    static func kindColor(_ kind: ClientChannelMessageKind) -> Color {
        switch kind {
        case .request: DieterTheme.amber
        case .done: DieterTheme.running
        case .decision: DieterTheme.decision
        case .hold: DieterTheme.amber
        case .release: DieterTheme.running
        case .claim: DieterTheme.action
        default: DieterTheme.tertiary
        }
    }

    static func presenceColor(_ presence: ClientChannelPresence) -> Color {
        switch presence {
        case .running: DieterTheme.running
        case .waiting: DieterTheme.amber
        case .failed: DieterTheme.coral
        default: DieterTheme.tertiary
        }
    }

    /// The harness mark on an avatar: Codex and Claude have their own.
    static func harnessSymbol(_ harness: String) -> String? {
        let harness = harness.lowercased()
        if harness.contains("codex") || harness.contains("openai") { return "sparkles" }
        if harness.contains("claude") { return "brain.head.profile" }
        return harness.isEmpty ? nil : "cpu"
    }

    static func harnessColor(_ harness: String) -> Color {
        let harness = harness.lowercased()
        if harness.contains("codex") || harness.contains("openai") { return DieterTheme.openAIQuota }
        if harness.contains("claude") { return DieterTheme.amber }
        return DieterTheme.subtle
    }

    static func time(_ millis: Int64) -> String {
        guard millis > 0 else { return "" }
        return Date(timeIntervalSince1970: Double(millis) / 1_000).formatted(date: .omitted, time: .shortened)
    }

    static func dateTime(_ millis: Int64) -> String {
        guard millis > 0 else { return "" }
        return Date(timeIntervalSince1970: Double(millis) / 1_000).formatted(date: .abbreviated, time: .shortened)
    }
}

/// A card's avatar: its initials on its colour, with the harness mark. People
/// and Dieter's coordination events have their own.
struct ChannelAvatar: View {
    let initials: String
    let colorIndex: Int32
    var kind: ClientChannelAuthorKind = .agent
    var harness = ""
    var size: CGFloat = 30

    var body: some View {
        let tint: Color =
            switch kind {
            case .human: DieterTheme.subtle
            case .dieter: DieterTheme.shell
            default: ChannelStyle.avatarColor(colorIndex)
            }
        Text(initials)
            .font(.system(size: size * 0.38, weight: .bold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.2), in: RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
            // Opaque underneath, so overlapping avatars in a stack stay legible.
            .background(DieterTheme.panelSolid, in: RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.27, style: .continuous).strokeBorder(tint.opacity(0.35))
            }
            .overlay(alignment: .bottomTrailing) {
                if kind == .agent, let symbol = ChannelStyle.harnessSymbol(harness) {
                    Image(systemName: symbol)
                        .font(.system(size: max(7, size * 0.24), weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: size * 0.42, height: size * 0.42)
                        .background(ChannelStyle.harnessColor(harness), in: Circle())
                        .overlay { Circle().strokeBorder(DieterTheme.panelSolid, lineWidth: 1.5) }
                        .offset(x: size * 0.12, y: size * 0.12)
                }
            }
            .accessibilityHidden(true)
    }
}

extension ChannelAvatar {
    init(author: ClientChannelAuthorView, size: CGFloat = 30) {
        self.init(
            initials: author.initials, colorIndex: author.colorIndex, kind: author.kind, harness: author.harness,
            size: size)
    }
}

/// REQUEST, DONE or DECISION, in its kind's colour.
struct ChannelKindBadge: View {
    let label: String
    let kind: ClientChannelMessageKind

    var body: some View {
        let tint = ChannelStyle.kindColor(kind)
        Text(label)
            .font(.system(size: 9.5, weight: .bold))
            .tracking(0.5)
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .frame(height: 17)
            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(tint.opacity(0.35))
            }
            .fixedSize()
    }
}

/// A presence dot: filled while running, waiting or failed, hollow while idle.
struct ChannelPresenceDot: View {
    let presence: ClientChannelPresence
    var size: CGFloat = 7

    var body: some View {
        let color = ChannelStyle.presenceColor(presence)
        Group {
            if presence == .idle {
                Circle().strokeBorder(color, lineWidth: 1.2)
            } else {
                Circle().fill(color)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A workspace path as a small mono chip.
struct ChannelFileChip: View {
    let path: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "doc").font(.system(size: 8.5, weight: .medium)).foregroundStyle(DieterTheme.tertiary)
            Text(path).font(DieterFont.monoSmall).lineLimit(1).truncationMode(.middle)
        }
        .foregroundStyle(DieterTheme.text.opacity(0.9))
        .padding(.horizontal, 6)
        .frame(height: 19)
        .background(DieterTheme.inset, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(DieterTheme.insetRim) }
        .help(path)
    }
}
