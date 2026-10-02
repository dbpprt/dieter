package com.dbpprt.dieter.core.navigation

import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.api.v1.Project
import com.dbpprt.dieter.core.runtime.CoreException
import com.dbpprt.dieter.core.runtime.FailureKind
import kotlin.uuid.Uuid
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonPrimitive
import okio.ByteString
import okio.ByteString.Companion.encodeUtf8

/** Folder scopes share one key layout: `<scope>-folder.*` and `<scope>-item.*`. */
enum class FolderScope(val key: String) { PROJECTS("projects"), CHATS("chats") }

data class NavigationFolder(val id: String, val name: String, val itemIds: List<String>, val expanded: Boolean = true)

/** The sidebar's projects as it shows them: available projects only, in the shared order, grouped by folder. */
data class SidebarProjects(
    /** Every available project in the shared order. */
    val order: List<String> = emptyList(),
    /** Project folders in order, each with its available projects in the folder's order. */
    val folders: List<NavigationFolder> = emptyList(),
    /** Available projects in no folder, in the shared order. */
    val unfiled: List<String> = emptyList(),
    /** Pinned available projects, in pin order. */
    val pinned: List<String> = emptyList(),
    /** Available projects whose boards the sidebar shows. */
    val expanded: List<String> = emptyList(),
) {
    companion object {
        /**
         * The sidebar's [available] projects under a saved layout: [savedOrder]
         * first, then the rest in their given order; [folders] and
         * [savedPinned] keep only available projects; [expanded] lists the
         * projects whose boards show.
         */
        fun of(available: List<String>, savedOrder: List<String>, folders: List<NavigationFolder>, savedPinned: List<String>, expanded: Collection<String>): SidebarProjects {
            val order = NavigationLayout.inOrder(available.distinct(), savedOrder)
            val present = order.toHashSet()
            val open = expanded.toHashSet()
            return SidebarProjects(
                order = order,
                folders = folders.map { folder -> folder.copy(itemIds = folder.itemIds.filter(present::contains)) },
                unfiled = NavigationLayout.unfiled(folders, order),
                pinned = savedPinned.filter(present::contains),
                expanded = order.filter(open::contains),
            )
        }
    }
}

/** What the chats list reads from the navigation layout: saved orders, chat folders, and each project section's disclosure. */
data class ChatLayout(
    val projectOrder: List<String> = emptyList(),
    val pinnedOrder: List<String> = emptyList(),
    val folders: List<NavigationFolder> = emptyList(),
    /** Projects showing all their chats instead of the preview. */
    val showAll: Set<String> = emptySet(),
    /** Projects whose chat section is collapsed. */
    val collapsed: Set<String> = emptySet(),
)

// Key prefixes in the `navigation` namespace.
private const val PROJECTS_ORDER = "projects-order"
private const val PROJECTS_PINNED = "projects-pinned"
private const val PINNED_ORDER = "pinned-order"
private const val PROJECTS_DISCLOSURE = "projects-disclosure"
private const val CHATS_SECTION = "chats-section"
private const val CHATS_DISCLOSURE = "chats-disclosure"

/**
 * The account-wide navigation layout, derived from the `navigation` namespace:
 * folders, project and pinned orders, disclosure flags, and lane sort
 * direction. Unknown item IDs are kept (their machine may be offline); views
 * filter them against what is available.
 */
class NavigationLayout(private val values: Map<String, ByteString>) {
    fun ids(prefix: String, field: String): List<String> {
        val head = "$prefix."
        val tail = ".$field"
        return values.keys.filter { it.startsWith(head) && it.endsWith(tail) && it.length > head.length + tail.length }
            .map { it.substring(head.length, it.length - tail.length) }
            .sorted()
    }

