package com.getdieter.core.navigation

import com.getdieter.api.v1.Card
import com.getdieter.api.v1.Project
import com.getdieter.core.runtime.Timestamps
import com.getdieter.core.v1.KvDelete
import com.getdieter.core.v1.KvIntent
import kotlin.time.Instant
import kotlin.uuid.Uuid

/** Automatic activity ordering and explicit replacement of the saved project order. */
object ProjectOrdering {
    private const val ORDER_PREFIX = "projects-order"

    /** Latest live conversation/card activity first, with stable fallbacks. */
    fun byActivity(projects: List<Project>, cards: List<Card>): List<String> {
        val latestByProject = HashMap<String, Instant>()
        for (card in cards) {
            if (card.archived || card.project_id.isBlank()) continue
            val activity =
                listOfNotNull(
                        Timestamps.parse(card.last_activity_at),
                        Timestamps.parse(card.runtime_updated_at),
                    )
                    .maxOrNull() ?: Timestamps.parse(card.updated_at) ?: continue
            val previous = latestByProject[card.project_id]
            if (previous == null || activity > previous) latestByProject[card.project_id] = activity
        }
        return projects
            .filterNot { it.archived }
            .sortedWith(
                compareByDescending<Project> {
                        latestByProject[it.id]
                            ?: Timestamps.parse(it.updated_at)
                            ?: Instant.DISTANT_PAST
                    }
                    .thenBy { it.name.lowercase() }
                    .thenBy { it.name }
                    .thenBy { it.id }
            )
            .map { it.id }
    }

    /** Replaces every saved position; an empty list restores automatic activity order. */
    fun replaceSavedOrder(kv: SharedKv, next: List<String>) {
        val current = NavigationLayout(kv.values.value).savedProjectOrder()
        val removed = current.filterNot { it in next }
        val kept = current.filter { it in next }
        val deletes = removed.map {
            KvIntent(
                id = Uuid.random().toString(),
                key = "$ORDER_PREFIX.$it.position",
                delete = KvDelete(),
            )
        }
        kv.enqueue(
            deletes +
                NavigationEditor.order(
                    kept,
                    next.distinct(),
                    ORDER_PREFIX,
                    "",
                )
        )
    }
}
