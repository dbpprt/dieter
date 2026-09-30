package com.dbpprt.dieter.ui

import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.core.workspace.WorkspaceBadge

/** Compact workspace identity and state shown directly on board cards (the core's rule). */
internal fun workspaceCardBadgeInfo(card: Card): WorkspaceBadge? = WorkspaceBadge.of(card)
