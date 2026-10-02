import DieterAPI
import Foundation
import SharedCore
import Testing
@testable import DieterMac

@MainActor private func waitForWorkspace(_ condition: () -> Bool) async throws {
    for _ in 0..<1_000 {
        if condition() { return }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    throw CocoaError(.coderValueNotFound)
}

private let reviewed = WorkspaceTarget(endpointID: "gateway#machine", projectID: "project", conversationID: "c_card")

private func reviewTarget(_ card: String = "c_card") -> ClientReviewTarget {
    .with {
        $0.cardID = card
        $0.daemonID = "machine"
    }
}

@Test @MainActor func reviewFoldsTheCoresRowsAvailabilityAndToast() async throws {
    let core = ScriptedCoreClient(), model = WorktreeChangesModel()
    model.bind(target: reviewed, core: core, card: nil)
    await model.loadWorkspaceSurface()
    let scope = try #require(core.commands.first?.review.scope)
    #expect(core.commands.first?.review.action == .bind(reviewTarget()))
    core.emit(.review, scope: scope) {
        $0.review = .with {
            $0.cardID = "c_card"
            $0.daemonID = "machine"
            $0.selectedPath = "a.swift"
            $0.displayRows = [
                .with {
                    $0.hunk = .with {
                        $0.id = 0; $0.text = "@@ -1 +1 @@"; $0.additions = 1; $0.deletions = 1
                    }
                },
                .with {
                    $0.line = .with {
                        $0.row = .with {
                            $0.id = 1; $0.kind = .deletion; $0.text = "-old"; $0.oldLine = 1
                        }
                        $0.commentable = true
                    }
                },
                .with {
                    $0.line = .with {
                        $0.row = .with {
                            $0.id = 2; $0.kind = .addition; $0.text = "+new"; $0.newLine = 1
                        }
                    }
                },
            ]
            $0.diffMore = true
            $0.availability = .with {
                $0.allowed = ["commit", "merge_local"]
                $0.allowsMergeFlow = true
                $0.mode = "worktree"
            }
            $0.mergeStep = "merge"
            $0.toast = "Commit succeeded"
            $0.conflicted = true
        }
    }
    #expect(model.selectedChangePath == "a.swift")
    #expect(model.conflicted)
    #expect(model.diff.rows.map(\.id) == [0, 1, 2])
    guard case .line(let deletion) = model.diff.rows[1] else {
        Issue.record("the deletion is a line row")
        return
    }
    #expect(deletion.line.kind == .deletion && deletion.line.oldLine == 1 && deletion.line.newLine == nil)
    #expect(deletion.commentable)
    #expect(model.diff.more)
    #expect(model.availability.allows(.commit) && !model.availability.allows(.push))
    #expect(model.availability.allowsMergeFlow)
    #expect(model.mergeFlowStep == .merge)
    #expect(model.workspaceToast?.message == "Commit succeeded")
    try await waitForWorkspace { core.commands.contains { $0.review.action == .clearToast_p(ClientStep()) } }
    // An update that leaves the rows unchanged keeps the ones shown.
    core.emit(.review, scope: scope) {
        $0.review = .with {
            $0.cardID = "c_card"
            $0.daemonID = "machine"
            $0.selectedPath = "a.swift"
            $0.diffUnchanged = true
            $0.conflicted = true
        }
    }
    #expect(model.diff.rows.count == 3)

    // A slice for another conversation is stale.
    core.emit(.review, scope: scope) {
        $0.review = .with {
            $0.cardID = "c_other"
            $0.daemonID = "machine"
            $0.selectedPath = "other.swift"
        }
    }
    #expect(model.selectedChangePath == "a.swift")
}

@Test @MainActor func reviewCommentsMergesAndOperationsGoThroughTheCore() async throws {
    let core = ScriptedCoreClient(), model = WorktreeChangesModel()
    core.handler = { command in
        switch command.review.action {
        case .addComment?: .with { $0.changeComment = .with { $0.id = "comment" } }
        case .merge?: .with { $0.outcome = .with { $0.succeeded = true } }
        case .start?:
            .with {
                $0.gitOperation = .with {
                    $0.id = "op"; $0.status = "running"
                }
            }
        default: .with { $0.done = ClientDone() }
        }
    }
    model.authorName = "Reviewer"
    model.bind(target: reviewed, core: core, card: .with { $0.id = "c_card" })
    let line = UnifiedDiffLine(id: 7, kind: .addition, text: "+x", oldLine: nil, newLine: 3)
    #expect(await model.addChangeComment(line: line, body: "Looks good"))
    #expect(await model.startGitOperation(form: .with { $0.kind = "validate" }))
    #expect(
        await model.performMergeFlow(
            strategy: "squash", subject: "Ship it", body: "", validate: true, removeWorkspace: true,
            moveCardToDone: false))
    let actions = core.commands.map(\.review.action)
    #expect(
        actions.contains(
            .addComment(
                .with {
                    $0.rowID = 7; $0.body = "Looks good"; $0.author = "Reviewer"
                })))
    #expect(
        actions.contains(
            .start(.with { $0.kind = "validate" })))
    #expect(
        actions.contains(
            .merge(
                .with {
                    $0.strategy = "squash"
                    $0.subject = "Ship it"
                    $0.validate = true
                    $0.removeWorkspace = true
                })))
}

