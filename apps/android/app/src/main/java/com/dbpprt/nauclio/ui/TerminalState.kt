package com.dbpprt.nauclio.ui

private const val TERMINAL_CLIENT_BUFFER_LIMIT = 2 * 1_024 * 1_024
internal const val TERMINAL_INPUT_CHUNK_LIMIT = 64 * 1_024

data class TerminalScreenState(
    val data: ByteArray = byteArrayOf(),
    val revision: Long = 0,
    val resetRevision: Long = 0,
)

internal object TerminalScreenReducer {
    fun apply(
        current: TerminalScreenState,
        data: ByteArray,
        screenReset: Boolean,
        limit: Int = TERMINAL_CLIENT_BUFFER_LIMIT,
    ): TerminalScreenState {
        var resetRevision = current.resetRevision
        var next = if (screenReset) {
            resetRevision++
            data.copyOf()
        } else if (data.isEmpty()) {
            current.data
        } else {
            current.data + data
        }
        if (next.size > limit) {
            next = next.copyOfRange(next.size - limit, next.size)
            resetRevision++
        }
        return TerminalScreenState(
            data = next,
            revision = current.revision + 1,
            resetRevision = resetRevision,
        )
    }
}

internal fun terminalInputChunks(data: ByteArray, limit: Int = TERMINAL_INPUT_CHUNK_LIMIT): List<ByteArray> {
    require(limit > 0)
    if (data.isEmpty()) return emptyList()
    return buildList {
        var offset = 0
        while (offset < data.size) {
            val end = minOf(data.size, offset + limit)
            add(data.copyOfRange(offset, end))
            offset = end
        }
    }
}
