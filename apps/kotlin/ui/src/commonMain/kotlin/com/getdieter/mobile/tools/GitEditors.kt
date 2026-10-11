package com.getdieter.mobile.tools

import androidx.compose.foundation.layout.*
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.getdieter.client.v1.*
import com.getdieter.core.workspace.GitFormField
import com.getdieter.core.workspace.GitOperationForm as OperationForm
import com.getdieter.core.workspace.GitOperations
import com.getdieter.mobile.app.*
import com.getdieter.mobile.design.*
import com.getdieter.mobile.design.Tone

@Composable
internal fun MergeEditor(
    view: ReviewSlice,
    title: String,
    dismiss: () -> Unit,
    submit: (ReviewMerge) -> Unit,
) {
    val strategies = view.merge_readiness?.strategies.orEmpty()
    var strategy by remember { mutableStateOf(strategies.firstOrNull()?.strategy ?: "squash") }
    var subject by remember { mutableStateOf(title) }
    var body by remember { mutableStateOf("") }
    var validate by remember { mutableStateOf(true) }
    var remove by remember { mutableStateOf(false) }
    var done by remember { mutableStateOf(true) }
    Sheet(
        "Merge into ${view.availability?.merge_destination.orEmpty()}",
        dismiss,
        confirm =
            ChromeAction(
                "merge-confirm",
                "Merge",
                Glyph.MERGE,
                enabled =
                    view.merge_readiness?.blocked != true &&
                        !view.submitting &&
                        (strategy == "fast_forward" || subject.isNotBlank()),
            ) {
                submit(ReviewMerge(strategy, subject, body, validate, remove, done))
            },
    ) {
        Group(listOf(0)) { _, position ->
            PickerRow(
                "Strategy",
                strategies.firstOrNull { it.strategy == strategy }?.title ?: strategy,
                strategies.map { it.strategy to it.title },
                strategy,
                strategies.isNotEmpty(),
                position,
                Glyph.MERGE,
            ) {
                strategy = it
            }
        }
        strategies
            .firstOrNull { it.strategy == strategy }
            ?.caption
            ?.takeIf { it.isNotEmpty() }
            ?.let { SectionFooter(it) }
        if (strategy != "fast_forward") {
            SectionHeader("Commit message")
            FormColumn {
                MobileTextField(
                    subject,
                    { subject = it },
                    Modifier.fillMaxWidth(),
                    label = { Text("Subject") },
                    placeholder = { Text("Subject") },
                    singleLine = true,
                )
                MobileTextField(
                    body,
                    { body = it },
                    Modifier.fillMaxWidth(),
                    label = { Text("Body") },
                    placeholder = { Text("Description (optional)") },
                    minLines = 3,
                )
            }
        }
        SectionHeader("Options")
        Group(listOf(0, 1, 2)) { index, position ->
            when (index) {
                0 ->
                    ListRow(
                        "Run validation first",
                        position = position,
                        trailing = { DSwitch(validate, { validate = it }) },
                    )
                1 ->
                    ListRow(
                        "Remove workspace afterwards",
                        position = position,
                        trailing = { DSwitch(remove, { remove = it }) },
                    )
                else ->
                    ListRow(
                        "Move card to Done",
                        position = position,
                        trailing = { DSwitch(done, { done = it }) },
                    )
            }
        }
        val checks = view.merge_readiness?.items.orEmpty()
        if (checks.isNotEmpty()) {
            SectionHeader("Readiness")
            Group(checks) { check, position ->
                val danger = check.tone == WorkspaceTone.WORKSPACE_TONE_DANGER
                ListRow(
                    check.text,
                    position = position,
                    glyph = if (danger) Glyph.ERROR else Glyph.CHECK_CIRCLE,
                    glyphTint = if (danger) palette.destructive else palette.success,
                    titleMaxLines = 2,
                )
            }
        }
    }
}