    /** IDs under `<prefix>.<id>.position` with [parent], by rank then ID. */
    fun ordered(prefix: String, parent: String = ""): List<String> {
        val head = "$prefix."
        return values.mapNotNull { (key, value) ->
            if (!key.startsWith(head) || !key.endsWith(".position")) return@mapNotNull null
            val id = key.substring(head.length, key.length - ".position".length).ifEmpty { return@mapNotNull null }
            val position = SharedKv.decodePosition(value)?.takeIf { it.parent == parent } ?: return@mapNotNull null
            id to position.rank
        }.sortedWith(compareBy({ it.second }, { it.first })).map { it.first }
    }

    private fun bool(key: String): Boolean? = values[key]?.let { runCatching { Json.parseToJsonElement(it.utf8()).jsonPrimitive.booleanOrNull }.getOrNull() }

    private fun string(key: String): String? = values[key]?.let { runCatching { Json.parseToJsonElement(it.utf8()).jsonPrimitive.contentOrNull }.getOrNull() }

    fun folders(scope: FolderScope): List<NavigationFolder> {
        val prefix = "${scope.key}-folder"
        val named = ids(prefix, "name").toSet()
        val order = ordered(prefix).filter { it in named }
        val ids = order + named.filterNot { it in order }.sorted()
        val claimed = HashSet<String>()
        return ids.mapNotNull { id ->
            val name = string("$prefix.$id.name")?.trim()?.ifEmpty { null } ?: return@mapNotNull null
            // An item belongs to one folder; the first listing wins.
            val items = ordered("${scope.key}-item", parent = id).filter { it.isNotBlank() && claimed.add(it) }
            NavigationFolder(id, name, items, expanded = bool("$prefix.$id.expanded") != false)
        }.distinctBy { it.id }
    }

    fun unfiled(scope: FolderScope, available: List<String>): List<String> = unfiled(folders(scope), available)

    /** [projects] in the shared order. */
    fun orderedProjects(projects: List<Project>): List<Project> {
        val byId = projects.associateBy { it.id }
        return projectOrder(projects.map { it.id }).mapNotNull(byId::get)
    }

    /** [available] projects in the shared order; unordered ones follow in their given order. */
    fun projectOrder(available: List<String>): List<String> = inOrder(available, ordered(PROJECTS_ORDER))

    /** Pinned [available] projects, in pin order. */
    fun pinnedProjects(available: List<String>): List<String> = available.toSet().let { present -> ordered(PROJECTS_PINNED).filter(present::contains) }

    /** The sidebar's [available] projects: the shared order, folders and their members, unfiled, pinned, and expanded ones. */
    fun sidebarProjects(available: List<String>): SidebarProjects =
        SidebarProjects.of(available, ordered(PROJECTS_ORDER), folders(FolderScope.PROJECTS), ordered(PROJECTS_PINNED), expandedProjects())

    /** What the chats list reads: the saved orders, chat folders, and section disclosures. */
    fun chatLayout(): ChatLayout = ChatLayout(
        projectOrder = savedProjectOrder(), pinnedOrder = savedPinnedChatOrder(), folders = folders(FolderScope.CHATS),
        showAll = projectsShowingAllChats().toSet(), collapsed = collapsedChatSections().toSet(),
    )

    /** Pinned chats ([pinnedChats]) under the saved pinned order. */
    fun pinnedChats(chats: List<Card>): List<Card> = pinnedChats(chats, ordered(PINNED_ORDER))

    /** A project's chat section is collapsed only by an explicit `false`. */
    fun chatSectionCollapsed(projectId: String): Boolean = bool("$CHATS_SECTION.$projectId.expanded") == false

    /** Show all of a project's chats instead of the preview. */
    fun chatsShowAll(projectId: String): Boolean = bool("$CHATS_DISCLOSURE.$projectId.expanded") == true

    /** Lanes show newest first unless set to ascending. */
    fun laneDescending(boardId: String, laneId: String): Boolean = string("lane.$boardId.$laneId.sort") != "ascending"

    /** IDs whose `<prefix>.<id>.expanded` flag is [value]. */
    fun flagged(prefix: String, value: Boolean): List<String> = ids(prefix, "expanded").filter { bool("$prefix.$it.expanded") == value }

