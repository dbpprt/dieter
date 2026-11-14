package com.getdieter.core.folders

import java.io.File

internal actual fun folderVectors(): String =
    File(
            checkNotNull(System.getProperty("dieter.repository")) {
                "run through ./gradlew jvmTest"
            },
            "tests/fixtures/folders/vectors.json",
        )
        .readText()
