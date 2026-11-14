package com.getdieter.core.folders

import com.getdieter.api.v1.FolderEntry
import com.getdieter.api.v1.FolderEntryKind
import com.getdieter.api.v1.FolderMode

/** What a member does with a remote entry. */
enum class FolderAction {
    /** Leaves the local entry as it is. */
    NONE,
    /**
     * Makes the local copy match [FolderDecision.result] (download, mkdir or delete) and records
     * it. With [FolderDecision.conflictCopy] set, the local content moves there first: it lost.
     */
    APPLY,
    /** Records [FolderDecision.result], whose content the member already has. */
    MERGE,
    /** A send-only member does not apply a newer remote entry. */
    OUT_OF_SYNC,
}

/** The outcome of reconciling a local entry with a remote one. */
data class FolderDecision(
    val action: FolderAction,
    /** The entry to record for [FolderAction.APPLY] and [FolderAction.MERGE]. */
    val result: FolderEntry? = null,
    /** Concurrent versions with different content. */
    val conflict: Boolean = false,
    /** Where this member keeps its losing local content. */
    val conflictCopy: String = "",
)

/** The reconciliation rules (`internal/folders/reconcile.go`), shared through golden vectors. */
object FolderReconcile {
    private val FILE = FolderEntryKind.FOLDER_ENTRY_KIND_FILE
    private val DIRECTORY = FolderEntryKind.FOLDER_ENTRY_KIND_DIRECTORY
    private val DELETED = FolderEntryKind.FOLDER_ENTRY_KIND_DELETED

    /** Equal kind and, for files, equal size, SHA-256 and executable bit. */
    fun sameContent(a: FolderEntry, b: FolderEntry): Boolean =
        a.kind == b.kind &&
            (a.kind != FILE ||
                a.size == b.size && a.sha256 == b.sha256 && a.executable == b.executable)

    /**
     * Whether [a] beats [b] when their versions are concurrent and their contents differ: the later
     * modification, then the higher author ID, then the higher SHA-256.
     */
    fun wins(a: FolderEntry, b: FolderEntry): Boolean {
        if (a.modified_nanos != b.modified_nanos) return a.modified_nanos > b.modified_nanos
        if (a.author_id != b.author_id) return FolderNames.compareUtf8(a.author_id, b.author_id) > 0
        return FolderNames.compareUtf8(a.sha256, b.sha256) > 0
    }

    /**
     * Reconciles a member's [local] entry (null when it has none) with a [remote] entry for the
     * same path, for a member in [mode]. When versions are concurrent and contents differ, only the
     * member whose local content loses acts; a modification beats a deletion and a directory beats
     * a file.
     */
    fun decide(local: FolderEntry?, remote: FolderEntry, mode: FolderMode): FolderDecision {
        val sendOnly = mode == FolderMode.FOLDER_MODE_SEND_ONLY
        if (local == null) {
            if (sendOnly) {
                return if (remote.kind == DELETED) FolderDecision(FolderAction.NONE)
                else FolderDecision(FolderAction.OUT_OF_SYNC)
            }
            return FolderDecision(FolderAction.APPLY, remote)
        }
        when (Versions.compare(local.version, remote.version)) {
            Ordering.EQUAL,
            Ordering.AFTER -> return FolderDecision(FolderAction.NONE)
            Ordering.BEFORE ->
                return if (sendOnly) FolderDecision(FolderAction.OUT_OF_SYNC)
                else FolderDecision(FolderAction.APPLY, remote)
            Ordering.CONCURRENT -> Unit
        }
        val merged = Versions.merge(local.version, remote.version)
        if (sameContent(local, remote)) {
            val chosen = if (wins(remote, local)) remote else local
            return FolderDecision(
                FolderAction.MERGE,
                chosen.copy(path = local.path, version = merged),
            )
        }
        if (sendOnly) return FolderDecision(FolderAction.OUT_OF_SYNC, conflict = true)
        val apply = FolderDecision(FolderAction.APPLY, remote.copy(version = merged), true)
        val none = FolderDecision(FolderAction.NONE, conflict = true)
        val copy = { conflictName(local.path, local.author_name, local.modified_nanos) }
        return when {
            local.kind == DELETED -> apply
            remote.kind == DELETED -> none
            local.kind == DIRECTORY && remote.kind == FILE -> none
            local.kind == FILE && remote.kind == DIRECTORY -> apply.copy(conflictCopy = copy())
            wins(local, remote) -> none
            else -> apply.copy(conflictCopy = copy())
        }
    }

