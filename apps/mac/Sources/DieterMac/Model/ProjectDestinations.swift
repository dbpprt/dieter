import DieterAPI
import DieterShared
import Foundation

/// A checkout a new chat can run in, as the core lays out the destinations.
struct ProjectDestination: Identifiable, Equatable {
    let project: Dieter_V1_Project
    let destination: ClientChatDestination
    /// The machine the checkout is on, as its group names it.
    let machineName: String
    let machineOnline: Bool

    var id: String { checkoutID.isEmpty ? project.id : checkoutID }
    var machineID: String { destination.machineID }
    var checkoutID: String { destination.checkoutID }
    var checkout: Dieter_V1_Checkout? { project.checkouts.first { $0.id == checkoutID } }
    /// "app · Studio".
    var title: String { destination.title }
    /// "Online · ~/src/app".
    var detail: String { destination.detail }
    /// The project's name, told apart from the machine's other checkouts of it.
    var optionTitle: String { destination.optionTitle }
}

/// A machine and the checkouts on it a new chat can run in.
struct ProjectDestinationGroup: Identifiable, Equatable {
    let group: ClientChatDestinationGroup
    let destinations: [ProjectDestination]

    var id: String { machineID }
    var machineID: String { group.machineID }
    var machineName: String { group.machineName }
    var machineOnline: Bool { group.machineOnline }
    var machineVersion: String { group.machineVersion }
    /// "Studio · Online".
    var title: String { group.title }
}

enum ProjectDestinationCatalog {
    /// `projects`' attached checkouts on the known machines, grouped and ordered by the core.
    static func groups(
        projects: [Dieter_V1_Project], endpoints: [MachineEndpoint], fallbackEndpoint: MachineEndpoint
    ) -> [ProjectDestinationGroup] {
        let machines = (endpoints + [fallbackEndpoint]).compactMap { endpoint -> ClientChatDestinationMachine? in
            guard let daemonID = endpoint.daemonID else { return nil }
            return .with {
                $0.daemonID = daemonID
                $0.id = endpoint.id
                $0.name = endpoint.name
                $0.online = endpoint.online
                $0.version = endpoint.releaseVersion
            }
        }
        var unique: [String: ClientChatDestinationMachine] = [:]
        for machine in machines where unique[machine.daemonID] == nil { unique[machine.daemonID] = machine }
        let input = ClientChatDestinationInput.with {
            $0.projects = projects
            $0.machines = machines.filter { unique[$0.daemonID] == $0 && !$0.daemonID.isEmpty }
        }
        let byID = Dictionary(projects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ClientChatDestinationGroups(rules: SharedRules.shared.chatDestinations(input: input.rulesData)).groups
            .map {
                group in
                ProjectDestinationGroup(
                    group: group,
                    destinations: group.destinations.compactMap { destination in
                        byID[destination.projectID].map {
                            ProjectDestination(
                                project: $0, destination: destination, machineName: group.machineName,
                                machineOnline: group.machineOnline)
                        }
                    })
            }
    }

    static func destination(projectID: String, in groups: [ProjectDestinationGroup]) -> ProjectDestination? {
        groups.lazy.flatMap(\.destinations).first { $0.project.id == projectID }
    }

    static func destination(
        machineID: String, projectID: String, checkoutID: String, in groups: [ProjectDestinationGroup]
    ) -> ProjectDestination? {
        guard let group = groups.first(where: { $0.machineID == machineID }) else { return nil }
        if !checkoutID.isEmpty,
            let exact = group.destinations.first(where: { $0.project.id == projectID && $0.checkoutID == checkoutID })
        {
            return exact
        }
        return group.destinations.first { $0.project.id == projectID }
    }

    /// The destination to show first, as the core picks it.
    static func preferredDestination(
        preferredMachineID: String, preferredProjectID: String, preferredCheckoutID: String = "",
        in groups: [ProjectDestinationGroup]
    ) -> ProjectDestination? {
        let encoded = ClientChatDestinationGroups.with { $0.groups = groups.map(\.group) }
        let chosen = ClientChatDestination(
            rules: SharedRules.shared.preferredChatDestination(
                groups: encoded.rulesData, machineId: preferredMachineID, projectId: preferredProjectID,
                checkoutId: preferredCheckoutID))
        guard !chosen.projectID.isEmpty else { return nil }
        return groups.lazy.flatMap(\.destinations).first {
            $0.machineID == chosen.machineID && $0.project.id == chosen.projectID && $0.checkoutID == chosen.checkoutID
        }
    }
}

extension DieterStore {
    func projectDestinationGroups(projects candidates: [Dieter_V1_Project]? = nil) -> [ProjectDestinationGroup] {
        ProjectDestinationCatalog.groups(
            projects: candidates ?? projects.filter { !$0.archived }, endpoints: endpoints, fallbackEndpoint: endpoint)
    }
}
