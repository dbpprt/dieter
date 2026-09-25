package com.dbpprt.dieter.connection

import com.dbpprt.dieter.v1.Card

/** Join placement and runtime separately; transport order and wall clocks are not revisions. */
internal fun mergeCardState(incoming: Card, previous: Card?): Card {
    if (previous == null || previous.id != incoming.id) return incoming
    fun covers(a: Map<String, Long>, b: Map<String, Long>) =
        b.all { (actor, count) -> java.lang.Long.compareUnsigned(a[actor] ?: 0L, count) >= 0 }
    val oldFields = previous.stateFieldsList.associateBy { it.name }
    val newFields = incoming.stateFieldsList.associateBy { it.name }
    val fields = (oldFields.keys + newFields.keys).sorted().map { name ->
        val old = oldFields[name]
        val new = newFields[name]
        when {
            old == null -> requireNotNull(new)
            new == null -> old
            else -> {
                val all = old.versionsList + new.versionsList
                val versions = all.filterIndexed { i, version ->
                    all.withIndex().none { (j, other) ->
                        i != j && covers(other.clockMap, version.clockMap) &&
                            (!covers(version.clockMap, other.clockMap) || other.rank > version.rank ||
                                (other.rank == version.rank && j < i))
                    }
                }.sortedBy { it.rank }
                // The daemon also limits each causal register to 16 siblings.
                if (versions.size > 16) return@map old
                val revision = when (versions) {
                    new.versionsList -> new.revision
                    old.versionsList -> old.revision
                    else -> "unobserved-join" // Not a daemon CAS receipt.
                }
                new.toBuilder().clearVersions().addAllVersions(versions).setRevision(revision).build()
            }
        }
    }
    val result = incoming.toBuilder().clearStateFields().addAllStateFields(fields)
    for (field in fields) {
        if (field.versionsList.any { it.deleted }) continue
        val value = field.versionsList.maxByOrNull { it.rank }?.value ?: continue
        when (field.name) {
            "placement" -> result.setBoardId(value.boardId).setLane(value.lane).setOrderKey(value.orderKey)
                .setPhaseChangedAt(value.phaseChangedAt).setPlacementRevision(field.revision)
            "summary" -> result.setRuntime(value.runtime).setRuntimeUpdatedAt(value.runtimeUpdatedAt)
                .setLastActivityAt(value.lastActivityAt).setProvider(value.provider).setModel(value.model)
                .setEffort(value.effort).setInitialPromptSentAt(value.initialPromptSentAt)
                .setResponseSeq(value.responseSeq).setResponseMessageId(value.responseMessageId)
                .setSeenResponseSeq(value.seenResponseSeq).setMergedIntoCardId(value.mergedIntoCardId)
        }
    }
    return result.build()
}
