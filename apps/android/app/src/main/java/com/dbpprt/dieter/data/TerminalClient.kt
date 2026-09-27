package com.dbpprt.dieter.data

import com.dbpprt.dieter.v1.*
import com.google.protobuf.ByteString
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.flow.Flow

/** A captured, authenticated route. Closing/replacing its channel fails calls; it never retargets them. */
interface TerminalClient {
    suspend fun terminals(): TerminalsResponse
    suspend fun create(request: CreateTerminalRequest): Terminal
    fun watch(id: String, afterSequence: Long): Flow<TerminalFrame>
    suspend fun write(id: String, data: ByteArray)
    suspend fun resize(id: String, columns: Int, rows: Int): Terminal
    suspend fun rename(id: String, name: String): Terminal
    suspend fun close(id: String)
}

internal class GrpcTerminalClient(
    private val route: DieterServiceGrpcKt.DieterServiceCoroutineStub,
    private val checkout: (String) -> String,
) : TerminalClient {
    private fun unary() = route.withDeadlineAfter(15, TimeUnit.SECONDS)
    override suspend fun terminals() = unary().listTerminals(ListTerminalsRequest.getDefaultInstance())
    override suspend fun create(request: CreateTerminalRequest) = unary().createTerminal(
        request.toBuilder().setCheckoutId(request.checkoutId.ifBlank { checkout(request.projectId) }).build(),
    )
    override fun watch(id: String, afterSequence: Long) = route.watchTerminal(
        WatchTerminalRequest.newBuilder().setTerminalId(id).setAfterSequence(afterSequence).setHeartbeatMs(15_000).build(),
    )
    override suspend fun write(id: String, data: ByteArray) {
        unary().writeTerminal(TerminalInputRequest.newBuilder().setTerminalId(id).setData(ByteString.copyFrom(data)).build())
    }
    override suspend fun resize(id: String, columns: Int, rows: Int) = unary().resizeTerminal(
        ResizeTerminalRequest.newBuilder().setTerminalId(id).setColumns(columns).setRows(rows).build(),
    )
    override suspend fun rename(id: String, name: String) = unary().renameTerminal(
        RenameTerminalRequest.newBuilder().setTerminalId(id).setName(name).build(),
    )
    override suspend fun close(id: String) {
        unary().closeTerminal(TerminalRef.newBuilder().setTerminalId(id).build())
    }
}