@Composable
internal fun GitOperationEditor(
    kind: String,
    card: com.getdieter.api.v1.Card?,
    onDismiss: () -> Unit,
    submit: (GitOperationForm) -> Unit,
) {
    var form by remember(kind) { mutableStateOf(OperationForm.initial(kind, card)) }
    val copy = GitOperations.copy(kind)
    Sheet(
        GitOperations.title(kind),
        onDismiss,
        confirm =
            ChromeAction(
                "git-confirm",
                GitOperations.title(kind),
                gitGlyph(kind),
                enabled = form.ready,
            ) {
                submit(
                    GitOperationForm(
                        kind = kind,
                        subject = form.subject,
                        body = form.body,
                        stage_all = form.stageAll,
                        validate = form.validate,
                        fetch = form.fetch,
                        draft = form.draft,
                        push = form.push,
                        strategy = form.strategy,
                        force_with_lease = form.forceWithLease,
                        expected_remote_sha = form.expectedRemoteSha,
                        target_card_id = form.targetCardId,
                    )
                )
            },
    ) {
        GitOperations.description(kind, card?.workspace?.base_branch.orEmpty())?.let {
            Text(
                it,
                Modifier.padding(horizontal = ScreenMargin + 4.dp, vertical = 6.dp),
                style = type.subheadline,
                color = palette.secondaryLabel,
            )
        }
        val fields = GitOperations.fields(kind).filter(form::shows)
        val texts = fields.filter {
            it in
                listOf(
                    GitFormField.SUBJECT,
                    GitFormField.BODY,
                    GitFormField.EXPECTED_REMOTE_SHA,
                    GitFormField.TARGET_CARD_ID,
                )
        }
        val toggles = fields.filter { it !in texts && it != GitFormField.STRATEGY }
        if (texts.isNotEmpty())
            FormColumn {
                texts.forEach { field ->
                    when (field) {
                        GitFormField.SUBJECT ->
                            MobileTextField(
                                form.subject,
                                { form = form.copy(subject = it) },
                                Modifier.fillMaxWidth(),
                                label = { Text(copy.subject) },
                                placeholder = { Text(copy.subject) },
                                singleLine = true,
                            )
                        GitFormField.BODY ->
                            MobileTextField(
                                form.body,
                                { form = form.copy(body = it) },
                                Modifier.fillMaxWidth(),
                                label = { Text(copy.body) },
                                placeholder = { Text(copy.body) },
                                minLines = 3,
                            )
                        GitFormField.EXPECTED_REMOTE_SHA ->
                            MobileTextField(
                                form.expectedRemoteSha,
                                { form = form.copy(expectedRemoteSha = it) },
                                Modifier.fillMaxWidth(),
                                label = { Text(copy.expectedRemoteSha) },
                                placeholder = { Text(copy.expectedRemoteSha) },
                                supportingText = { Text(copy.expectedRemoteShaHelp) },
                                singleLine = true,
                            )
                        else ->
                            MobileTextField(
                                form.targetCardId,
                                { form = form.copy(targetCardId = it) },
                                Modifier.fillMaxWidth(),
                                label = { Text(copy.targetCardId) },
                                placeholder = { Text(copy.targetCardId) },
                                singleLine = true,
                            )
                    }
                }
            }
        if (GitFormField.STRATEGY in fields)
            Group(listOf(0)) { _, position ->
                val strategies = GitOperations.strategies(kind)
                PickerRow(
                    "Strategy",
                    strategies.firstOrNull { it.first == form.strategy }?.second ?: form.strategy,
                    strategies,
                    form.strategy,
                    true,
                    position,
                ) {
                    form = form.copy(strategy = it)
                }
            }
        if (toggles.isNotEmpty()) {
            SectionHeader("Options")
            Group(toggles) { field, position ->
                val (title, checked) =
                    when (field) {
                        GitFormField.STAGE_ALL -> copy.stageAll to form.stageAll
                        GitFormField.FETCH -> copy.fetch to form.fetch
                        GitFormField.VALIDATE -> copy.validate to form.validate
                        GitFormField.DRAFT -> copy.draft to form.draft
                        GitFormField.PUSH -> copy.push to form.push
                        else -> copy.forceWithLease to form.forceWithLease
                    }
                ListRow(
                    title,
                    position = position,
                    trailing = {
                        DSwitch(
                            checked,
                            { on ->
                                form =
                                    when (field) {
                                        GitFormField.STAGE_ALL -> form.copy(stageAll = on)
                                        GitFormField.FETCH -> form.copy(fetch = on)
                                        GitFormField.VALIDATE -> form.copy(validate = on)
                                        GitFormField.DRAFT -> form.copy(draft = on)
                                        GitFormField.PUSH -> form.copy(push = on)
                                        else -> form.copy(forceWithLease = on)
                                    }
                            },
                        )
                    },
                )
            }
        }
        GitOperations.notice(kind)?.let {
            Banner(
                it.title,
                it.detail,
                Modifier.padding(horizontal = ScreenMargin, vertical = 12.dp),
                tone = Tone.WARNING,
            )
        }
    }
}
