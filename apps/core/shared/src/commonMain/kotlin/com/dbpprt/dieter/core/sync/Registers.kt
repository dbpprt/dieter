package com.dbpprt.dieter.core.sync

import com.dbpprt.dieter.api.v1.PeerVersion
import okio.ByteString

/**
 * The peer store's causal register rules (internal/peerstore), applied to the
 * records machines stream. A version's rank identifies its content, so equal
 * ranks are the same version wherever it came from.
 */
object Registers {
    /** Whether clock [a] has seen everything clock [b] has. */
    fun covers(a: Map<String, Long>, b: Map<String, Long>): Boolean =
        b.all { (actor, count) -> (a[actor] ?: 0L).toULong() >= count.toULong() }

    /**
     * The join of several machines' copies of one register: every version
     * that no other strictly succeeds, once, ordered by rank. Commutative,
     * associative and idempotent, so arrival order never matters.
     */
    fun join(copies: Iterable<List<PeerVersion>>): List<PeerVersion> {
        val byRank = LinkedHashMap<String, PeerVersion>()
        for (versions in copies) for (version in versions) byRank.getOrPut(version.rank) { version }
        val all = byRank.values.toList()
        return all.filter { version ->
            all.none { other -> other !== version && covers(other.clock, version.clock) && !covers(version.clock, other.clock) }
        }.sortedBy { it.rank }
    }

    /** `peerstore.Selected`: absent when any version is a tombstone, else the highest rank's value. */
    fun selected(versions: List<PeerVersion>): ByteString? {
        if (versions.isEmpty() || versions.any { it.deleted }) return null
        return versions.maxBy { it.rank }.value_json
    }

    /** `peerstore.SelectedKV`: a tombstone wins, else the highest rank. */
    fun selectedKv(versions: List<PeerVersion>): PeerVersion? = versions.firstOrNull { it.deleted } ?: versions.maxByOrNull { it.rank }

    /** Whether two copies hold exactly the same versions. */
    fun same(a: List<PeerVersion>, b: List<PeerVersion>): Boolean =
        a.size == b.size && a.mapTo(HashSet()) { it.rank } == b.mapTo(HashSet()) { it.rank }
}
