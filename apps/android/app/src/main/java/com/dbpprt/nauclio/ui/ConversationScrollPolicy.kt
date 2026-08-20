package com.dbpprt.nauclio.ui

internal fun shouldFollowConversationUpdate(
    explicitOpenScroll: Boolean,
    initialScrollComplete: Boolean,
    followingLatest: Boolean,
): Boolean = explicitOpenScroll || !initialScrollComplete || followingLatest
