import DieterClientAPI
import SwiftUI

/// The selected channel's coordination state: live file claims (with a
/// release), its member cards and their presence, and pinned decisions.
struct ChannelInspector: View {
    enum Tab: String, CaseIterable, Hashable {
        case claims, members, pins
    }

    let model: ChannelsModel
    let stream: ClientChannelStreamView
    @State private var tab = Tab.claims

    var body: some View {
        VStack(spacing: 0) {
            DieterSegmentedPicker(title: "Inspector", selection: $tab, options: Tab.allCases, fillsWidth: true) {
                Text(title($0)).minimumScaleFactor(0.85)
            }
            .padding(10)
            .accessibilityIdentifier("channels.inspector.tabs")
            .e2eTarget("channels.inspector.tabs")
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    switch tab {
                    case .claims: claims
                    case .members: members
                    case .pins: pins
                    }
                }
                .padding(.horizontal, 10).padding(.bottom, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("channels.inspector")
    }

    private func title(_ tab: Tab) -> String {
        switch tab {
        case .claims: stream.claimsTab
        case .members: stream.membersTab
        case .pins: stream.pinsTab
        }
    }

    @ViewBuilder private var claims: some View {
        if stream.claims.isEmpty {
            ChannelInspectorEmpty(
                text: "No live claims. A running agent claims the files it changes until its turn ends.")
        }
        ForEach(stream.claims, id: \.id) { claim in
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    ChannelFileChip(path: claim.path)
                    Spacer(minLength: 4)
                    if !claim.heldLabel.isEmpty {
                        Text(claim.heldLabel).font(.system(size: 10)).foregroundStyle(DieterTheme.tertiary)
                    }
                }
                HStack(spacing: 7) {
                    ChannelAvatar(initials: claim.holderInitials, colorIndex: claim.holderColorIndex, size: 18)
                    Text(claim.holder).font(.system(size: 11.5)).lineLimit(1)
                }
                if claim.advisory {
                    Label("On \(claim.machine), in its own checkout", systemImage: "desktopcomputer")
                        .font(.system(size: 10.5)).foregroundStyle(DieterTheme.tertiary)
                        .help("Another machine's claim: it blocks writes only there. Coordinate before you push.")
                }
                if !claim.waitingLabel.isEmpty {
                    Label(claim.waitingLabel, systemImage: "hourglass")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(DieterTheme.amber)
                }
                Button("Release") {
                    Task { await model.release(cardID: claim.cardID, path: claim.path) }
                }
                .buttonStyle(DieterBarButtonStyle(size: 24))
                .help("Free \(claim.path) for other agents now")
                .accessibilityIdentifier("channels.claim.release.\(claim.path)")
                .e2eTarget("channels.claim.release.\(claim.path)")
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .dieterTile(radius: 10)
            .accessibilityElement(children: .contain)
        }
    }

    @ViewBuilder private var members: some View {
        if stream.members.isEmpty {
            ChannelInspectorEmpty(text: "No agents have agent channels on in this project yet.")
        }
        ForEach(stream.members, id: \.cardID) { member in
            HStack(alignment: .top, spacing: 9) {
                ChannelAvatar(
                    initials: member.initials, colorIndex: member.colorIndex, harness: member.harness, size: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(member.title).font(.system(size: 12, weight: .semibold)).lineLimit(2)
                    HStack(spacing: 5) {
                        ChannelPresenceDot(presence: member.presence, size: 6)
                        Text(member.presenceLabel).font(.system(size: 10.5)).foregroundStyle(
                            ChannelStyle.presenceColor(member.presence))
                    }
                    if !member.detail.isEmpty {
                        Text(member.detail).font(.system(size: 10.5)).foregroundStyle(DieterTheme.tertiary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .dieterTile(radius: 10)
            .opacity(member.enabled ? 1 : 0.6)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("channels.member.\(member.cardID)")
        }
    }

    @ViewBuilder private var pins: some View {
        if stream.pins.isEmpty {
            ChannelInspectorEmpty(
                text: "No pinned decisions. Decisions are pinned and returned to agents that check the files they name."
            )
        }
        ForEach(stream.pins, id: \.messageID) { pin in
            HStack(alignment: .top, spacing: 9) {
                RoundedRectangle(cornerRadius: 1).fill(DieterTheme.decision).frame(width: 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text(pin.body).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    Text(
                        [pin.author, ChannelStyle.dateTime(pin.createdAtMillis)].filter { !$0.isEmpty }
                            .joined(separator: " · ")
                    )
                    .font(.system(size: 10.5)).foregroundStyle(DieterTheme.tertiary)
                    Button("Unpin") { Task { await model.pin(pin.messageID, pinned: false) } }
                        .buttonStyle(.plain)
                        .font(.system(size: 10.5, weight: .medium)).foregroundStyle(DieterTheme.action)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
        }
    }
}

private struct ChannelInspectorEmpty: View {
    let text: String

    var body: some View {
        Text(text).font(.system(size: 11.5)).foregroundStyle(DieterTheme.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 8)
    }
}
