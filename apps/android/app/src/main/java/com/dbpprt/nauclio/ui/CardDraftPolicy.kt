package com.dbpprt.nauclio.ui

import com.dbpprt.nauclio.v1.Card

internal fun Card.unsentTaskText(): String? = initialPrompt.trim().takeIf {
    scope == "board" && initialPromptSentAt.isBlank() && it.isNotBlank()
}

internal fun Card.canEditInitialTask(): Boolean = unsentTaskText() != null
