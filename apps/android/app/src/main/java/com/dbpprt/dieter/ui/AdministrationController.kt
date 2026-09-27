package com.dbpprt.dieter.ui

import com.dbpprt.dieter.data.AdministrationClient
import com.dbpprt.dieter.v1.*
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope

data class AdministrationState(
    val settings: Settings? = null,
    val settingsOptions: SettingsOptions? = null,
    val archivedProjects: List<Project> = emptyList(),
    val archivedCards: List<Card> = emptyList(),
)

internal class AdministrationController(
    scope: CoroutineScope,
    binding: () -> Any?,
    private val route: suspend (String) -> AdministrationClient,
    private val publish: (AdministrationState) -> Unit,
    reportError: (Throwable) -> Unit,
) {
    var state = AdministrationState()
        private set
    private val requests = FeatureRequests(scope, binding) { _, error -> reportError(error) }

    fun reset() { requests.cancelAll(); state = AdministrationState(); publish(state) }
    fun cancel() = requests.cancelAll()
    fun load(project: String, board: String) = requests.launch("load") {
        val client = route(project)
        check()
        val snapshot = coroutineScope {
            val settings = async { client.settings() }
            val options = async { client.options() }
            val projects = async { client.archivedProjects().projectsList }
            val cards = async { if (board.isBlank()) emptyList() else client.archivedCards(board).cardsList }
            AdministrationState(settings.await(), options.await(), projects.await(), cards.await())
        }
        check()
        state = snapshot
        publish(state)
    }
    fun update(project: String, settings: Settings): Job {
        requests.cancel("load")
        return requests.launch("update") {
            val client = route(project)
            check()
            val updated = client.update(settings)
            check()
            state = state.copy(settings = updated)
            publish(state)
        }
    }
}
