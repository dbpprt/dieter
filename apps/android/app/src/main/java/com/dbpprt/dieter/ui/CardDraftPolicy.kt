package com.dbpprt.dieter.ui

import com.dbpprt.dieter.v1.Card

internal fun Card.unsentTaskText(): String? = initialPrompt.trim().takeIf {
    scope == "board" && initialPromptSentAt.isBlank() && it.isNotBlank()
}

internal fun Card.canEditInitialTask(): Boolean = unsentTaskText() != null