    /** The saved orders, unfiltered: IDs whose item may be offline are kept. */
    fun savedProjectOrder(): List<String> = ordered(PROJECTS_ORDER)

    fun savedPinnedProjects(): List<String> = ordered(PROJECTS_PINNED)

    fun savedPinnedChatOrder(): List<String> = ordered(PINNED_ORDER)

    /** Projects shown expanded, chat sections collapsed, and projects listing all their chats. */
    fun expandedProjects(): List<String> = flagged(PROJECTS_DISCLOSURE, true)

    fun collapsedChatSections(): List<String> = flagged(CHATS_SECTION, false)

    fun projectsShowingAllChats(): List<String> = flagged(CHATS_DISCLOSURE, true)


    companion object {
        const val PROJECT_CHAT_PREVIEW = 5
        const val MAX_FOLDER_NAME_BYTES = 256

        /** [available] in [saved] order; the rest follow in their given order. */
        fun inOrder(available: List<String>, saved: List<String>): List<String> {
            val present = available.toSet()
            val preferred = saved.distinct().filter { it in present }
            val placed = preferred.toSet()
            return preferred + available.filterNot { it in placed }
        }

        /**
         * Pinned [chats]: [savedOrder] first, then newly pinned chats by
         * position, then ID. Membership comes from the cards themselves.
         */
        fun pinnedChats(chats: List<Card>, savedOrder: List<String>): List<Card> {
            val pinned = chats.filter { it.pinned }
            if (pinned.size <= 1 || savedOrder.isEmpty()) return pinned
            val byId = pinned.associateBy { it.id }
            val preferred = savedOrder.distinct().mapNotNull(byId::get)
            val placed = preferred.mapTo(HashSet()) { it.id }
            return preferred + pinned.filterNot { it.id in placed }.sortedWith(compareBy<Card>({ it.position }, { it.id }))
        }

        /** [available] items that no folder holds, in their given order. */
        fun unfiled(folders: List<NavigationFolder>, available: List<String>): List<String> {
            val assigned = folders.flatMapTo(HashSet()) { it.itemIds }
            return available.filterNot { it in assigned }
        }

        /** [order] with [id] moved to [targetId]'s position; unchanged when either is missing. */
        fun moveTo(order: List<String>, id: String, targetId: String): List<String> {
            val source = order.indexOf(id)
            val target = order.indexOf(targetId)
            if (source < 0 || target < 0 || source == target) return order
            return order.toMutableList().apply {
                removeAt(source)
                add(target, id)
            }
        }

        /** [order] with [id] moved right before [beforeId], or to the end when null; unchanged when [id] or a given [beforeId] is missing. */
        fun moveBefore(order: List<String>, id: String, beforeId: String?): List<String> {
            if (id == beforeId || id !in order) return order
            val rest = order.filterNot { it == id }
            val index = if (beforeId == null) rest.size else rest.indexOf(beforeId).takeIf { it >= 0 } ?: return order
            return rest.toMutableList().apply { add(index, id) }
        }
    }
}

/** Builds navigation edits; every method queues one atomic batch on [kv]. */
class NavigationEditor(private val kv: SharedKv) {
    private val layout get() = NavigationLayout(kv.values.value)

    fun setProjectOrder(next: List<String>) = kv.enqueue(order(layout.ordered(PROJECTS_ORDER), next, PROJECTS_ORDER, ""))

    fun setPinnedProjects(next: List<String>) {
        val current = layout.ordered(PROJECTS_PINNED)
        val removed = current.filterNot { it in next }
        val intents = removed.map { delete("$PROJECTS_PINNED.$it.position") } + order(current.filter { it in next }, next, PROJECTS_PINNED, "")
        kv.enqueue(intents)
    }

