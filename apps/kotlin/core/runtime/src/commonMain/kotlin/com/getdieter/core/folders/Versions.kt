package com.getdieter.core.folders

import com.getdieter.api.v1.FolderCounter
import okio.ByteString.Companion.encodeUtf8

/**
 * A version vector: counters sorted by actor, without zero counters. The pure rules of synced
 * folders mirror the Go reference (`internal/folders`) and are checked against the same golden
 * vectors (`tests/fixtures/folders/vectors.json`).
 */
typealias Version = List<FolderCounter>

/** How two versions relate. */
enum class Ordering {
    EQUAL,
    /** The first version is dominated by the second. */
    BEFORE,
    /** The first version dominates the second. */
    AFTER,
    CONCURRENT,
}

object Versions {
    /** Bounds a version vector: the actors that ever changed one entry. */
    const val MAX_COUNTERS = 64

    /** The actor of a member ID: the first 8 bytes of its SHA-256 as 16 lowercase hex digits. */
    fun actorOf(memberId: String): String = memberId.encodeUtf8().sha256().hex().take(16)

    private fun validActor(actor: String): Boolean =
        actor.length == 16 && actor.all { it in '0'..'9' || it in 'a'..'f' }

    /** Why [version] is invalid: bounds, order and actor encoding; null when it is valid. */
    fun problem(version: Version): String? {
        if (version.size > MAX_COUNTERS) return "version has too many actors"
        for ((index, counter) in version.withIndex()) {
            if (!validActor(counter.actor) || counter.value_ == 0L) return "invalid version counter"
            if (index > 0 && version[index - 1].actor >= counter.actor)
                return "version counters must be sorted and unique"
        }
        return null
    }

    /** [actor]'s count. */
    fun get(version: Version, actor: String): Long {
        val index = version.binarySearch { it.actor.compareTo(actor) }
        return if (index >= 0) version[index].value_ else 0L
    }

    /** [version] with [actor]'s count incremented. */
    fun bump(version: Version, actor: String): Version {
        val index = version.binarySearch { it.actor.compareTo(actor) }
        val out = version.toMutableList()
        if (index >= 0) {
            out[index] = FolderCounter(actor, out[index].value_ + 1)
        } else {
            out.add(-index - 1, FolderCounter(actor, 1))
        }
        return out
    }

    /** The element-wise maximum of [a] and [b]. */
    fun merge(a: Version, b: Version): Version {
        val out = ArrayList<FolderCounter>(maxOf(a.size, b.size))
        var i = 0
        var j = 0
        while (i < a.size || j < b.size) {
            when {
                j == b.size || i < a.size && a[i].actor < b[j].actor -> out += a[i++]
                i == a.size || b[j].actor < a[i].actor -> out += b[j++]
                else -> {
                    val larger =
                        if (a[i].value_.toULong() >= b[j].value_.toULong()) a[i].value_
                        else b[j].value_
                    out += FolderCounter(a[i].actor, larger)
                    i++
                    j++
                }
            }
        }
        return out
    }

    /** How [a] relates to [b]. */
    fun compare(a: Version, b: Version): Ordering {
        var less = false
        var greater = false
        var i = 0
        var j = 0
        while (i < a.size || j < b.size) {
            when {
                j == b.size || i < a.size && a[i].actor < b[j].actor -> {
                    greater = true
                    i++
                }
                i == a.size || b[j].actor < a[i].actor -> {
                    less = true
                    j++
                }
                else -> {
                    val left = a[i].value_.toULong()
                    val right = b[j].value_.toULong()
                    if (left > right) greater = true else if (left < right) less = true
                    i++
                    j++
                }
            }
        }
        return when {
            less && greater -> Ordering.CONCURRENT
            less -> Ordering.BEFORE
            greater -> Ordering.AFTER
            else -> Ordering.EQUAL
        }
    }

    /** [a] dominates or equals [b]. */
    fun covers(a: Version, b: Version): Boolean =
        compare(a, b).let { it == Ordering.EQUAL || it == Ordering.AFTER }
}
