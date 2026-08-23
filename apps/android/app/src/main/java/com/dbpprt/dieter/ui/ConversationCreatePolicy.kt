package com.dbpprt.dieter.ui

internal fun canCreateConversation(
    projectId: String,
    provider: String,
    model: String,
    prompt: String,
    chat: Boolean,
    title: String,
    hasAttachments: Boolean = false,
): Boolean = projectId.isNotBlank() &&
    provider.isNotBlank() &&
    model.isNotBlank() &&
    (prompt.isNotBlank() || hasAttachments) &&
    (chat || title.isNotBlank())

internal fun shouldOpenCreatedConversation(chat: Boolean, lane: String): Boolean =
    chat || lane != "todo"

internal fun shouldDeferConversationStart(chat: Boolean, lane: String): Boolean =
    !chat && lane != "running"
