package com.dbpprt.dieter.core.sync

import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.api.v1.CardStateField
import com.dbpprt.dieter.api.v1.CardStateVersion

// Matches the peer-store frontier bound.
private const val MAX_CAUSAL_SIBLINGS = 16

// A client-side join is not a daemon CAS receipt; a move must wait for a
// replica that has observed the complete frontier.
internal const val UNOBSERVED_JOIN = "unobserved-join"

/**
 * Joins two observations of one card, e.g. a conversation read from its
 * owner and the account view: placement and runtime registers separately,
 * since transport order and wall clocks are not revisions.
 */
fun mergeCardState(incoming: Card, previous: Card?): Card {
    if (previous == null || previous.id != incoming.id) return incoming
    val oldFields = previous.state_fields.associateBy { it.name }
    val newFields = incoming.state_fields.associateBy { it.name }
    val fields = (oldFields.keys + newFields.keys).sorted().map { name ->
        val old = oldFields[name]
        val new = newFields[name]
        when {
            old == null -> requireNotNull(new)
            new == null -> old
            else -> join(old, new)
        }
    }
    var result = incoming.copy(state_fields = fields)
    for (field in fields) {
        if (field.versions.any { it.deleted }) continue
        val selected = field.versions.maxByOrNull { it.rank } ?: continue
        // protobuf-lite returned a default message for an unset value; keep that.
        val value = selected.value_ ?: Card()
        result = when (field.name) {
            "placement" -> result.copy(
                board_id = value.board_id, lane = value.lane, order_key = value.order_key,
                phase_changed_at = value.phase_changed_at, placement_revision = field.revision,
            )
            "summary" -> result.copy(
                runtime = value.runtime, runtime_updated_at = value.runtime_updated_at,
                last_activity_at = value.last_activity_at, provider = value.provider, model = value.model,
                effort = value.effort, initial_prompt_sent_at = value.initial_prompt_sent_at,
                response_seq = value.response_seq, response_message_id = value.response_message_id,
                seen_response_seq = value.seen_response_seq, merged_into_card_id = value.merged_into_card_id,
            )
            else -> result
        }
    }
    return result
}

private fun join(old: CardStateField, new: CardStateField): CardStateField {
    val all: List<CardStateVersion> = old.versions + new.versions
    val versions = all.filterIndexed { i, version ->
        all.withIndex().none { (j, other) ->
            i != j && Registers.covers(other.clock, version.clock) &&
                (!Registers.covers(version.clock, other.clock) || other.rank > version.rank || (other.rank == version.rank && j < i))
        }
    }.sortedBy { it.rank }
    // Keep the last complete view until a daemon supplies a resolved register.
    if (versions.size > MAX_CAUSAL_SIBLINGS) return old
    val revision = when (versions) {
        new.versions -> new.revision
        old.versions -> old.revision
        else -> UNOBSERVED_JOIN
    }
    return new.copy(versions = versions, revision = revision)
}
