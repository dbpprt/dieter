package com.dbpprt.dieter.settings

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow

/** Projection and semantic edits over the account KV store. */
class NavigationFolderStore(private val shared: SharedKV) {
    private val _layouts = MutableStateFlow(NavigationFolderScope.entries.associateWith { NavigationFolderPreferences() })
    val layouts = _layouts.asStateFlow()
    fun project(values: Map<String,String>) {
        _layouts.value = NavigationFolderScope.entries.associateWith { SharedNavigation.folders(values, it.name.lowercase()) }
    }
    fun update(scope: NavigationFolderScope, transform: (NavigationFolderPreferences) -> NavigationFolderPreferences) = shared.edit { values ->
        val current = SharedNavigation.folders(values, scope.name.lowercase())
        val updated = NavigationFolderPreferences.from(transform(current).folders)
        if (current == updated) return@edit
        val name = scope.name.lowercase(); val prefix = "$name-folder"
        current.folders.filterNot { old -> updated.folders.any { it.id == old.id } }.forEach {
            delete("$prefix.${it.id}.name")
        }
        updated.folders.forEach { folder ->
            val previous = current.folders.firstOrNull { it.id == folder.id }
            if (previous?.name != folder.name) put("$prefix.${folder.id}.name", folder.name, previous != null)
            if (previous?.isExpanded != folder.isExpanded) put("$prefix.${folder.id}.expanded", folder.isExpanded)
            SharedNavigation.order(this, previous?.itemIDs.orEmpty(), folder.itemIDs, "$name-item", folder.id)
        }
        val members = updated.folders.flatMap { it.itemIDs }.toSet()
        current.folders.filter { old -> updated.folders.any { it.id == old.id } }.flatMap { it.itemIDs }
            .filterNot { it in members }.forEach { move("$name-item.$it.position") }
        SharedNavigation.order(this, current.folders.map { it.id }, updated.folders.map { it.id }, prefix)
    }

    fun create(scope: NavigationFolderScope, name: String, itemID: String? = null) {
        update(scope) { current ->
            val next = current.adding(name)
            if (next == current || itemID == null) next else next.moving(itemID, next.folders.last().id)
        }
    }

}
