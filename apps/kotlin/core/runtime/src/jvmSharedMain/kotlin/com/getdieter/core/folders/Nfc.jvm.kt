package com.getdieter.core.folders

import java.text.Normalizer

internal actual fun nfc(value: String): String =
    if (Normalizer.isNormalized(value, Normalizer.Form.NFC)) value
    else Normalizer.normalize(value, Normalizer.Form.NFC)
