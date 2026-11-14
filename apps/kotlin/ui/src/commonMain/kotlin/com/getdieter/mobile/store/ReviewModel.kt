package com.getdieter.mobile.store

import com.getdieter.client.v1.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/** A conversation's changes and processes, and a project checkout's uncommitted changes. */
class ReviewModel
internal constructor(
    private val context: StoreContext,
    private val workspace: StateFlow<WorkspaceSlice>,
    private val defaults: StateFlow<CreationSlice>,
    private val available: (daemonId: String) -> Boolean,
) {
    val slice = MutableStateFlow(ReviewSlice())
    val projectChanges = MutableStateFlow(ProjectChangesSlice())
    val processes = MutableStateFlow(ProcessesSlice())

    internal fun subscribe() {
        context.observeAlways(Slice.SLICE_PROJECT_CHANGES, MobileStore.PROJECT_CHANGES_SCOPE) {
            it.project_changes?.let { value ->
                projectChanges.value =
                    if (value.diff_unchanged)
                        value.copy(display_rows = projectChanges.value.display_rows)
                    else value
            }
        }
        context.observeAlways(Slice.SLICE_PROCESSES, MobileStore.PROCESSES_SCOPE) {
            it.processes?.let { value -> processes.value = value }
        }
        context.observeAlways(Slice.SLICE_REVIEW, MobileStore.REVIEW_SCOPE) {
            it.review?.let { value ->
                slice.value =
                    if (value.diff_unchanged) value.copy(display_rows = slice.value.display_rows)
                    else value
            }
        }
    }

    /** Binds project changes to [projectId]'s checkout [checkoutId] or its default checkout. */
    fun bindProjectChanges(projectId: String, checkoutId: String = "") {
        val project = workspace.value.projects.firstOrNull { it.id == projectId } ?: return
        val checkout =
            project.toolCheckout(
                checkoutId,
                defaults.value.checkouts[project.id].orEmpty(),
                available,
            ) ?: return
        context.action {
            context.core.dispatch(
                Command(
                    project_changes =
                        ProjectChangesCommand(
                            scope = MobileStore.PROJECT_CHANGES_SCOPE,
                            bind =
                                ProjectChangesTarget(
                                    project.id,
                                    checkout.id,
                                    checkout.daemon_id,
                                    true,
                                ),
                        )
                )
            )
            context.core.dispatch(
                Command(
                    project_changes =
                        ProjectChangesCommand(
                            scope = MobileStore.PROJECT_CHANGES_SCOPE,
                            active = Toggle(true),
                        )
                )
            )
        }
    }

    internal fun bindCard(cardId: String, daemonId: String) =
        context.command(
            Command(
                review =
                    ReviewCommand(
                        scope = MobileStore.REVIEW_SCOPE,
                        bind = ReviewTarget(card_id = cardId, daemon_id = daemonId),
                    )
            )
        )

    internal fun bindProcesses(daemonId: String, projectId: String, cardId: String) =
        context.command(
            Command(
                processes =
                    ProcessesCommand(
                        scope = MobileStore.PROCESSES_SCOPE,
                        bind = ProcessesTarget(daemonId, projectId, cardId, true),
                    )
            )
        )
}
