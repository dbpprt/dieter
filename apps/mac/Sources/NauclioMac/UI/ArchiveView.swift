import SwiftUI

struct ArchiveView: View {
    @Environment(NauclioStore.self) private var store
    @State private var scope = "Cards"

    private var itemCount: Int {
        switch scope {
        case "Chats": store.chats.filter(\.archived).count
        case "Projects": store.archivedProjects.count
        default: store.archivedCards.count
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            FluidPaneChrome(background: NauclioTheme.background, spacing: 9) {
                HStack(spacing: 10) {
                    PaneTitleBlock(
                        title: "Archive",
                        subtitle: "\(itemCount) archived \(scope.lowercased())",
                        symbol: "archivebox",
                        prominent: true
                    )
                    Button { Task { await store.loadArchive() } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(NauclioIconButtonStyle()).help("Refresh archive")
                }
            } secondary: {
                Picker("Scope", selection: $scope) {
                    Text("Cards").tag("Cards")
                    Text("Chats").tag("Chats")
                    Text("Projects").tag("Projects")
                }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 320)
            }
            List {
                if scope == "Cards" {
                    ForEach(store.archivedCards, id: \.id) { card in
                        HStack { VStack(alignment: .leading) { Text(card.title).fontWeight(.semibold); Text(card.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2) }; Spacer(); Button("Restore") { Task { await store.archive(card, archived: false); await store.loadArchive() } }.buttonStyle(NauclioSecondaryButtonStyle()) }
                            .padding(11).background(NauclioTheme.surface.opacity(0.48), in: RoundedRectangle(cornerRadius: 9))
                            .listRowSeparator(.hidden).listRowBackground(Color.clear)
                    }
                } else if scope == "Chats" {
                    ForEach(store.chats.filter(\.archived), id: \.id) { card in
                        HStack { VStack(alignment: .leading) { Text(card.title).fontWeight(.semibold); Text(card.updatedAt).font(.caption).foregroundStyle(.secondary) }; Spacer(); Button("Restore") { Task { await store.archive(card, archived: false); await store.loadArchive() } }.buttonStyle(NauclioSecondaryButtonStyle()) }
                            .padding(11).background(NauclioTheme.surface.opacity(0.48), in: RoundedRectangle(cornerRadius: 9))
                            .listRowSeparator(.hidden).listRowBackground(Color.clear)
                    }
                } else {
                    ForEach(store.archivedProjects, id: \.id) { project in
                        HStack { VStack(alignment: .leading) { Text(project.name).fontWeight(.semibold); Text(project.path).font(.caption).foregroundStyle(.secondary) }; Spacer(); Button("Restore") { Task { await store.setProjectArchived(id: project.id, archived: false) } }.buttonStyle(NauclioSecondaryButtonStyle()) }
                            .padding(11).background(NauclioTheme.surface.opacity(0.48), in: RoundedRectangle(cornerRadius: 9))
                            .listRowSeparator(.hidden).listRowBackground(Color.clear)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .background(NauclioTheme.background)
        .task { await store.loadArchive() }
    }
}
