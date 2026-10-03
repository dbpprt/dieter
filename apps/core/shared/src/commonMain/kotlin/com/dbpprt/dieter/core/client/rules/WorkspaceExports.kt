package com.dbpprt.dieter.core.client.rules

import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.api.v1.PullRequestSummary
import com.dbpprt.dieter.api.v1.WorkspaceSummary
import com.dbpprt.dieter.client.v1.ChangedFileLabel
import com.dbpprt.dieter.client.v1.GitOperationForm as ClientGitOperationForm
import com.dbpprt.dieter.client.v1.GitFormCopy
import com.dbpprt.dieter.client.v1.GitFormNotice
import com.dbpprt.dieter.client.v1.GitOperationFormSpec
import com.dbpprt.dieter.client.v1.MergeStrategyOption
import com.dbpprt.dieter.client.v1.WorkspaceBadgeView
import com.dbpprt.dieter.client.v1.WorkspaceTone
import com.dbpprt.dieter.core.workspace.ChangedFiles
import com.dbpprt.dieter.core.workspace.Commits
import com.dbpprt.dieter.core.workspace.GitFormField
import com.dbpprt.dieter.core.workspace.GitOperationForm
import com.dbpprt.dieter.core.workspace.GitOperations
import com.dbpprt.dieter.core.workspace.OperationStart
import com.dbpprt.dieter.core.workspace.StatusTone
import com.dbpprt.dieter.core.workspace.WorkspaceBadge

/**
 * Workspace presentation as views call it while rendering: a card's
 * workspace badge, a changed file's labels, and Git operation forms.
 */
object WorkspaceExports {
    /**
     * The badge of a card's workspace. [mode], [state], [branch], [changedFiles],
     * [ahead], and [behind] are the card's workspace summary; [cardMode] and
     * [cardBranch] the card's own workspace fields, used when the summary has
     * none; [pullRequest] its pull request number, 0 for none.
     */
    fun workspaceBadge(
        mode: String, state: String, branch: String, changedFiles: Int, ahead: Int, behind: Int,
        cardMode: String, cardBranch: String, pullRequest: Int,
    ): WorkspaceBadgeView {
        val card = Card(
            workspace_mode = cardMode, workspace_branch = cardBranch,
            workspace = WorkspaceSummary(mode = mode, state = state, branch = branch, changed_files = changedFiles, ahead = ahead, behind = behind),
            pull_request = if (pullRequest > 0) PullRequestSummary(number = pullRequest) else null,
        )
        val badge = WorkspaceBadge.of(card) ?: return WorkspaceBadgeView()
        return WorkspaceBadgeView(shown = true, title = badge.title, full_title = badge.fullTitle, accessibility_label = badge.accessibilityLabel, conflicted = badge.conflicted)
    }

    /** A changed file's status badge and title, name, and directory. */
    fun changedFile(path: String, status: String, conflicted: Boolean, untracked: Boolean): ChangedFileLabel = ChangedFileLabel(
        badge = ChangedFiles.badge(status, conflicted, untracked), title = ChangedFiles.title(status, conflicted, untracked),
        filename = ChangedFiles.filename(path), directory = ChangedFiles.directory(path),
    )

    /**
     * How to collect a [kind] operation's form, filled from the conversation's
     * [cardTitle] and [cardPrompt] and its pull request's [pullRequestHeadSha];
     * [baseBranch] names the base in the summary ("main").
     */
    fun gitOperationForm(kind: String, cardTitle: String, cardPrompt: String, pullRequestHeadSha: String, baseBranch: String): GitOperationFormSpec =
        GitOperationFormSpec(
            initial = wire(GitOperationForm.initial(kind, cardTitle, cardPrompt, pullRequestHeadSha)),
            title = GitOperations.title(kind),
            summary = GitOperations.description(kind, baseBranch.ifBlank { "base" }).orEmpty(),
            destructive = GitOperations.destructive(kind),
            start = when (GitOperations.start(kind)) {
                OperationStart.IMMEDIATE -> GitOperationFormSpec.Start.START_IMMEDIATE
                OperationStart.CONFIRM -> GitOperationFormSpec.Start.START_CONFIRM
                OperationStart.FORM -> GitOperationFormSpec.Start.START_FORM
            },
            inputs = GitOperations.fields(kind).map(::input),
            strategies = GitOperations.strategies(kind).map { (strategy, title) -> MergeStrategyOption(strategy = strategy, title = title) },
            copy = GitOperations.copy(kind).let {
                GitFormCopy(
                    subject = it.subject, subject_placeholder = it.subjectPlaceholder, body = it.body, body_placeholder = it.bodyPlaceholder,
                    stage_all = it.stageAll, fetch = it.fetch, validate = it.validate, strategy = it.strategy, draft = it.draft, push = it.push,
                    force_with_lease = it.forceWithLease, expected_remote_sha = it.expectedRemoteSha,
                    expected_remote_sha_placeholder = it.expectedRemoteShaPlaceholder, expected_remote_sha_help = it.expectedRemoteShaHelp,
                    target_card_id = it.targetCardId, target_card_id_placeholder = it.targetCardIdPlaceholder,
                )
            },
            notice = GitOperations.notice(kind)?.let { GitFormNotice(title = it.title, detail = it.detail, tone = tone(it.tone)) },
        )

