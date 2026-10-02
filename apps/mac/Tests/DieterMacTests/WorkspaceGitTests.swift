import DieterAPI
import Testing

@testable import DieterMac

@Test func conversationWorkspaceDraftFillsTheCreationIntent() {
    var intent = ClientCreationIntent()
    ConversationWorkspaceDraft(
        mode: .worktree,
        branch: "  feature/mac-git  ",
        baseBranch: "  release  ",
        baseRemote: "  private  ",
        remotePublishMode: RemotePublishMode.pullRequest.rawValue
    ).apply(to: &intent)

    #expect(intent.workspaceMode == "worktree")
    #expect(intent.workspaceBranch == "feature/mac-git")
    #expect(intent.workspaceBaseBranch == "release")
    #expect(intent.workspaceBaseRemote == "private")
    #expect(intent.remotePublishMode == "pull_request")
}

@Test func validationCommandDraftRoundTripsLiteralArgumentsAndEnvironment() {
    var draft = ValidationCommandDraft()
    draft.name = "Unit tests"
    draft.executable = "go"
    draft.arguments = "test\n-race\n./..."
    draft.workingDirectory = "server"
    draft.environment = "GOFLAGS=-count=1\nCI=true"
    draft.timeoutSeconds = 900

    let value = draft.value
    #expect(value.arguments == ["test", "-race", "./..."])
    #expect(value.environment == ["GOFLAGS": "-count=1", "CI": "true"])
    #expect(value.timeoutSeconds == 900)

    let restored = ValidationCommandDraft(value)
    #expect(restored.name == draft.name)
    #expect(restored.executable == draft.executable)
    #expect(restored.arguments == draft.arguments)
    #expect(restored.workingDirectory == draft.workingDirectory)
}

@Test func projectSetupCarriesGitWorkspaceSettingsWithoutAModeDefault() {
    var draft = ProjectSetupDraft()
    draft.path = "/srv/repo"
    draft.name = "Repo"
    draft.baseRemote = "upstream"
    draft.baseBranch = "develop"
    var validation = Dieter_V1_ValidationCommand()
    validation.name = "Tests"
    validation.executable = "make"
    validation.arguments = ["test"]
    draft.validationCommands = [validation]

    let request = draft.request()
    #expect(request.baseRemote == "upstream")
    #expect(request.baseBranch == "develop")
    #expect(request.validationCommands.first?.arguments == ["test"])
}

@Test func workspaceReviewUsesDedicatedCompactNavigation() {
    #expect(WorkspaceReviewLayout.isCompact(width: 520))
    #expect(!WorkspaceReviewLayout.isCompact(width: 900))
    #expect(WorkspaceReviewLayout.compactBreakpoint == 680)
}
