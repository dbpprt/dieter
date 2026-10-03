import DieterAPI
import DieterShared
import SwiftUI

struct ProjectCheckoutMenu: View {
    @Environment(DieterStore.self) private var store
    let projectID: String
    var accessibilityIdentifier = ""

    private var resolvedAccessibilityIdentifier: String {
        accessibilityIdentifier.isEmpty ? "project.checkout.\(projectID)" : accessibilityIdentifier
    }

    private var selectedCheckout: Dieter_V1_Checkout? {
        store.checkout(forProjectID: projectID)
    }

    private var selectedCheckoutLabel: String {
        guard let checkout = selectedCheckout else { return "Choose machine" }
        let machine =
            store.endpoints.first { $0.daemonID == checkout.daemonID }
            ?? (store.endpoint.daemonID == checkout.daemonID ? store.endpoint : nil)
        return "\(machine?.name ?? checkout.daemonID) · \(checkout.title())"
    }

    var body: some View {
        Menu {
            ForEach(store.projectDirectory[projectID]?.checkoutChoices ?? [], id: \.id) { checkout in
                let machine =
                    store.endpoints.first { $0.daemonID == checkout.daemonID }
                    ?? (store.endpoint.daemonID == checkout.daemonID ? store.endpoint : nil)
                Button {
                    Task { await store.selectCheckout(checkout) }
                } label: {
                    Label(
                        "\(machine?.name ?? checkout.daemonID) · \(checkout.title(machineOnline: machine?.online == true))",
                        systemImage: store.checkout(forProjectID: projectID)?.id == checkout.id
                            ? "checkmark" : "desktopcomputer")
                }
                .disabled(!(machine.map(store.machineIsAvailable) ?? false))
                .accessibilityLabel(
                    "\(checkout.title()) on \(machine?.name ?? checkout.daemonID), \(SharedRules.shared.machinePresence(online: machine?.online == true))"
                )
            }
        } label: {
            Label(selectedCheckoutLabel, systemImage: "desktopcomputer")
        }
        .help("Choose the machine and checkout for files, Git, and new conversations")
        .accessibilityIdentifier(resolvedAccessibilityIdentifier)
        .smokeTarget(resolvedAccessibilityIdentifier)
    }
}