@Test @MainActor func projectChangesBindTheCheckoutAndLetTheCoreOpenTheFirstChange() async throws {
    let core = ScriptedCoreClient(), model = ProjectChangesModel()
    model.bind(projectID: "project", checkoutID: "checkout", daemonID: "machine", core: core)
    await model.refresh()
    let scope = try #require(core.commands.first?.projectChanges.scope)
    #expect(
        core.commands.first?.projectChanges.action
            == .bind(
                .with {
                    $0.projectID = "project"
                    $0.checkoutID = "checkout"
                    $0.daemonID = "machine"
                    $0.selectFirst = true
                }))
    core.emit(.projectChanges, scope: scope) {
        $0.projectChanges = .with {
            $0.projectID = "project"
            $0.checkoutID = "checkout"
            $0.daemonID = "machine"
            $0.changes = .with {
                $0.files = [
                    .with {
                        $0.path = "staged.swift"; $0.staged = true
                    },
                    .with {
                        $0.path = "edited.swift"; $0.unstaged = true
                    },
                ]
            }
            $0.selection = .with { $0.path = "edited.swift" }
            $0.allowed = ["stage", "commit"]
        }
    }
    #expect(model.selection == ProjectChangeSelection(path: "edited.swift", section: "unstaged"))
    #expect(model.allows("stage") && !model.allows("push"))
    // A slice for another checkout is stale.
    core.emit(.projectChanges, scope: scope) {
        $0.projectChanges = .with {
            $0.projectID = "project"
            $0.checkoutID = "elsewhere"
            $0.daemonID = "machine"
        }
    }
    #expect(model.changes?.files.count == 2)
}

@Test @MainActor func projectCommitKeepsItsDraftUntilTheCoreReportsSuccess() async throws {
    let core = ScriptedCoreClient(), model = ProjectChangesModel()
    var succeeds = false
    core.handler = { command in
        switch command.projectChanges.action {
        case .run?: return .with { $0.outcome = .with { $0.succeeded = succeeds } }
        default:
            return .with {
                $0.projectChanges = .with {
                    $0.projectID = "project"
                    $0.checkoutID = "checkout"
                    $0.daemonID = "machine"
                    $0.changes = .with {
                        $0.files = [
                            .with {
                                $0.path = "a.swift"; $0.staged = true
                            }
                        ]
                    }
                }
            }
        }
    }
    model.bind(projectID: "project", checkoutID: "checkout", daemonID: "machine", core: core)
    await model.refresh()
    model.commitSubject = "Subject"
    #expect(await model.startOperation(kind: "commit", subject: "Subject")?.value == false)
    #expect(model.commitSubject == "Subject")
    succeeds = true
    #expect(await model.startOperation(kind: "commit", subject: "Subject")?.value == true)
    #expect(model.commitSubject.isEmpty)
}