    /** Whether [form] shows [input] with its current values. */
    fun gitOperationShows(form: ClientGitOperationForm, input: GitOperationFormSpec.Input): Boolean =
        GitFormField.entries.firstOrNull { input(it) == input }?.let(core(form)::shows) ?: true

    /** Whether [form] can start: a commit and a pull request need a subject, adopting a conversation, a forced push the remote head. */
    fun gitOperationReady(form: ClientGitOperationForm): Boolean = core(form).ready

    /** The core's form for [wire]; an empty strategy is the kind's default. */
    internal fun core(wire: ClientGitOperationForm): GitOperationForm = GitOperationForm(
        kind = wire.kind, subject = wire.subject, body = wire.body, stageAll = wire.stage_all, validate = wire.validate, draft = wire.draft,
        strategy = wire.strategy.ifEmpty { GitOperations.strategies(wire.kind).firstOrNull()?.first ?: "squash" },
        fetch = wire.fetch, push = wire.push, forceWithLease = wire.force_with_lease, expectedRemoteSha = wire.expected_remote_sha,
        targetCardId = wire.target_card_id,
    )

    internal fun wire(form: GitOperationForm): ClientGitOperationForm = ClientGitOperationForm(
        kind = form.kind, subject = form.subject, body = form.body, stage_all = form.stageAll, validate = form.validate, fetch = form.fetch,
        draft = form.draft, push = form.push, strategy = form.strategy, force_with_lease = form.forceWithLease,
        expected_remote_sha = form.expectedRemoteSha, target_card_id = form.targetCardId,
    )

    internal fun tone(tone: StatusTone): WorkspaceTone = when (tone) {
        StatusTone.NEUTRAL -> WorkspaceTone.WORKSPACE_TONE_NEUTRAL
        StatusTone.ACTIVE -> WorkspaceTone.WORKSPACE_TONE_ACTIVE
        StatusTone.SUCCESS -> WorkspaceTone.WORKSPACE_TONE_SUCCESS
        StatusTone.WARNING -> WorkspaceTone.WORKSPACE_TONE_WARNING
        StatusTone.DANGER -> WorkspaceTone.WORKSPACE_TONE_DANGER
    }

    private fun input(field: GitFormField): GitOperationFormSpec.Input = when (field) {
        GitFormField.SUBJECT -> GitOperationFormSpec.Input.INPUT_SUBJECT
        GitFormField.BODY -> GitOperationFormSpec.Input.INPUT_BODY
        GitFormField.STAGE_ALL -> GitOperationFormSpec.Input.INPUT_STAGE_ALL
        GitFormField.FETCH -> GitOperationFormSpec.Input.INPUT_FETCH
        GitFormField.VALIDATE -> GitOperationFormSpec.Input.INPUT_VALIDATE
        GitFormField.STRATEGY -> GitOperationFormSpec.Input.INPUT_STRATEGY
        GitFormField.DRAFT -> GitOperationFormSpec.Input.INPUT_DRAFT
        GitFormField.PUSH -> GitOperationFormSpec.Input.INPUT_PUSH
        GitFormField.FORCE_WITH_LEASE -> GitOperationFormSpec.Input.INPUT_FORCE_WITH_LEASE
        GitFormField.EXPECTED_REMOTE_SHA -> GitOperationFormSpec.Input.INPUT_EXPECTED_REMOTE_SHA
        GitFormField.TARGET_CARD_ID -> GitOperationFormSpec.Input.INPUT_TARGET_CARD_ID
    }

    /** A commit's abbreviated hash, at most seven characters. */
    fun shortSha(shortSha: String, sha: String): String = Commits.shortSha(shortSha, sha)
}
