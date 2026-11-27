package com.getdieter.core.client

import com.getdieter.client.v1.MemoryCommand
import com.getdieter.client.v1.Result
import com.getdieter.core.CoreRuntime
import com.getdieter.core.memory.MemoryDreams
import com.getdieter.core.runtime.CoreException
import com.getdieter.core.runtime.FailureKind

/**
 * Runs an agent memory command ([com.getdieter.core.memory.MemoryCalls]): the account's memory
 * setting, a project's memory state and a dream started now, a conversation's switch, and a dream
 * conversation's review. A conversation's memory and its dream show in its ConversationState.
 */
internal suspend fun CoreRuntime.executeMemory(command: MemoryCommand): Result {
    command.settings?.let {
        val machine = memory.settingsMachine(it.daemon_id)
        // The settings form's pickers show this machine's catalog.
        metadata.ensure(machine)
        return Result(memory_settings = memory.settings(machine))
    }
    command.update_settings?.let { update ->
        val settings = update.settings ?: invalid("Choose the memory settings.")
        return Result(memory_settings = memory.updateSettings(update.daemon_id, settings))
    }
    command.set_enabled?.let {
        return Result(card = memory.setEnabled(it.card_id, it.enabled))
    }
    command.status?.let {
        return Result(memory_status = memory.status(it.project_id))
    }
    command.start_dream?.let {
        return Result(memory_dream = MemoryDreams.state(memory.startDream(it.project_id)))
    }
    command.dream?.let {
        val dream =
            memory.dream(it.card_id)
                ?: throw CoreException(
                    FailureKind.PERMANENT,
                    "The conversation's machine has no record of this dream.",
                )
        return Result(memory_dream = MemoryDreams.state(dream))
    }
    command.apply_dream?.let {
        return Result(memory_dream = MemoryDreams.state(memory.apply(it.card_id)))
    }
    command.discard_dream?.let {
        return Result(memory_dream = MemoryDreams.state(memory.discard(it.card_id)))
    }
    command.undo_dream?.let {
        return Result(memory_dream = MemoryDreams.state(memory.undo(it.card_id)))
    }
    invalid("Choose what to do with agent memory.")
}
