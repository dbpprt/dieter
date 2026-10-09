import DieterAPI
import DieterShared
import Foundation

struct ConversationWorkspaceRoute: Equatable {
    let endpointID: String
    let machineName: String
}

extension DieterStore {
    /// The machine that runs `card`'s conversation, listed or not; nil when
    /// the card names none.
    func machine(for card: Dieter_V1_Card) -> MachineEndpoint? {
        guard !card.ownerDaemonID.isEmpty else { return nil }
        return endpoints.first { $0.daemonID == card.ownerDaemonID }
            ?? MachineEndpoint(
                name: card.ownerDaemonID, host: activeGateway.host, port: activeGateway.port,
                secure: activeGateway.secure, daemonID: card.ownerDaemonID, online: false)
    }

    /// The endpoint ID of the machine that runs `card`'s conversation.
    func endpointID(for card: Dieter_V1_Card) -> String {
        endpointID(forDaemon: card.ownerDaemonID)
    }

    /// Workspace RPCs belong to the conversation owner. A project's records
    /// are on every machine, while its chats and checkouts run on one.
    func conversationWorkspaceRoute(for card: Dieter_V1_Card) -> ConversationWorkspaceRoute? {
        guard let machine = machine(for: card) else { return nil }
        return ConversationWorkspaceRoute(endpointID: machine.id, machineName: machine.name)
    }

    /// Whether the machine that runs `card`'s conversation can take work
    /// now; reports why not unless `reportOffline` is false.
    func conversationMachineIsAvailable(_ card: Dieter_V1_Card, reportOffline: Bool = true) -> Bool {
        guard let machine = machine(for: card) else { return false }
        if let reason = unavailableReason(machine) {
            if reportOffline { errorMessage = reason }
            return false
        }
        return phase.isConnected
    }

    func attachCheckout(projectID: String, path: String, name: String, machineID: String) async -> Bool {
        guard let target = endpoints.first(where: { $0.id == machineID }), machineIsAvailable(target),
            let daemonID = target.daemonID
        else { return false }
        do {
            _ = try await administer {
                $0.attachCheckout = .with {
                    $0.daemonID = daemonID
                    $0.projectID = projectID
                    $0.path = path
                    $0.name = name
                }
            }
            return true
        } catch { show(error); return false }
    }
    func detachCheckout(_ checkout: Dieter_V1_Checkout) async {
        do {
            _ = try await administer {
                $0.detachCheckout = .with {
                    $0.projectID = checkout.projectID
                    $0.checkoutID = checkout.id
                }
            }
            creationCheckoutIDs.removeValue(forKey: checkout.projectID)
        } catch { show(error) }
    }

    func consolidateProject(source: String, destination: String) async -> Bool {
        do {
            _ = try await administer {
                $0.consolidate = .with {
                    $0.sourceID = source
                    $0.destinationID = destination
                }
            }
            selectedProjectID = destination
            return true
        } catch { show(error); return false }
    }

    /// The checkout a new conversation in the project runs on: the one picked
    /// on this Mac, else the core's choice (`CreationSlice.checkouts`); nil
    /// when the user must choose.
    func checkout(forProjectID id: String) -> Dieter_V1_Checkout? {
        let values = projectDirectory[id]?.checkoutChoices ?? []
        guard let chosen = creationCheckoutIDs[id] ?? creationMemory.checkouts[id] else { return nil }
        return values.first { $0.id == chosen }
    }

    /// Picks the checkout new conversations in its project run on; the core remembers it.
    func pickCheckout(_ checkout: Dieter_V1_Checkout) {
        creationCheckoutIDs[checkout.projectID] = checkout.id
        Task {
            await perform {
                $0.rememberCreation = .with {
                    $0.projectID = checkout.projectID
                    $0.checkoutID = checkout.id
                }
            }
        }
    }

    /// Whether the project's chosen checkout is on a machine that can take
    /// work now; reports why not. Surfaces name the checkout in their
    /// targets and the core routes them to its machine.
    func checkoutIsAvailable(_ projectID: String) -> Bool {
        guard let checkout = checkout(forProjectID: projectID) else {
            errorMessage = "Choose a machine and checkout for this project."
            return false
        }
        guard let machine = endpoints.first(where: { $0.daemonID == checkout.daemonID }) else {
            errorMessage = SharedRules.shared.unenrolledMachineMessage()
            return false
        }
        if let reason = unavailableReason(machine) {
            errorMessage = reason
            return false
        }
        return phase.isConnected
    }

    func selectCheckout(_ checkout: Dieter_V1_Checkout) async {
        pickCheckout(checkout)
        resetFileSurface()
        guard section == .files, checkoutIsAvailable(checkout.projectID) else { return }
        await loadFiles()
    }

}
