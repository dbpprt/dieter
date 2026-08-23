package com.dbpprt.dieter.ui

internal fun assignCardLabel(existingLabelIds: List<String>, labelId: String): List<String> =
    if (labelId.isBlank() || labelId in existingLabelIds) existingLabelIds else existingLabelIds + labelId
