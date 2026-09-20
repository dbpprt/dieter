import DieterAPI
import Foundation

extension DieterStore {
    func machine(for card: Dieter_V1_Card) -> DieterEndpoint? {
        if card.ownerDaemonID.isEmpty { return endpoint }
        return endpoints.first { $0.daemonID == card.ownerDaemonID }
            ?? (endpoint.daemonID == card.ownerDaemonID ? endpoint : DieterEndpoint(name: card.ownerDaemonID, host: endpoint.host, port: endpoint.port, secure: endpoint.secure, daemonID: card.ownerDaemonID, online: false))
    }

    func endpointID(for card: Dieter_V1_Card?) -> String {
        guard let card else { return endpoint.id }
        return machine(for: card)?.id ?? "unavailable:\(card.ownerDaemonID)"
    }

    func ensureConversationConnection(_ card: Dieter_V1_Card, reportOffline: Bool = true) async -> Bool {
        guard let target = machine(for: card), target.online else {
            if reportOffline { errorMessage = "This conversation’s machine is offline. Shared board edits remain available." }
            return false
        }
        if target.id == endpoint.id, phase.isConnected, rpc != nil { return true }
        await connect(to: target)
        return !Task.isCancelled && endpoint.id == target.id && phase.isConnected && rpc != nil
    }

    func attachCheckout(projectID: String, path: String, name: String, machineID: String) async -> Bool {
        guard let target = endpoints.first(where: { $0.id == machineID }), target.online else { return false }
        await connect(to: target)
        guard endpoint.id == target.id, let rpc else { return false }
        var request = Dieter_V1_AttachCheckoutRequest()
        request.projectID = projectID; request.path = path; request.name = name
        do {
            _ = try await rpc.attachCheckout(request)
            await refreshState()
            await refreshMachineDirectory()
            return true
        } catch { show(error); return false }
    }
    func detachCheckout(_ checkout: Dieter_V1_Checkout) async {
        guard let machine = endpoints.first(where: { $0.daemonID == checkout.daemonID }), machine.online else {
            errorMessage = "The checkout’s machine is offline."; return
        }
        do {
            var request = Dieter_V1_CheckoutRef(); request.checkoutID = checkout.id
            if machine.id == endpoint.id, let rpc { _ = try await rpc.detachCheckout(request) }
            else {
                let lease = try await selectDirectoryDataPlane(for: machine)
                defer { lease.release() }
                _ = try await lease.rpc.detachCheckout(request)
            }
            creationCheckoutIDs.removeValue(forKey: checkout.projectID)
            await refreshState(); await refreshMachineDirectory()
        } catch { show(error) }
    }

    func consolidateProject(source: String, destination: String) async -> Bool {
        guard await ensureReplicaConnection(source), let rpc else { return false }
        do {
            _ = try await rpc.consolidateProject(source: source, destination: destination)
            selectedProjectID = destination
            await refreshState(); await refreshMachineDirectory()
            return true
        } catch { show(error); return false }
    }

    func checkout(forProjectID id: String) -> Dieter_V1_Checkout? {
        let values = projectDirectory[id]?.checkouts.filter { !$0.detached } ?? []
        if let selected = creationCheckoutIDs[id] { return values.first { $0.id == selected } }
        return values.count == 1 ? values.first : nil
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
        guard endpoint.id == target.id, phase.isConnected, let rpc else { return false }
        rpc.selectCheckout(projectID: projectID, checkoutID: checkout.id)
        return true
    }

    func selectCheckout(_ checkout: Dieter_V1_Checkout) async {
        creationCheckoutIDs[checkout.projectID] = checkout.id
        guard await ensureCheckoutConnection(checkout.projectID) else { return }
        await refreshState()
        resetFileSurface()
        if section == .files { await loadFiles() }
    }

}
