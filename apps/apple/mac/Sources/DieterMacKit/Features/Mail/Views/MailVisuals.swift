import DieterClientAPI
import SwiftUI

/// Colours and glyphs of agent mail. Every word, count and time comes from
/// the shared core; this maps its sender styles and flags onto the theme.
@MainActor
enum MailStyle {
    static let unread = DieterTheme.action
    static let important = Color(nsColor: .systemRed)
    static let flag = Color(nsColor: .systemOrange)

    /// A stable avatar colour for a sender (the same sender, the same colour).
    static func avatarColor(_ senderKey: String) -> Color {
        var hash: UInt32 = 5_381
        for byte in senderKey.utf8 { hash = (hash &* 33) &+ UInt32(byte) }
        return ChannelStyle.avatarColor(Int32(bitPattern: hash % 8))
    }

    /// What stands in for initials: a clock for a schedule's report, a
    /// terminal for an operator's; agents' conversations show initials.
    static func glyph(_ style: ClientMailSenderStyle) -> String? {
        switch style {
        case .schedule: "clock"
        case .operator: "terminal"
        default: nil
        }
    }

    static func mailboxSymbol(_ box: ClientMailBox) -> String {
        switch box {
        case .inbox: "tray"
        case .flagged: "flag"
        case .unread: "envelope.badge"
        case .archive: "archivebox"
        case .trash: "trash"
        default: "tray"
        }
    }

    static func mailboxIdentifier(_ box: ClientMailBox) -> String {
        switch box {
        case .inbox: "inbox"
        case .flagged: "flagged"
        case .unread: "unread"
        case .archive: "archive"
        case .trash: "trash"
        default: "inbox"
        }
    }
}

/// A sender's avatar: initials (or a schedule clock, or an operator's
/// terminal) on the sender's colour, with the agent's harness mark.
struct MailAvatar: View {
    let initials: String
    let style: ClientMailSenderStyle
    let harness: String
    let senderKey: String
    var size: CGFloat = 32
    var emphasized = false

    var body: some View {
        let tint =
            emphasized ? Color.white : (style == .operator ? DieterTheme.subtle : MailStyle.avatarColor(senderKey))
        Group {
            if let glyph = MailStyle.glyph(style) {
                Image(systemName: glyph).font(.system(size: size * 0.42, weight: .semibold))
            } else {
                Text(initials).font(.system(size: size * 0.38, weight: .bold))
            }
        }
        .foregroundStyle(tint)
        .frame(width: size, height: size)
        .background(tint.opacity(0.2), in: Circle())
        .background(emphasized ? Color.clear : DieterTheme.panelSolid, in: Circle())
        .overlay { Circle().strokeBorder(tint.opacity(0.35)) }
        .overlay(alignment: .bottomTrailing) {
            if let symbol = ChannelStyle.harnessSymbol(harness) {
                Image(systemName: symbol)
                    .font(.system(size: max(7, size * 0.24), weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: size * 0.42, height: size * 0.42)
                    .background(ChannelStyle.harnessColor(harness), in: Circle())
                    .overlay {
                        Circle().strokeBorder(emphasized ? Color.white : DieterTheme.panelSolid, lineWidth: 1.5)
                    }
                    .offset(x: size * 0.08, y: size * 0.08)
            }
        }
        .accessibilityHidden(true)
    }
}

extension MailAvatar {
    init(row: ClientMailRow, size: CGFloat = 32, emphasized: Bool = false) {
        self.init(
            initials: row.initials, style: row.senderStyle, harness: row.harness, senderKey: row.senderKey, size: size,
            emphasized: emphasized)
    }

    init(reader: ClientMailReader, size: CGFloat = 40) {
        // The reader carries no sender key; its sender groups the colour alike.
        self.init(
            initials: reader.initials, style: reader.senderStyle, harness: reader.harness, senderKey: reader.sender,
            size: size)
    }
}

/// "! Important" beside a subject.
struct MailImportantChip: View {
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "exclamationmark").font(.system(size: 9.5, weight: .heavy))
            Text("Important")
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(MailStyle.important)
        .padding(.horizontal, 8).frame(height: 21)
        .background(MailStyle.important.opacity(0.13), in: Capsule())
        .overlay { Capsule().strokeBorder(MailStyle.important.opacity(0.3)) }
        .fixedSize()
        .accessibilityLabel("Important")
    }
}

/// An amber note on a row or reader that may be out of date.
struct MailStaleNote: View {
    let text: String
    /// The note's colour; amber when nil.
    var tint: Color?

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(tint ?? DieterTheme.amber)
            .lineLimit(2)
    }
}
