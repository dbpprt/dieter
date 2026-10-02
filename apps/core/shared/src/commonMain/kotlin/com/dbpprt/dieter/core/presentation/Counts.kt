package com.dbpprt.dieter.core.presentation

/** Counted nouns as every client writes them: "1 chat", "3 chats", "2 files conflict". */
object Counts {
    /** "[count] [noun]", or [plural] (by default [noun] plus "s") unless [count] is 1. */
    fun of(count: Int, noun: String, plural: String = "${noun}s"): String = "$count ${word(count, noun, plural)}"

    /** [noun] when [count] is 1, else [plural]: "needs" / "need", "conflicts" / "conflict". */
    fun word(count: Int, noun: String, plural: String = "${noun}s"): String = if (count == 1) noun else plural
}