    /**
     * Where the losing version of [path], made by [author] at [modifiedNanos], is kept: "stem
     * (conflict, AUTHOR, YYYY-MM-DD HH.MM.SS).ext". Every member derives the same name.
     */
    fun conflictName(path: String, author: String, modifiedNanos: Long): String {
        val slash = path.lastIndexOf('/')
        val dir = path.substring(0, slash + 1)
        val base = path.substring(slash + 1)
        val dot = base.lastIndexOf('.')
        var ext = if (dot >= 0) base.substring(dot) else ""
        if (ext == base || FolderNames.utf8Length(ext) > 16) ext = ""
        var stem = base.removeSuffix(ext)
        val suffix = " (conflict, ${sanitizeName(author)}, ${utcStamp(modifiedNanos)})$ext"
        val suffixBytes = FolderNames.utf8Length(suffix)
        while (
            stem.isNotEmpty() &&
                FolderNames.utf8Length(stem) + suffixBytes > FolderBounds.MAX_COMPONENT_BYTES
        ) {
            val cut =
                if (
                    stem.length >= 2 &&
                        stem[stem.length - 1].isLowSurrogate() &&
                        stem[stem.length - 2].isHighSurrogate()
                )
                    2
                else 1
            stem = stem.substring(0, stem.length - cut)
        }
        return dir + stem + suffix
    }

    /** Whether [path] names a conflict copy, and the file it conflicts with. */
    fun conflictOriginal(path: String): String? {
        val match = CONFLICT_COPY.find(FolderNames.name(path)) ?: return null
        val dir = path.substring(0, path.length - FolderNames.name(path).length)
        return dir + match.groupValues[1] + match.groupValues[3]
    }

    /** "Pixel 9 · 2025-11-13 14.00.00" of a conflict copy's name. */
    fun conflictDetail(path: String): String {
        val match = CONFLICT_COPY.find(FolderNames.name(path)) ?: return ""
        return match.groupValues[2].substringBeforeLast(", ") +
            " · " +
            match.groupValues[2].substringAfterLast(", ")
    }

    private val CONFLICT_COPY =
        Regex("""^(.*) \(conflict, (.*, \d{4}-\d{2}-\d{2} \d{2}\.\d{2}\.\d{2})\)(\.[^.]*)?$""")

    /**
     * A device name made safe inside a file name: separators and control characters become '-', and
     * it is at most 40 bytes. Empty is "unknown".
     */
    fun sanitizeName(name: String): String {
        val out = StringBuilder()
        var bytes = 0
        val trimmed = goTrimSpace(name)
        var index = 0
        while (index < trimmed.length) {
            val char = trimmed[index]
            var text: String
            if (
                char.isHighSurrogate() &&
                    index + 1 < trimmed.length &&
                    trimmed[index + 1].isLowSurrogate()
            ) {
                text = trimmed.substring(index, index + 2)
                index += 2
            } else {
                index++
                if (char.isSurrogate() || char.code == 0xFFFD) continue
                text = char.toString()
                if (char.code < 0x20 || char.code == 0x7f || char in "/\\:*?\"<>|") text = "-"
            }
            val size = FolderNames.utf8Length(text)
            if (bytes + size > 40) break
            out.append(text)
            bytes += size
        }
        val result = goTrimSpace(out.toString())
        return if (result.isEmpty()) "unknown" else nfc(result)
    }

    /** Go's `strings.TrimSpace`: Unicode White_Space at both ends. */
    private fun goTrimSpace(value: String): String = value.trim(::goSpace)

    private fun goSpace(char: Char): Boolean =
        when (char.code) {
            0x09,
            0x0A,
            0x0B,
            0x0C,
            0x0D,
            0x20,
            0x85,
            0xA0,
            0x1680,
            0x2028,
            0x2029,
            0x202F,
            0x205F,
            0x3000 -> true
            in 0x2000..0x200A -> true
            else -> false
        }

    /** "YYYY-MM-DD HH.MM.SS" in UTC of Unix nanoseconds. */
    internal fun utcStamp(nanos: Long): String {
        val seconds = nanos.floorDiv(1_000_000_000L)
        val days = seconds.floorDiv(86_400L)
        val secondOfDay = seconds.mod(86_400L)
        // Howard Hinnant's civil_from_days.
        val z = days + 719_468
        val era = z.floorDiv(146_097L)
        val doe = z - era * 146_097
        val yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
        val doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        val mp = (5 * doy + 2) / 153
        val day = doy - (153 * mp + 2) / 5 + 1
        val month = if (mp < 10) mp + 3 else mp - 9
        val year = yoe + era * 400 + if (month <= 2) 1 else 0
        fun two(value: Long) = value.toString().padStart(2, '0')
        return "${year.toString().padStart(4, '0')}-${two(month)}-${two(day)} " +
            "${two(secondOfDay / 3600)}.${two(secondOfDay / 60 % 60)}.${two(secondOfDay % 60)}"
    }
}
