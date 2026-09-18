import DieterAPI
import DieterCore
import Testing
@testable import DieterMac

@Test func commandPaletteCatalogBuildsSearchableLocationsAndKeepsTheNewestDuplicate() {
    var project = Dieter_V1_Project()
    project.id = "project"
    project.name = "Dieter"
    var board = Dieter_V1_Board()
    board.id = "board"
    board.name = "Mac"
    var old = Dieter_V1_Card()
    old.id = "card"
    old.projectID = project.id
    old.boardID = board.id
    old.title = "Old title"
    old.updatedAt = "1"
    var current = old
    current.title = "Layout loop"
    current.summary = "All Chats"
    current.updatedAt = "2"

    let documents = CommandPaletteCatalog.documents(
        projects: [project], boards: [board], cards: [old, current])
    let index = TaskSearchIndex(documents: documents)
    #expect(index.search("layout").map(\.title) == ["Layout loop"])
    #expect(index.search("dieter mac").map(\.id) == ["card"])
    #expect(index.search("old").isEmpty)
}

@Test @MainActor func commandPaletteRevisionChangesOnlyWhenItsCatalogInputsChange() {
    let store = DieterStore(restoreSync: false)
    let initial = store.replica.commandSearchRevision
    var chat = Dieter_V1_Card()
    chat.id = "chat"
    chat.title = "Chat"
    chat.scope = "chat"

    store.chats = [chat]
    let changed = store.replica.commandSearchRevision
    #expect(changed > initial)
    store.chats = [chat]
    #expect(store.replica.commandSearchRevision == changed)

    chat.title = "Renamed"
    store.chats = [chat]
    #expect(store.replica.commandSearchRevision > changed)
}