    /** Pins [projectId] after the pinned projects, or unpins it; a project already so stays where it is. */
    fun pinProject(projectId: String, pinned: Boolean) {
        if (projectId.isBlank()) return
        val current = layout.ordered(PROJECTS_PINNED)
        if ((projectId in current) == pinned) return
        setPinnedProjects(if (pinned) current + projectId else current - projectId)
    }

    fun setPinnedChatOrder(next: List<String>) = kv.enqueue(order(layout.ordered(PINNED_ORDER), next, PINNED_ORDER, ""))

    /**
     * Drops [projectId] on [targetProjectId]: within one folder, or among the
     * unfiled projects in their [displayed] order. Moving across folders is
     * [moveToFolder]'s job; nothing changes then.
     */
    fun moveProject(projectId: String, targetProjectId: String, displayed: List<String>) {
        val folders = layout.folders(FolderScope.PROJECTS)
        val source = folders.firstOrNull { projectId in it.itemIds }
        val target = folders.firstOrNull { targetProjectId in it.itemIds }
        if (source?.id != target?.id) return
        if (source != null) {
            reorderFolderItems(FolderScope.PROJECTS, source.id, NavigationLayout.moveTo(source.itemIds, projectId, targetProjectId))
            return
        }
        val next = NavigationLayout.moveTo(displayed, projectId, targetProjectId)
        if (next != displayed) setProjectOrder(next)
    }

    /**
     * Moves [projectId] right before [beforeProjectId], or to the end when
     * null, as the sidebar shows the [available] projects: within the
     * project's folder, or among the projects in no folder; a target in
     * another group changes nothing. With [ungrouped], it moves in the shared
     * order of every available project, as lists that ignore folders (the
     * chats list) show them.
     */
    fun moveProjectBefore(projectId: String, beforeProjectId: String?, available: List<String>, ungrouped: Boolean = false) {
        if (projectId.isBlank() || projectId == beforeProjectId) return
        if (!ungrouped) {
            val folders = layout.folders(FolderScope.PROJECTS)
            val source = folders.firstOrNull { projectId in it.itemIds }
            if (source != null) {
                if (beforeProjectId != null && beforeProjectId !in source.itemIds) return
                val next = NavigationLayout.moveBefore(source.itemIds, projectId, beforeProjectId)
                if (next != source.itemIds) reorderFolderItems(FolderScope.PROJECTS, source.id, next)
                return
            }
            if (beforeProjectId != null && folders.any { beforeProjectId in it.itemIds }) return
        }
        val displayed = layout.projectOrder(available.distinct())
        val next = NavigationLayout.moveBefore(displayed, projectId, beforeProjectId)
        if (next != displayed) setProjectOrder(next)
    }

    /** Drops pinned [chatId] on [targetChatId] within the [displayed] pinned order. */
    fun movePinnedChat(chatId: String, targetChatId: String, displayed: List<String>) {
        val next = NavigationLayout.moveTo(displayed, chatId, targetChatId)
        if (next != displayed) setPinnedChatOrder(next)
    }

    /** Records the current pinned order once, so later pins append instead of reshuffling. */
    fun initializePinnedChatOrder(chats: List<Card>) {
        if (layout.ordered(PINNED_ORDER).isNotEmpty()) return
        val pinned = chats.filter { it.pinned }.sortedByDescending { it.last_activity_at.ifEmpty { it.updated_at } }
        if (pinned.isNotEmpty()) setPinnedChatOrder(pinned.map { it.id })
    }

    fun setProjectExpanded(projectId: String, expanded: Boolean) = kv.enqueue(listOf(put("$PROJECTS_DISCLOSURE.$projectId.expanded", JsonPrimitive(expanded))))

    fun setChatSectionCollapsed(projectId: String, collapsed: Boolean) = kv.enqueue(listOf(put("$CHATS_SECTION.$projectId.expanded", JsonPrimitive(!collapsed))))

    fun setChatsShowAll(projectId: String, showAll: Boolean) = kv.enqueue(listOf(put("$CHATS_DISCLOSURE.$projectId.expanded", JsonPrimitive(showAll))))

