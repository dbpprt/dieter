import DieterAPI
import DieterShared
import Foundation

extension Dieter_V1_Project {
    /// The checkouts a destination picker offers: every attached one, in order.
    package var checkoutChoices: [Dieter_V1_Checkout] {
        ClientCheckouts(rules: SharedRules.shared.checkoutChoices(project: rulesData)).checkouts
    }
}

extension Dieter_V1_Checkout {
    /// The checkout as destination pickers name it: its name, else "Project
    /// checkout", ending " · Offline" while its machine is offline.
    package func title(machineOnline: Bool = true) -> String {
        SharedRules.shared.checkoutTitle(name: name, machineOnline: machineOnline)
    }
}

extension ClientMachineEntry {
    /// The core's detail, followed by when the machine was last seen where that matters.
    package func statusLine(now: Date = Date()) -> String {
        guard showLastSeen else { return detail }
        return detail + " · " + SharedRules.shared.machineLastSeen(lastSeenAt: lastSeenAt, nowMillis: now.epochMillis)
    }
}
