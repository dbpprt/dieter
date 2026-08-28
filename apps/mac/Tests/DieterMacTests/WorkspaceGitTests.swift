import DieterAPI
import Testing
@testable import DieterMac

@Test func conversationWorkspaceDraftPopulatesCreateRequest() {
    var request = Dieter_V1_CreateConversationRequest()
    ConversationWorkspaceDraft(mode: .worktree, branch: "  feature/mac-git  ", baseBranch: "  release  ").apply(to: &request)

    #expect(request.workspaceMode == "worktree")
    #expect(request.workspaceBranch == "feature/mac-git")
    #expect(request.workspaceBaseBranch == "release")
}

@Test func unifiedDiffParserTracksBothSidesOfAHunk() {
    let lines = UnifiedDiffParser.parse("""
    diff --git a/a.swift b/a.swift
    @@ -10,3 +10,4 @@
     context
    -old
    +new
    +extra
     tail
    """)

    let deletion = lines.first { $0.kind == .deletion }
    let additions = lines.filter { $0.kind == .addition }
    #expect(deletion?.oldLine == 11)
    #expect(deletion?.newLine == nil)
    #expect(additions.map(\.newLine) == [11, 12])
    #expect(lines.last?.oldLine == 12)
    #expect(lines.last?.newLine == 13)
}

@Test func workspaceActionAvailabilityLocksNormalActionsDuringConflicts() {
    let availability = WorkspaceActionAvailability(
        agentActive: false,
        operationActive: false,
        workspaceState: "conflicted",
        workspaceMode: "worktree",
        changedFiles: 2,
        hasCommits: true,
        hasRemote: true,
        scmAuthenticated: true,
        hasPullRequest: true
    )

    #expect(!availability.allows(.commit))
    #expect(!availability.allows(.mergePullRequest))
    #expect(availability.allows(.continueConflict))
    #expect(availability.allows(.abortConflict))
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

@Test func projectSetupCarriesGitWorkspaceDefaults() {
    var draft = ProjectSetupDraft()
    draft.path = "/srv/repo"
    draft.name = "Repo"
    draft.defaultWorkspaceMode = "worktree"
    draft.baseRemote = "upstream"
    draft.baseBranch = "develop"
    var validation = Dieter_V1_ValidationCommand()
    validation.name = "Tests"
    validation.executable = "make"
    validation.arguments = ["test"]
    draft.validationCommands = [validation]

    let request = draft.request()
    #expect(request.defaultWorkspaceMode == "worktree")
    #expect(request.baseRemote == "upstream")
    #expect(request.baseBranch == "develop")
    #expect(request.validationCommands.first?.arguments == ["test"])
}
