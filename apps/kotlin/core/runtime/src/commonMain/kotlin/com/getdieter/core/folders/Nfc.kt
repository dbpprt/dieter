package com.getdieter.core.folders

/**
 * [value] in Unicode Normalization Form C: `java.text.Normalizer` on Android and the JVM,
 * `precomposedStringWithCanonicalMapping` on Apple platforms. Paths are NFC in every index, as the
 * Go rules require (`norm.NFC`).
 */
internal expect fun nfc(value: String): String
