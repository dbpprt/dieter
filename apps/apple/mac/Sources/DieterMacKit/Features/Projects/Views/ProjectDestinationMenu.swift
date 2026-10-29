import DieterCore
import SwiftUI

struct ProjectCheckoutMenu: View {
    @Environment(DieterStore.self) private var store
    let projectID: String
    var accessibilityIdentifier = ""
    var size: CGFloat = DieterMetrics.capsuleHeight

    private var resolvedAccessibilityIdentifier: String {
        accessibilityIdentifier.isEmpty ? "project.checkout.\(projectID)" : accessibilityIdentifier
    }

    var body: some View {
        // The chosen checkout and the choices, read once rather than per item.
        let chosen = store.checkout(forProjectID: projectID)
        let choices = store.projectDirectory[projectID]?.checkoutChoices ?? []
        let selectedCheckoutLabel: String =
            chosen.map { checkout in
                let machine = store.endpoints.first { $0.daemonID == checkout.daemonID }
                return "\(machine?.name ?? checkout.daemonID) · \(checkout.title())"
            } ?? "Choose machine"
        Menu {
            ForEach(choices, id: \.id) { checkout in
                let machine = store.endpoints.first { $0.daemonID == checkout.daemonID }
                Button {
                    Task { await store.selectCheckout(checkout) }
                } label: {
                    Label(
                        "\(machine?.name ?? checkout.daemonID) · \(checkout.title(machineOnline: machine?.online == true))",
                        systemImage: chosen?.id == checkout.id ? "checkmark" : "desktopcomputer")
                }
                .disabled(!(machine.map(store.machineIsAvailable) ?? false))
                .accessibilityLabel(
                    "\(checkout.title()) on \(machine?.name ?? checkout.daemonID), \(SharedRules.shared.machinePresence(online: machine?.online == true))"
                )
            }
        } label: {
            DieterMenuLabel(title: selectedCheckoutLabel, symbol: "desktopcomputer", size: size)
        }
        .dieterMenuChrome()
        .help("Choose the machine and checkout for files, Git, and new conversations")
        .accessibilityIdentifier(resolvedAccessibilityIdentifier)
        .e2eTarget(resolvedAccessibilityIdentifier)
    }
}
