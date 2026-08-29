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

@Test func activeGitOperationIsReconciledAfterWorkspaceClearsItsOperationID() {
    #expect(GitOperationReconciliation.operationID(
        workspaceOperationID: "",
        observedOperationID: "gitop_stale",
        observedStatus: "running"
    ) == "gitop_stale")
    #expect(GitOperationReconciliation.operationID(
        workspaceOperationID: "",
        observedOperationID: "gitop_finished",
        observedStatus: "succeeded"
    ) == nil)
    #expect(GitOperationReconciliation.operationID(
        workspaceOperationID: "gitop_current",
        observedOperationID: nil,
        observedStatus: nil
    ) == "gitop_current")
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

@Test func changedFilesHaveCompactStablePresentation() {
    #expect(WorkspaceChangePresentation.badge(status: "modified") == "M")
    #expect(WorkspaceChangePresentation.badge(status: "added") == "A")
    #expect(WorkspaceChangePresentation.badge(status: "modified", conflicted: true) == "!")
    #expect(WorkspaceChangePresentation.badge(status: "modified", untracked: true) == "U")
    #expect(WorkspaceChangePresentation.title(status: "renamed") == "Renamed")
    #expect(WorkspaceChangePresentation.filename("Sources/App/Workspace.swift") == "Workspace.swift")
    #expect(WorkspaceChangePresentation.directory("Sources/App/Workspace.swift") == "Sources/App")
    #expect(WorkspaceChangePresentation.directory("README.md").isEmpty)
}

@Test func workspaceReviewSelectionSurvivesRefreshAndFallsBackSafely() {
    #expect(WorkspaceReviewSelectionResolver.resolve(
        currentPath: "Sources/App.swift",
        currentCommitSHA: "",
        filePaths: ["README.md", "Sources/App.swift"],
        commitSHAs: ["abc"]
    ) == .init(path: "Sources/App.swift", commitSHA: ""))
    #expect(WorkspaceReviewSelectionResolver.resolve(
        currentPath: "Removed.swift",
        currentCommitSHA: "",
        filePaths: [],
        commitSHAs: ["abc"]
    ) == .init(path: "", commitSHA: "abc"))
    #expect(WorkspaceReviewSelectionResolver.resolve(
        currentPath: "Removed.swift",
        currentCommitSHA: "old",
        filePaths: [],
        commitSHAs: []
    ) == .init(path: "", commitSHA: ""))
}
