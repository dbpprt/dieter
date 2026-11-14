package com.getdieter.core.folders

import com.getdieter.api.v1.FolderEntry
import com.getdieter.api.v1.FolderEntryKind

/** Bounds of entries and folders (`internal/folders/entry.go`). */
object FolderBounds {
    const val MAX_PATH_BYTES = 4096
    const val MAX_COMPONENT_BYTES = 255
    const val MAX_FILE_SIZE = 64L shl 30
    const val MAX_NAME_BYTES = 64
    /** Entries per folder on a phone. */
    const val MAX_PHONE_ENTRIES = 25_000
    /** The transfer chunk size. */
    const val CHUNK_SIZE = 1 shl 20
    /** Payload-only partial files beside a destination start with this. */
    const val TEMPORARY_PREFIX = ".dieter-transfer-"
    /** Index pages a client asks for. */
    const val INDEX_PAGE = 512
    /** Conflict copies one file keeps. */
    const val MAX_CONFLICT_COPIES = 5
    /** Errors and unsyncable paths a member keeps. */
    const val MAX_PROBLEMS = 100
}

/** Paths and names: validation, normalization and platform limits. */
object FolderNames {
    /** A path component that never syncs: Git metadata and transfer partials. */
    fun protected(component: String): Boolean =
        component == ".git" || component.startsWith(FolderBounds.TEMPORARY_PREFIX)

    /** [path] in NFC: how a member names a path it found on disk. */
    fun normalize(path: String): String = nfc(path)

    /**
     * Why [path] is not a relative, clean, NFC path within bounds without protected components;
     * null when it is valid.
     */
    fun pathProblem(path: String): String? {
        if (
            path.isEmpty() ||
                path == "." ||
                utf8Length(path) > FolderBounds.MAX_PATH_BYTES ||
                !validUtf16(path) ||
                path.any { it == '\\' || it == '\u0000' } ||
                path.startsWith("/")
        )
            return "invalid folder path"
        if (nfc(path) != path) return "folder path must be NFC"
        for (part in path.split('/')) {
            if (
                part.isEmpty() ||
                    part == "." ||
                    part == ".." ||
                    utf8Length(part) > FolderBounds.MAX_COMPONENT_BYTES
            )
                return "invalid folder path component"
            if (part.any { it.code < 0x20 || it.code == 0x7f })
                return "folder path contains a control character"
            if (protected(part)) return "protected folder path"
        }
        return null
    }

    fun validPath(path: String): Boolean = pathProblem(path) == null

    /** Why [entry], received from another member, is invalid; null when it is valid. */
    fun entryProblem(entry: FolderEntry): String? {
        pathProblem(entry.path)?.let {
            return it
        }
        Versions.problem(entry.version)?.let {
            return it
        }
        if (entry.version.isEmpty()) return "an entry needs a version"
        if (
            utf8Length(entry.author_id) > 128 ||
                utf8Length(entry.author_name) > FolderBounds.MAX_NAME_BYTES ||
                !validUtf16(entry.author_name)
        )
            return "invalid entry author"
        return when (entry.kind) {
            FolderEntryKind.FOLDER_ENTRY_KIND_FILE ->
                if (
                    entry.size < 0 ||
                        entry.size > FolderBounds.MAX_FILE_SIZE ||
                        !validDigest(entry.sha256)
                )
                    "a file entry needs a size and SHA-256"
                else null
            FolderEntryKind.FOLDER_ENTRY_KIND_DIRECTORY,
            FolderEntryKind.FOLDER_ENTRY_KIND_DELETED ->
                if (entry.size != 0L || entry.sha256.isNotEmpty() || entry.executable)
                    "only files have content"
                else null
            else -> "invalid entry kind"
        }
    }

    /** Paths that collide on a case-insensitive file system share this key. */
    fun foldKey(path: String): String {
        val normalized = nfc(path)
        val out = StringBuilder(normalized.length)
        for (char in normalized) out.append(if (char.isSurrogate()) char else char.lowercaseChar())
        return out.toString()
    }

