package com.dbpprt.dieter.connection

import com.dbpprt.dieter.v1.Project
import com.dbpprt.dieter.v1.Board
import com.dbpprt.dieter.v1.Card

// These unions are a client cache of eventual replicas. Execution still uses
// immutable owner IDs; neither snapshot provenance nor list position is an owner.
// A refreshed observation replaces the cache even if its wall-clock timestamp
// is smaller: the peer store, not client clocks, resolves concurrent edits.
internal fun sharedProjects(values: List<Project>): List<Project> = values.groupBy { it.id }.map { (_, versions) ->
    val selected = versions.last()
    val checkouts = versions.flatMap { it.checkoutsList }.groupBy { it.id }.map { (_, copies) ->
        val checkout = copies.lastOrNull { it.detached } ?: copies.last()
        val local = copies.lastOrNull { it.path.isNotEmpty() }
        checkout.toBuilder().setPath(local?.path.orEmpty()).clearValidationCommands().addAllValidationCommands(local?.validationCommandsList.orEmpty()).build()
    }.sortedBy { it.id }
    selected.toBuilder().clearCheckouts().addAllCheckouts(checkouts).build()
}.sortedBy { it.name.lowercase() }

internal fun sharedBoards(values: List<Board>): List<Board> = values.groupBy { it.id }.values.map { it.last() }.sortedBy { it.id }
internal fun sharedItems(values: List<Card>): List<Card> = values.groupBy { it.id }.values.map { versions ->
    val accepted = versions.filter { it.ownerDaemonId.isNotEmpty() }
    if (accepted.isEmpty()) versions.last() else accepted.last()
}.sortedBy { it.id }
