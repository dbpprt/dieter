import DieterAPI
import Foundation

struct ProjectDestination: Identifiable, Equatable {
    let project: Dieter_V1_Project
    let machineID: String
    let machineName: String
    let machineOnline: Bool
    let machineVersion: String

    var id: String { project.id }
    var title: String { "\(project.name) · \(machineName)" }
    var machineStatus: String { machineOnline ? "Online" : "Offline" }

    var detail: String {
        let path = (project.path as NSString).abbreviatingWithTildeInPath
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
        projectEndpointIDs: [String: String],
        endpoints: [DieterEndpoint],
        fallbackEndpoint: DieterEndpoint
    ) -> [ProjectDestinationGroup] {
        let endpointByID = Dictionary(endpoints.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let fallbackMachine = fallbackEndpoint.daemonID == nil ? nil : fallbackEndpoint
        let destinations = projects.map { project in
            let mappedID = projectEndpointIDs[project.id]
            let machine = mappedID.flatMap { endpointByID[$0] }
                ?? (mappedID == fallbackMachine?.id || mappedID == nil ? fallbackMachine : nil)
            return ProjectDestination(
                project: project,
                machineID: mappedID ?? machine?.id ?? "unassigned",
                machineName: machine?.name ?? "Unknown machine",
                machineOnline: machine?.online ?? false,
                machineVersion: machine?.version ?? ""
            )
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
        let pathOrder = lhs.project.path.localizedCaseInsensitiveCompare(rhs.project.path)
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
            projectEndpointIDs: projectEndpointIDs,
            endpoints: endpoints,
            fallbackEndpoint: endpoint
        )
    }
}
