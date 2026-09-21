import DieterAPI
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
        let machineName = machine?.name ?? checkout.daemonID
        let checkoutName = checkout.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return checkoutName.isEmpty ? machineName : "\(machineName) · \(checkoutName)"
    }

    var body: some View {
        Menu {
            ForEach(store.projectDirectory[projectID]?.checkouts.filter { !$0.detached } ?? [], id: \.id) { checkout in
                let machine =
                    store.endpoints.first { $0.daemonID == checkout.daemonID }
                    ?? (store.endpoint.daemonID == checkout.daemonID ? store.endpoint : nil)
                Button {
                    Task { await store.selectCheckout(checkout) }
                } label: {
                    Label(
                        "\(machine?.name ?? checkout.daemonID) · \(checkout.name)",
                        systemImage: store.checkout(forProjectID: projectID)?.id == checkout.id
                            ? "checkmark" : "desktopcomputer")
                }
                .disabled(machine?.online != true)
                .accessibilityLabel(
                    "\(checkout.name) on \(machine?.name ?? checkout.daemonID), \(machine?.online == true ? "online" : "offline")"
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