    fun setLaneDescending(boardId: String, laneId: String, descending: Boolean) =
        kv.enqueue(listOf(put("lane.$boardId.$laneId.sort", JsonPrimitive(if (descending) "descending" else "ascending"))))

    fun createFolder(scope: FolderScope, name: String): String {
        val folders = layout.folders(scope)
        val trimmed = validName(name, folders, exceptId = null)
        val id = Uuid.random().toString()
        editFolders(scope, folders, folders + NavigationFolder(id, trimmed, emptyList()))
        return id
    }

    fun renameFolder(scope: FolderScope, id: String, name: String) {
        val folders = layout.folders(scope)
        val trimmed = validName(name, folders, exceptId = id)
        editFolders(scope, folders, folders.map { if (it.id == id) it.copy(name = trimmed) else it })
    }

    /** Deletes the folder only; its items become unfiled. */
    fun deleteFolder(scope: FolderScope, id: String) {
        val folders = layout.folders(scope)
        editFolders(scope, folders, folders.filterNot { it.id == id })
    }

    fun setFolderExpanded(scope: FolderScope, id: String, expanded: Boolean) {
        val folders = layout.folders(scope)
        editFolders(scope, folders, folders.map { if (it.id == id) it.copy(expanded = expanded) else it })
    }

    /** Moves an item into [folderId] (appended), or out of every folder when null. */
    fun moveToFolder(scope: FolderScope, itemId: String, folderId: String?) {
        if (itemId.isBlank()) return
        val folders = layout.folders(scope)
        if (folderId != null && folders.none { it.id == folderId }) return
        val next = folders.map { folder ->
            val without = folder.itemIds - itemId
            folder.copy(itemIds = if (folder.id == folderId) without + itemId else without)
        }
        editFolders(scope, folders, next)
    }

    /**
     * Replaces [scope]'s folders with [next]: names, order, expansion, and
     * members. An item belongs to one folder; the first listing wins. Only
     * the differences are recorded.
     */
    fun setFolders(scope: FolderScope, next: List<NavigationFolder>) {
        val claimed = HashSet<String>()
        val trimmed = next.map { folder -> folder.copy(name = folder.name.trim(), itemIds = folder.itemIds.filter { it.isNotBlank() && claimed.add(it) }) }
        trimmed.forEachIndexed { index, folder ->
            nameProblem(folder.name, trimmed.take(index))?.let { throw CoreException(FailureKind.PERMANENT, it) }
        }
        editFolders(scope, layout.folders(scope), trimmed)
    }

    fun reorderFolderItems(scope: FolderScope, folderId: String, next: List<String>) {
        val folders = layout.folders(scope)
        editFolders(scope, folders, folders.map { if (it.id == folderId) it.copy(itemIds = next.filter { id -> id in it.itemIds }) else it })
    }

    /** Emits the minimal edits that turn [old] into [new]. */
    private fun editFolders(scope: FolderScope, old: List<NavigationFolder>, new: List<NavigationFolder>) {
        val folderPrefix = "${scope.key}-folder"
        val itemPrefix = "${scope.key}-item"
        val before = old.associateBy { it.id }
        val intents = mutableListOf<KvIntent>()
        for (folder in old) if (new.none { it.id == folder.id }) intents += delete("$folderPrefix.${folder.id}.name")
        for (folder in new) {
            val previous = before[folder.id]
            if (previous == null || previous.name != folder.name) {
                // An offline rename must not resurrect a folder deleted elsewhere.
                intents += put("$folderPrefix.${folder.id}.name", JsonPrimitive(folder.name), requiresExisting = previous != null)
            }
            if (previous == null || previous.expanded != folder.expanded) intents += put("$folderPrefix.${folder.id}.expanded", JsonPrimitive(folder.expanded))
            intents += order(previous?.itemIds.orEmpty(), folder.itemIds, itemPrefix, folder.id)
        }
        val filed = new.flatMapTo(HashSet()) { it.itemIds }
        for (folder in old) {
            if (new.none { it.id == folder.id }) continue
            for (item in folder.itemIds) if (item !in filed) intents += move("$itemPrefix.$item.position", "")
        }
        intents += order(old.map { it.id }.filter { id -> new.any { it.id == id } }, new.map { it.id }, folderPrefix, "")
        kv.enqueue(intents)
    }

