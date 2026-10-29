package com.getdieter.core.presentation

import java.io.File

private val corpus =
    File(
        checkNotNull(System.getProperty("dieter.repository")) { "run through ./gradlew jvmTest" },
        "tests/fixtures/markdown",
    )

internal actual fun markdownFixtureNames(): List<String> =
    corpus.list().orEmpty().filter { it.endsWith(".md") }.map { it.removeSuffix(".md") }.sorted()

internal actual fun markdownFixture(file: String): String = File(corpus, file).readText()
