package com.dbpprt.dieter.settings

import org.json.JSONObject
import org.json.JSONTokener

/** The portable record schema is identical in Swift, Kotlin and daemon tests. */
object SharedNavigation {
    fun ids(values: Map<String,String>, prefix: String, field: String): List<String> = values.keys
        .filter { it.startsWith("$prefix.") && it.endsWith(".$field") }
        .map { it.removePrefix("$prefix.").removeSuffix(".$field") }.sorted()
    fun ordered(values: Map<String,String>, prefix: String, parent: String = ""): List<String> =
        ids(values, prefix, "position").mapNotNull { id ->
            runCatching { JSONObject(values.getValue("$prefix.$id.position")) }.getOrNull()
                ?.takeIf { it.optString("parent") == parent }?.let { id to it.optString("rank") }
        }.sortedWith(compareBy<Pair<String,String>> { it.second }.thenBy { it.first }).map { it.first }
    fun flags(values: Map<String,String>, prefix: String, inverted: Boolean = false): Set<String> =
        ids(values,prefix,"expanded").filter { values["$prefix.$it.expanded"] == (!inverted).toString() }.toSet()
    fun folders(values: Map<String,String>, scope: String): NavigationFolderPreferences {
        val prefix = "$scope-folder"; val names = ids(values,prefix,"name"); val order = ordered(values,prefix)
        return NavigationFolderPreferences.from((order.filter { it in names } + names.filterNot { it in order }).map { id ->
            NavigationFolder(id, JSONTokener(values.getValue("$prefix.$id.name")).nextValue() as String,
                ordered(values,"$scope-item",id), values["$prefix.$id.expanded"] != "false")
        })
    }
    fun order(kv: SharedKV, old: List<String>, next: List<String>, prefix: String, parent: String = "") {
        // Keep the longest increasing subsequence of old indices. Only inserted
        // or moved items receive new positions; other devices' edits stay intact.
        val indices = old.withIndex().associate { it.value to it.index }
        val tails = mutableListOf<Int>(); val previous = IntArray(next.size) { -1 }
        next.forEachIndexed { index,id ->
            val rank = indices[id] ?: return@forEachIndexed
            var lo = 0; var hi = tails.size
            while (lo < hi) { val mid = (lo+hi)/2; if (indices.getValue(next[tails[mid]]) < rank) lo = mid+1 else hi = mid }
            if (lo > 0) previous[index] = tails[lo-1]
            if (lo == tails.size) tails.add(index) else tails[lo] = index
        }
        val stable = mutableSetOf<String>(); var cursor = tails.lastOrNull() ?: -1
        while (cursor >= 0) { stable.add(next[cursor]); cursor = previous[cursor] }
        next.forEachIndexed { index,id -> if (id !in stable) {
            val after = if (index>0) "$prefix.${next[index-1]}.position" else ""
            val before = next.drop(index+1).firstOrNull { it in stable }?.let { "$prefix.$it.position" }.orEmpty()
            kv.move("$prefix.$id.position",parent,after,before)
        } }
    }
}