    private fun validName(name: String, folders: List<NavigationFolder>, exceptId: String?): String {
        nameProblem(name, folders, exceptId)?.let { throw CoreException(FailureKind.PERMANENT, it) }
        return name.trim()
    }

    companion object {
        /** Why [name] cannot name a folder, or null: 1 to 256 bytes and unique among [folders] other than [exceptId]. */
        fun nameProblem(name: String, folders: List<NavigationFolder>, exceptId: String? = null): String? {
            val trimmed = name.trim()
            if (!nameFits(trimmed)) return "Folder names must be 1 to 256 bytes."
            if (!nameAvailable(trimmed, folders, exceptId)) return "A folder with this name already exists."
            return null
        }

        private fun nameFits(trimmed: String) = trimmed.isNotEmpty() && trimmed.encodeUtf8().size <= NavigationLayout.MAX_FOLDER_NAME_BYTES

        /** Whether [name] is a valid folder name no other folder (than [exceptId]) uses, ignoring case and accents. */
        fun nameAvailable(name: String, folders: List<NavigationFolder>, exceptId: String? = null): Boolean {
            val trimmed = name.trim()
            if (!nameFits(trimmed)) return false
            val folded = Folding.fold(trimmed)
            return folders.none { it.id != exceptId && Folding.fold(it.name) == folded }
        }

        /**
         * Moves that turn [old] into [next]: the longest run that kept its
         * relative order stays put, and every other item is placed after its
         * new predecessor. Delivery is in order, so earlier moves are already
         * in place when later ones anchor on them.
         */
        fun order(old: List<String>, next: List<String>, prefix: String, parent: String): List<KvIntent> {
            val index = old.withIndex().associate { it.value to it.index }
            val stable = longestIncreasing(next.map { index[it] ?: -1 }).map { next[it] }.toSet()
            return next.withIndex().filterNot { it.value in stable }.map { (position, id) ->
                val after = if (position > 0) "$prefix.${next[position - 1]}.position" else ""
                val before = next.drop(position + 1).firstOrNull { it in stable }?.let { "$prefix.$it.position" }.orEmpty()
                move("$prefix.$id.position", parent, after, before)
            }
        }

        /** Positions of one longest strictly increasing subsequence, ignoring negative values. */
        internal fun longestIncreasing(values: List<Int>): List<Int> {
            val tails = mutableListOf<Int>()
            val previous = IntArray(values.size) { -1 }
            for ((position, value) in values.withIndex()) {
                if (value < 0) continue
                var low = 0
                var high = tails.size
                while (low < high) {
                    val middle = (low + high) / 2
                    if (values[tails[middle]] < value) low = middle + 1 else high = middle
                }
                if (low > 0) previous[position] = tails[low - 1]
                if (low == tails.size) tails += position else tails[low] = position
            }
            val result = mutableListOf<Int>()
            var cursor = tails.lastOrNull() ?: return emptyList()
            while (cursor >= 0) {
                result += cursor
                cursor = previous[cursor]
            }
            return result.reversed()
        }

        private fun put(key: String, value: JsonPrimitive, requiresExisting: Boolean = false) =
            KvIntent(id = Uuid.random().toString(), key = key, put = KvPut(value_json = value.toString().encodeUtf8(), requires_existing = requiresExisting))

        private fun delete(key: String) = KvIntent(id = Uuid.random().toString(), key = key, delete = KvDelete())

        private fun move(key: String, parent: String, after: String = "", before: String = "") =
            KvIntent(id = Uuid.random().toString(), key = key, move = KvMove(parent = parent, after = after, before = before))
    }
}

