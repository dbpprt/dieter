import Foundation
import Testing

@testable import DieterCore

@Test func recognizesRemoteWorkspaceImages() throws {
    #expect(
        RemoteWorkspaceImage.relativePath(from: try #require(URL(string: "docs/screenshots/Preview%20One.PNG")))
            == "docs/screenshots/Preview One.PNG")
    #expect(
        RemoteWorkspaceImage.relativePath(from: try #require(URL(string: "./images/result.webp#preview")))
            == "images/result.webp")
    #expect(RemoteWorkspaceImage.isWorkspaceImageURL(try #require(URL(string: "file:///remote/worktree/output.jpeg"))))
    #expect(!RemoteWorkspaceImage.isWorkspaceImageURL(try #require(URL(string: "https://example.com/output.jpeg"))))
    #expect(
        RemoteWorkspaceImage.relativePath(
            from: try #require(URL(string: "file:///remote/worktree/docs/output.jpeg")),
            workspaceRoot: "/remote/worktree") == "docs/output.jpeg")
}

@Test func rejectsNonImageAndEscapingRemotePaths() throws {
    #expect(RemoteWorkspaceImage.relativePath(from: try #require(URL(string: "README.md"))) == nil)
    #expect(RemoteWorkspaceImage.relativePath(from: try #require(URL(string: "../secret.png"))) == nil)
    #expect(RemoteWorkspaceImage.relativePath(from: try #require(URL(string: "https://example.com/image.png"))) == nil)
    #expect(RemoteWorkspaceImage.relativePath(from: try #require(URL(string: "/absolute/image.png"))) == nil)
    #expect(
        RemoteWorkspaceImage.relativePath(
            from: try #require(URL(string: "file:///remote/other/image.png")), workspaceRoot: "/remote/worktree") == nil
    )
}
