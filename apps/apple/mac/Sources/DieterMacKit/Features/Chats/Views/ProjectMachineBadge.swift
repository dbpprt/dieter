import DieterCore
import SwiftUI

/// Compact host marker shown beside each chat. It shows only the machine's
/// name and availability, so presence refreshes that keep them leave it alone.
struct ProjectMachineBadge: View, Equatable {
    let machine: MachineEndpoint
    let online: Bool
    let compact: Bool

    init(machine: MachineEndpoint, online: Bool, compact: Bool = false) {
        self.machine = machine
        self.online = online
        self.compact = compact
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.machine.name == rhs.machine.name && lhs.online == rhs.online && lhs.compact == rhs.compact
    }

    var body: some View {
        Group {
            if compact {
                ViewThatFits(in: .horizontal) {
                    badge(showName: true).frame(maxWidth: 72)
                    badge(showName: true).frame(width: 40)
                    badge(showName: false)
                }
            } else {
                badge(showName: true)
            }
        }
        .help("Hosted on \(machine.name) · \(SharedRules.shared.machinePresence(online: online))")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Hosted on \(machine.name), \(online ? "online" : "offline")")
    }

    private func badge(showName: Bool) -> some View {
        HStack(spacing: 4) {
            Circle().fill(online ? DieterTheme.machineOnline : DieterTheme.machineOffline).frame(width: 5, height: 5)
            if showName {
                Text(machine.name)
                    .font(.system(size: 8.5, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .foregroundStyle(online ? DieterTheme.subtle : DieterTheme.tertiary)
        .padding(.horizontal, 6)
        .frame(height: 16)
        .background(DieterTheme.tileHover, in: Capsule())
    }
}