/**
 * Case- and accent-insensitive comparison keys for names: the canonical
 * decomposition's base letter for Latin letters, as NFD plus mark stripping gives.
 */
object Folding {
    private const val ACCENTED = "ÀÁÂÃÄÅÇÈÉÊËÌÍÎÏÑÒÓÔÕÖÙÚÛÜÝàáâãäåçèéêëìíîïñòóôõöùúûüýÿĀāĂăĄąĆćĈĉĊċČčĎďĒēĔĕĖėĘęĚěĜĝĞğĠġĢģĤĥĨĩĪīĬĭĮįİĴĵĶķĹĺĻļĽľŃńŅņŇňŌōŎŏŐőŔŕŖŗŘřŚśŜŝŞşŠšŢţŤťŨũŪūŬŭŮůŰűŲųŴŵŶŷŸŹźŻżŽžƠơƯưǍǎǏǐǑǒǓǔǕǖǗǘǙǚǛǜǞǟǠǡǢǣǦǧǨǩǪǫǬǭǮǯǰǴǵǸǹǺǻǼǽǾǿȀȁȂȃȄȅȆȇȈȉȊȋȌȍȎȏȐȑȒȓȔȕȖȗȘșȚțȞȟȦȧȨȩȪȫȬȭȮȯȰȱȲȳḀḁḂḃḄḅḆḇḈḉḊḋḌḍḎḏḐḑḒḓḔḕḖḗḘḙḚḛḜḝḞḟḠḡḢḣḤḥḦḧḨḩḪḫḬḭḮḯḰḱḲḳḴḵḶḷḸḹḺḻḼḽḾḿṀṁṂṃṄṅṆṇṈṉṊṋṌṍṎṏṐṑṒṓṔṕṖṗṘṙṚṛṜṝṞṟṠṡṢṣṤṥṦṧṨṩṪṫṬṭṮṯṰṱṲṳṴṵṶṷṸṹṺṻṼṽṾṿẀẁẂẃẄẅẆẇẈẉẊẋẌẍẎẏẐẑẒẓẔẕẖẗẘẙẛẠạẢảẤấẦầẨẩẪẫẬậẮắẰằẲẳẴẵẶặẸẹẺẻẼẽẾếỀềỂểỄễỆệỈỉỊịỌọỎỏỐốỒồỔổỖỗỘộỚớỜờỞởỠỡỢợỤụỦủỨứỪừỬửỮữỰựỲỳỴỵỶỷỸỹ"
    private const val PLAIN = "AAAAAACEEEEIIIINOOOOOUUUUYaaaaaaceeeeiiiinooooouuuuyyAaAaAaCcCcCcCcDdEeEeEeEeEeGgGgGgGgHhIiIiIiIiIJjKkLlLlLlNnNnNnOoOoOoRrRrRrSsSsSsSsTtTtUuUuUuUuUuUuWwYyYZzZzZzOoUuAaIiOoUuUuUuUuUuAaAaÆæGgKkOoOoƷʒjGgNnAaÆæØøAaAaEeEeIiIiOoOoRrRrUuUuSsTtHhAaEeOoOoOoOoYyAaBbBbBbCcDdDdDdDdDdEeEeEeEeEeFfGgHhHhHhHhHhIiIiKkKkKkLlLlLlLlMmMmMmNnNnNnNnOoOoOoOoPpPpRrRrRrRrSsSsSsSsSsTtTtTtTtUuUuUuUuUuVvVvWwWwWwWwWwXxXxYyZzZzZzhtwyſAaAaAaAaAaAaAaAaAaAaAaAaEeEeEeEeEeEeEeEeIiIiOoOoOoOoOoOoOoOoOoOoOoOoUuUuUuUuUuUuUuYyYyYyYy"

    fun fold(value: String): String = buildString(value.length) {
        for (char in value) {
            val index = ACCENTED.indexOf(char)
            append(if (index >= 0) PLAIN[index] else char)
        }
    }.lowercase()
}
