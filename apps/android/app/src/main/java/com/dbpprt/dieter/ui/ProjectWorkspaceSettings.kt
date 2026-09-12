package com.dbpprt.dieter.ui

import com.dbpprt.dieter.v1.ValidationCommand
import java.util.UUID

internal data class ValidationCommandDraft(
    val id: String = UUID.randomUUID().toString(),
    val name: String = "",
    val executable: String = "",
    val arguments: String = "",
    val workingDirectory: String = "",
    val environment: String = "",
    val timeoutSeconds: String = "600",
) {
    constructor(value: ValidationCommand) : this(
        name = value.name,
        executable = value.executable,
        arguments = value.argumentsList.joinToString("\n"),
        workingDirectory = value.workingDirectory,
        environment = value.environmentMap.toSortedMap().entries.joinToString("\n") { (key, item) -> "$key=$item" },
        timeoutSeconds = value.timeoutSeconds.toString(),
    )

    fun validationError(): String? {
        if (executable.trim().isEmpty()) return "Every validation command needs an executable."
        val timeout = timeoutSeconds.toIntOrNull()
            ?: return "Validation timeout must be a number from 0 to 3600."
        if (timeout !in 0..3600) return "Validation timeout must be between 0 and 3600 seconds."
        val directory = workingDirectory.trim().replace('\\', '/')
        if (directory.startsWith('/') || directory.split('/').any { it == ".." }) {
            return "Validation working directories must stay inside the workspace."
        }
        environment.lineSequence().filter(String::isNotBlank).forEach { line ->
            val separator = line.indexOf('=')
            if (separator <= 0 || '\u0000' in line) return "Environment entries must use KEY=VALUE, one per line."
        }
        return null
    }

    fun value(): ValidationCommand {
        validationError()?.let { error(it) }
        val environmentValues = buildMap {
            environment.lineSequence().filter(String::isNotBlank).forEach { line ->
                val separator = line.indexOf('=')
                put(line.substring(0, separator), line.substring(separator + 1))
            }
        }
        return ValidationCommand.newBuilder()
            .setName(name.trim())
            .setExecutable(executable.trim())
            .addAllArguments(arguments.lineSequence().filter(String::isNotEmpty).toList())
            .setWorkingDirectory(workingDirectory.trim())
            .putAllEnvironment(environmentValues)
            .setTimeoutSeconds(timeoutSeconds.toInt())
            .build()
    }
}

internal fun validationCommandsError(values: List<ValidationCommandDraft>): String? =
    values.firstNotNullOfOrNull(ValidationCommandDraft::validationError)
