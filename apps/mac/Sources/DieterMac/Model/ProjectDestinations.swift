import DieterAPI
import Foundation

struct ProjectDestination: Identifiable, Equatable {
    let project: Dieter_V1_Project
    let machineID: String
    let machineName: String
    let machineOnline: Bool
    let machineVersion: String
    var checkoutID: String = ""

    var id: String { checkoutID.isEmpty ? project.id : checkoutID }
    var checkout: Dieter_V1_Checkout? { project.checkouts.first { $0.id == checkoutID } }
    var title: String { "\(project.name) · \(machineName)" }
    var machineStatus: String { machineOnline ? "Online" : "Offline" }

    var detail: String {
        let path = ((checkout?.path ?? "") as NSString).abbreviatingWithTildeInPath
        return path.isEmpty ? machineStatus : "\(machineStatus) · \(path)"
    }
}

struct ProjectDestinationGroup: Identifiable, Equatable {
    let machineID: String
    let machineName: String
    let machineOnline: Bool
    let machineVersion: String
    let destinations: [ProjectDestination]

    var id: String { machineID }
    var title: String { "\(machineName) · \(machineOnline ? "Online" : "Offline")" }
}

enum ProjectDestinationCatalog {
    static func groups(
        projects: [Dieter_V1_Project],
        projectReplicaEndpointIDs: [String: String],
        endpoints: [DieterEndpoint],
        fallbackEndpoint: DieterEndpoint
    ) -> [ProjectDestinationGroup] {
        let fallbackMachine = fallbackEndpoint.daemonID == nil ? nil : fallbackEndpoint
        let destinations = projects.flatMap { project -> [ProjectDestination] in
            project.checkouts.filter { !$0.detached }.map { checkout in
                let machine = endpoints.first { $0.daemonID == checkout.daemonID }
                    ?? (fallbackMachine?.daemonID == checkout.daemonID ? fallbackMachine : nil)
                return ProjectDestination(project: project, machineID: machine?.id ?? "unavailable:\(checkout.daemonID)",
                    machineName: machine?.name ?? checkout.daemonID, machineOnline: machine?.online ?? false,
                    machineVersion: machine?.version ?? "", checkoutID: checkout.id)
            }
        }
        let grouped = Dictionary(grouping: destinations, by: \ProjectDestination.machineID)
        return grouped.compactMap { machineID, values in
            guard let first = values.first else { return nil }
            return ProjectDestinationGroup(
                machineID: machineID,
                machineName: first.machineName,
                machineOnline: first.machineOnline,
                machineVersion: first.machineVersion,
                destinations: values.sorted(by: destinationOrder)
            )
        }.sorted(by: groupOrder)
    }

    static func destination(
        projectID: String,
        in groups: [ProjectDestinationGroup]
    ) -> ProjectDestination? {
        groups.lazy.flatMap(\.destinations).first { $0.project.id == projectID }
    }

    private static func destinationOrder(_ lhs: ProjectDestination, _ rhs: ProjectDestination) -> Bool {
        let nameOrder = lhs.project.name.localizedCaseInsensitiveCompare(rhs.project.name)
        if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
        let pathOrder = (lhs.checkout?.path ?? lhs.checkoutID).localizedCaseInsensitiveCompare(rhs.checkout?.path ?? rhs.checkoutID)
        if pathOrder != .orderedSame { return pathOrder == .orderedAscending }
        return lhs.project.id < rhs.project.id
    }

    private static func groupOrder(_ lhs: ProjectDestinationGroup, _ rhs: ProjectDestinationGroup) -> Bool {
        if lhs.machineOnline != rhs.machineOnline { return lhs.machineOnline && !rhs.machineOnline }
        let nameOrder = lhs.machineName.localizedCaseInsensitiveCompare(rhs.machineName)
        if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
        return lhs.machineID < rhs.machineID
    }
}

extension DieterStore {
    func projectDestinationGroups(
        projects candidates: [Dieter_V1_Project]? = nil
    ) -> [ProjectDestinationGroup] {
        ProjectDestinationCatalog.groups(
            projects: candidates ?? projects.filter { !$0.archived },
            projectReplicaEndpointIDs: projectReplicaEndpointIDs,
            endpoints: endpoints,
            fallbackEndpoint: endpoint
        )
    }
}
