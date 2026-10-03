import DieterAPI
import Foundation

struct ConversationWorkspaceRoute: Equatable {
    let endpointID: String
    let machineName: String
}

extension DieterStore {
    func machine(for card: Dieter_V1_Card) -> MachineEndpoint? {
        if card.ownerDaemonID.isEmpty { return endpoint }
        return endpoints.first { $0.daemonID == card.ownerDaemonID }
            ?? (endpoint.daemonID == card.ownerDaemonID
                ? endpoint
                : MachineEndpoint(
                    name: card.ownerDaemonID, host: endpoint.host, port: endpoint.port, secure: endpoint.secure,
                    daemonID: card.ownerDaemonID, online: false))
    }

    func endpointID(for card: Dieter_V1_Card?) -> String {
        guard let card else { return endpoint.id }
        return machine(for: card)?.id ?? "unavailable:\(card.ownerDaemonID)"
    }

    /// Workspace RPCs belong to the conversation owner, not whichever daemon
    /// most recently supplied the shared project projection. A project can be
    /// visible through one replica while its chat and checkout live on another
    /// machine.
    func conversationWorkspaceRoute(for card: Dieter_V1_Card) -> ConversationWorkspaceRoute? {
        guard let machine = machine(for: card) else { return nil }
        return ConversationWorkspaceRoute(endpointID: machine.id, machineName: machine.name)
    }

    /// Attaches the conversation's machine, whose agents and settings the
    /// composer and settings show. The conversation itself does not need
    /// this: the core opens it on its machine either way. Never connects a
    /// session that is offline.
    func ensureConversationConnection(_ card: Dieter_V1_Card, reportOffline: Bool = true) async -> Bool {
        guard let target = machine(for: card), target.online else {
            if reportOffline {
                errorMessage = "This conversation’s machine is offline. Shared board edits remain available."
            }
            return false
        }
        guard phase.isConnected else { return false }
        if target.id == endpoint.id { return true }
        await connect(to: target)
        return !Task.isCancelled && endpoint.id == target.id && phase.isConnected
    }

    func attachCheckout(projectID: String, path: String, name: String, machineID: String) async -> Bool {
        guard let target = endpoints.first(where: { $0.id == machineID }), target.online,
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
            await refreshState()
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
            await refreshState()
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
            await refreshState()
            return true
        } catch { show(error); return false }
    }

    /// The checkout a new conversation in the project runs on: the one picked
    /// on this Mac, else the core's choice (`CreationSlice.checkouts`); nil
    /// when the user must choose.
    func checkout(forProjectID id: String) -> Dieter_V1_Checkout? {
        let values = projectDirectory[id]?.checkouts.filter { !$0.detached } ?? []
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

    func ensureCheckoutConnection(_ projectID: String) async -> Bool {
        guard let checkout = checkout(forProjectID: projectID) else {
            errorMessage = "Choose a machine and checkout for this project."
            return false
        }
        guard let target = endpoints.first(where: { $0.daemonID == checkout.daemonID }), target.online else {
            errorMessage = "The selected checkout’s machine is offline."
            return false
        }
        if target.id != endpoint.id || !phase.isConnected { await connect(to: target) }
        // Surfaces name the checkout in their targets; the core routes them.
        return endpoint.id == target.id && phase.isConnected
    }

    func selectCheckout(_ checkout: Dieter_V1_Checkout) async {
        pickCheckout(checkout)
        guard await ensureCheckoutConnection(checkout.projectID) else { return }
        await refreshState()
        resetFileSurface()
        if section == .files { await loadFiles() }
    }

}
