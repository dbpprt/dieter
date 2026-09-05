import SwiftUI

struct ProjectDestinationMenuContent: View {
    let groups: [ProjectDestinationGroup]
    let selectedProjectID: String
    var allowsOffline = true
    let select: (ProjectDestination) -> Void

    var body: some View {
        ForEach(groups) { group in
            Section(group.title) {
                ForEach(group.destinations) { destination in
                    Button {
                        select(destination)
                    } label: {
                        Label(
                            destination.project.name,
                            systemImage: destination.project.id == selectedProjectID ? "checkmark" : "folder"
                        )
                    }
                    .disabled(!allowsOffline && !destination.machineOnline)
                    .help(destination.detail)
                    .accessibilityLabel(
                        "\(destination.project.name), \(destination.machineName), \(destination.machineStatus)"
                    )
                }
            }
        }
    }
}