    /** Every component of [path] can be stored on FAT or exFAT (Android shared storage). */
    fun portable(path: String): Boolean =
        path.split('/').none { part ->
            part.any { it in "\\:*?\"<>|" } || part.endsWith(".") || part.endsWith(" ")
        }

    /** The number of components of [path]. */
    fun depth(path: String): Int = path.count { it == '/' } + 1

    /** The parent directory of [path]; empty at the root. */
    fun parent(path: String): String = path.substringBeforeLast('/', "")

    /** The last component of [path]. */
    fun name(path: String): String = path.substringAfterLast('/')

    /**
     * The name a file another app shared gets: its last component in NFC without control
     * characters, characters FAT cannot store, a protected prefix or trailing dots and spaces,
     * within the component bound; "Shared file" when nothing is left.
     */
    fun sharedName(name: String): String {
        var clean =
            nfc(name.substringAfterLast('/').substringAfterLast('\\'))
                .filter { it.code >= 0x20 && it.code != 0x7f && it !in "\\:*?\"<>|" }
                .trim()
                .trimEnd('.', ' ')
        while (clean.startsWith(FolderBounds.TEMPORARY_PREFIX)) clean =
            clean.removePrefix(FolderBounds.TEMPORARY_PREFIX)
        if (clean == ".git" || clean == "." || clean == "..") clean = ""
        while (utf8Length(clean) > FolderBounds.MAX_COMPONENT_BYTES - 8) clean = clean.dropLast(1)
        return clean.ifEmpty { "Shared file" }
    }

    /** [name] for the [attempt]th try: "Report.pdf", then "Report (2).pdf", "Report (3).pdf"… */
    fun variant(name: String, attempt: Int): String {
        if (attempt <= 0) return name
        val dot = name.lastIndexOf('.').takeIf { it > 0 } ?: name.length
        return "${name.substring(0, dot)} (${attempt + 1})${name.substring(dot)}"
    }

    /** [path]'s ancestors, shallow first. */
    fun ancestors(path: String): List<String> {
        val parts = path.split('/')
        return (1 until parts.size).map { parts.subList(0, it).joinToString("/") }
    }

    internal fun validDigest(value: String): Boolean =
        value.length == 64 && value.all { it in '0'..'9' || it in 'a'..'f' }

    /** Bytes of [value] in UTF-8. */
    fun utf8Length(value: String): Int {
        var bytes = 0
        var index = 0
        while (index < value.length) {
            val char = value[index]
            bytes +=
                when {
                    char.code < 0x80 -> 1
                    char.code < 0x800 -> 2
                    char.isHighSurrogate() &&
                        index + 1 < value.length &&
                        value[index + 1].isLowSurrogate() -> {
                        index++
                        4
                    }
                    else -> 3
                }
            index++
        }
        return bytes
    }

    /** [value] has no unpaired surrogate, so it is valid UTF-8 once encoded. */
    fun validUtf16(value: String): Boolean {
        var index = 0
        while (index < value.length) {
            val char = value[index]
            if (char.isHighSurrogate()) {
                if (index + 1 >= value.length || !value[index + 1].isLowSurrogate()) return false
                index += 2
                continue
            }
            if (char.isLowSurrogate()) return false
            index++
        }
        return true
    }

    /** [value]'s code points; an unpaired surrogate stands for itself. */
    internal fun codePoints(value: String): IntArray {
        val out = IntArray(value.length)
        var count = 0
        var index = 0
        while (index < value.length) {
            val char = value[index]
            if (
                char.isHighSurrogate() &&
                    index + 1 < value.length &&
                    value[index + 1].isLowSurrogate()
            ) {
                out[count++] =
                    0x10000 + ((char.code - 0xD800) shl 10) + (value[index + 1].code - 0xDC00)
                index += 2
            } else {
                out[count++] = char.code
                index++
            }
        }
        return out.copyOf(count)
    }

    /** Orders strings by their UTF-8 bytes, as Go's string comparison does. */
    fun compareUtf8(a: String, b: String): Int {
        val left = codePoints(a)
        val right = codePoints(b)
        val shared = minOf(left.size, right.size)
        for (index in 0 until shared) {
            if (left[index] != right[index]) return left[index].compareTo(right[index])
        }
        return left.size.compareTo(right.size)
    }
}
