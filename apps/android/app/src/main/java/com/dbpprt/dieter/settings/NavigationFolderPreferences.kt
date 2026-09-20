package com.dbpprt.dieter.settings

import java.text.Normalizer
import java.util.Locale
import java.util.UUID

/** Portable layout only: IDs refer to resources; membership never changes their owner. */
data class NavigationFolder(
    val id: String = UUID.randomUUID().toString(),
    val name: String,
    val itemIDs: List<String> = emptyList(),
    val isExpanded: Boolean = true,
)

enum class NavigationFolderScope { PROJECTS, CHATS }

/** Matches the Mac folder model, including ordered membership and independent scopes. */
@ConsistentCopyVisibility
data class NavigationFolderPreferences private constructor(val folders: List<NavigationFolder>) {
    constructor() : this(emptyList())

    fun folderContaining(itemID: String): NavigationFolder? = folders.firstOrNull { itemID in it.itemIDs }

    fun unfiledIDs(availableIDs: List<String>): List<String> {
        val assigned = folders.flatMap { it.itemIDs }.toSet()
        return availableIDs.filterNot { it in assigned }
    }

    fun nameIsAvailable(name: String, excludingID: String? = null): Boolean =
        name.isNotBlank() && name.trim().toByteArray(Charsets.UTF_8).size <= 256 &&
            folders.none { it.id != excludingID && foldedName(it.name) == foldedName(name) }

    fun adding(name: String, id: String = UUID.randomUUID().toString()): NavigationFolderPreferences =
        if (!nameIsAvailable(name) || id.isBlank() || folders.any { it.id == id }) this
        else from(folders + NavigationFolder(id = id, name = name.trim()))

    fun renaming(id: String, name: String): NavigationFolderPreferences =
        if (!nameIsAvailable(name, excludingID = id)) this
        else from(folders.map { if (it.id == id) it.copy(name = name.trim()) else it })

    // Removing a folder only returns its members to the unfiled list.
    fun deleting(id: String) = from(folders.filterNot { it.id == id })

    fun toggling(id: String) = from(folders.map { if (it.id == id) it.copy(isExpanded = !it.isExpanded) else it })

    fun moving(itemID: String, folderID: String?): NavigationFolderPreferences {
        if (itemID.isBlank() || folderID != null && folders.none { it.id == folderID }) return this
        return from(folders.map { folder ->
            folder.copy(itemIDs = folder.itemIDs.filterNot { it == itemID } +
                if (folder.id == folderID) listOf(itemID) else emptyList())
        })
    }

    fun reordering(itemID: String, targetID: String): NavigationFolderPreferences {
        val folder = folderContaining(itemID) ?: return this
        val source = folder.itemIDs.indexOf(itemID)
        val target = folder.itemIDs.indexOf(targetID)
        if (target < 0 || source == target) return this
        val order = folder.itemIDs.toMutableList().apply { removeAt(source); add(target, itemID) }
        return from(folders.map { if (it.id == folder.id) it.copy(itemIDs = order) else it })
    }

    companion object {
        fun from(folders: List<NavigationFolder>): NavigationFolderPreferences {
            val folderIDs = hashSetOf<String>()
            val assignedIDs = hashSetOf<String>()
            return NavigationFolderPreferences(folders.mapNotNull { folder ->
                if (folder.id.isBlank() || folder.name.isBlank() || !folderIDs.add(folder.id)) null
                else folder.copy(name = folder.name.trim(), itemIDs = folder.itemIDs.filter {
                    it.isNotBlank() && assignedIDs.add(it)
                })
            })
        }

        private fun foldedName(name: String) = Normalizer.normalize(name.trim(), Normalizer.Form.NFD)
            .replace(Regex("\\p{M}+"), "").lowercase(Locale.ROOT)
    }
}
