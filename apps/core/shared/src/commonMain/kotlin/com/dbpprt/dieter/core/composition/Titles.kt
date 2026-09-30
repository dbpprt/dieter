package com.dbpprt.dieter.core.composition

import com.dbpprt.dieter.api.v1.MessagePart

/** Placeholder titles shown until the daemon generates one. */
object Titles {
    /** A task's first line; long lines are cut at a word boundary after 40 characters, at most 80. */
    fun task(prompt: String): String? {
        val line = prompt.lineSequence().map { it.trim() }.firstOrNull { it.isNotEmpty() } ?: return null
        if (line.length <= 80) return line
        val cut = line.lastIndexOf(' ', 80).takeIf { it >= 40 } ?: 80
        return line.take(cut).trimEnd()
    }

    /** A chat's first non-blank line, else its first attachment's name, else "New chat"; at most 72 characters. */
    fun chat(prompt: String, attachments: List<MessagePart> = emptyList()): String {
        val line = prompt.lineSequence().map { it.trim() }.firstOrNull { it.isNotEmpty() }
            ?: attachments.firstOrNull { it.filename.isNotBlank() }?.filename
            ?: return "New chat"
        return if (line.length > 72) line.take(69) + "…" else line
    }

    /** The title a created task shows: explicit, else from the prompt, else an attachment, else "New task". */
    fun creation(title: String, prompt: String, attachments: List<MessagePart>): String =
        title.trim().ifEmpty { null } ?: task(prompt) ?: attachments.firstOrNull { it.filename.isNotBlank() }?.filename ?: "New task"
}
