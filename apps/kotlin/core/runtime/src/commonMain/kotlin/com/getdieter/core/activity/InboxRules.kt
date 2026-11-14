package com.getdieter.core.activity

import com.getdieter.api.v1.Card
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull

/**
 * One saved Inbox rule. It names projects and labels and either shows or hides the cards that match
 * them. [matchAll] makes a card match only when it is in one of the [projects] *and* carries one of
 * the [labels]; otherwise either is enough. A condition left empty is not part of the match, and a
 * rule with no conditions never matches.
 */
data class InboxRule(
    val id: String,
    val name: String = "",
    /** A hiding rule drops matching cards; a showing rule keeps only matching cards. */
    val hide: Boolean = true,
    val matchAll: Boolean = false,
    val projects: Set<String> = emptySet(),
    val labels: Set<String> = emptySet(),
    val enabled: Boolean = true,
    /** Epoch millis; lists rules in the order they were made. */
    val created: Long = 0,
) {
    /** A rule with a condition can match; others are kept but have no effect. */
    val active: Boolean
        get() = enabled && (projects.isNotEmpty() || labels.isNotEmpty())

    fun matches(card: Card): Boolean {
        val inProject = projects.isNotEmpty() && card.project_id in projects
        val labelled = labels.isNotEmpty() && card.label_ids.any { it in labels }
        return when {
            projects.isEmpty() && labels.isEmpty() -> false
            projects.isEmpty() -> labelled
            labels.isEmpty() -> inProject
            matchAll -> inProject && labelled
            else -> inProject || labelled
        }
    }

    /** The KV value of this rule: a JSON object. */
    fun toJson(): JsonObject =
        JsonObject(
            mapOf(
                "name" to JsonPrimitive(name.trim().take(MAX_NAME)),
                "effect" to JsonPrimitive(if (hide) "hide" else "show"),
                "match" to JsonPrimitive(if (matchAll) "all" else "any"),
                "projects" to JsonArray(projects.sorted().take(MAX_IDS).map(::JsonPrimitive)),
                "labels" to JsonArray(labels.sorted().take(MAX_IDS).map(::JsonPrimitive)),
                "enabled" to JsonPrimitive(enabled),
                "created" to JsonPrimitive(created),
            )
        )

    companion object {
        const val MAX_NAME = 120
        const val MAX_IDS = 64

        /** The rule stored for [id] in [json], or null when it is not a rule. */
        fun parse(id: String, json: String): InboxRule? = runCatching {
            val value = Json.parseToJsonElement(json).jsonObject
            fun strings(key: String) =
                value[key]?.jsonArray?.mapNotNull { it.jsonPrimitive.contentOrNull }.orEmpty()
            InboxRule(
                id = id,
                name = value["name"]?.jsonPrimitive?.contentOrNull.orEmpty(),
                hide = value["effect"]?.jsonPrimitive?.contentOrNull != "show",
                matchAll = value["match"]?.jsonPrimitive?.contentOrNull == "all",
                projects = strings("projects").toSet(),
                labels = strings("labels").toSet(),
                enabled = value["enabled"]?.jsonPrimitive?.booleanOrNull != false,
                created = value["created"]?.jsonPrimitive?.longOrNull ?: 0,
            )
        }
            .getOrNull()
    }
}

/**
 * Which cards the Inbox shows under its [rules]. A card matching any active hiding rule is hidden.
 * While any active showing rule exists, a card must also match at least one of them.
 */
class InboxFilter(rules: List<InboxRule>) {
    private val hiding = rules.filter { it.active && it.hide }
    private val showing = rules.filter { it.active && !it.hide }

    val isEmpty: Boolean
        get() = hiding.isEmpty() && showing.isEmpty()

    fun shows(card: Card): Boolean =
        hiding.none { it.matches(card) } && (showing.isEmpty() || showing.any { it.matches(card) })

    /** [items] the rules show, and how many they hide. */
    fun apply(items: List<ActivityItem>): FilteredActivity {
        if (isEmpty) return FilteredActivity(items, 0)
        val visible = items.filter { shows(it.card) }
        return FilteredActivity(visible, items.size - visible.size)
    }
}

object InboxRuleText {
    private const val LISTED = 3

    /**
     * What a rule does in words: "Hide project dieter, wallfly or label urgent", "Show only label
     * urgent and project dieter". Long lists end in "+N".
     */
    fun summary(
        hide: Boolean,
        matchAll: Boolean,
        projectNames: List<String>,
        labelNames: List<String>,
    ): String {
        fun list(names: List<String>) =
            names.take(LISTED).joinToString(", ") +
                if (names.size > LISTED) " +${names.size - LISTED}" else ""
        val parts =
            listOfNotNull(
                projectNames.takeIf { it.isNotEmpty() }?.let { "project ${list(it)}" },
                labelNames.takeIf { it.isNotEmpty() }?.let { "label ${list(it)}" },
            )
        val verb = if (hide) "Hide" else "Show only"
        return if (parts.isEmpty()) "$verb nothing yet"
        else "$verb ${parts.joinToString(if (matchAll) " and " else " or ")}"
    }
}

/** The conversations the Inbox shows and how many its rules [hidden] left out. */
data class FilteredActivity(val items: List<ActivityItem>, val hidden: Int)
