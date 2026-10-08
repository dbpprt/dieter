import Testing
@testable import DieterMac

@Test func changeTreeCompactsSingleChildFoldersAndListsFoldersFirst() {
    let rows = ChangeTree.rows(paths: [
        "README.md",
        "src/cms/packages/dist/client.js",
        "src/cms/packages/dist/index.js",
        "src/main.go",
        "docs/services/design.md",
    ])
    #expect(
        rows.map { "\(String(repeating: "  ", count: $0.depth))\($0.name)\($0.kind == .folder ? "/" : "")" } == [
            "docs/services/",
            "  design.md",
            "src/",
            "  cms/packages/dist/",
            "    client.js",
            "    index.js",
            "  main.go",
            "README.md",
        ])
    #expect(rows.first { $0.name == "cms/packages/dist" }?.path == "src/cms/packages/dist")
    #expect(rows.first { $0.name == "src" }?.fileCount == 3)
}

@Test func changeTreeHidesTheContentsOfCollapsedFolders() {
    let paths = ["a/b/one.txt", "a/c/two.txt", "z.txt"]
    let rows = ChangeTree.rows(paths: paths, collapsed: ["a/b"])
    #expect(rows.map(\.path) == ["a", "a/b", "a/c", "a/c/two.txt", "z.txt"])
    #expect(ChangeTree.folders(paths: paths) == ["a", "a/b", "a/c"])
}
