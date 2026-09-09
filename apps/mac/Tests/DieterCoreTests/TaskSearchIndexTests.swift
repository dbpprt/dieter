import DieterCore
import Testing

@Test func taskSearchMatchesUnicodePrefixesAcrossFieldsAndRanksTitles() {
    let index = TaskSearchIndex(documents: [
        .init(id: "a", title: "Café capture", text: "Browser screenshot", location: "Website · Bugs", updatedAt: "1"),
        .init(id: "b", title: "Other task", text: "Fix café capture", location: "Website", updatedAt: "2"),
    ])
    #expect(index.search("CAFE capt").map(\.id) == ["a", "b"])
    #expect(index.search("screen bugs").map(\.id) == ["a"])
    #expect(index.search("capture missing").isEmpty)
    #expect(index.search("  ").isEmpty)
    #expect(index.search("💫").isEmpty)
    #expect(index.search("cafe", limit: 1).count == 1)
}

@Test func taskSearchUsesNewestDuplicateAndRemovesArchivedAndStaleWords() {
    let index = TaskSearchIndex(documents: [
        .init(id: "a", title: "Old title", text: "", location: "", updatedAt: "1"),
        .init(id: "a", title: "Renamed task", text: "", location: "", updatedAt: "2"),
        .init(id: "b", title: "Renamed archived", text: "", location: "", updatedAt: "3", archived: true),
    ])
    #expect(index.search("old").isEmpty)
    #expect(index.search("renamed").map(\.id) == ["a"])
    #expect(index.search("a").map(\.id) == ["a"])
    let updated = TaskSearchIndex(documents: [])
    #expect(updated.search("renamed").isEmpty)
}
