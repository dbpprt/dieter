package com.dbpprt.dieter.core.workspace

import com.dbpprt.dieter.api.v1.FileDiff
import com.dbpprt.dieter.api.v1.GetDiffRequest
import com.dbpprt.dieter.api.v1.GitOperation
import com.dbpprt.dieter.api.v1.GitOperationRef
import com.dbpprt.dieter.core.runtime.Deadlines
import com.dbpprt.dieter.core.session.MachineSessions
import kotlin.coroutines.cancellation.CancellationException
import kotlin.time.Duration
import kotlin.time.Duration.Companion.hours
import kotlin.time.TimeSource
import kotlinx.coroutines.delay

/**
 * Paged diffs, shared by the review and project changes surfaces. A diff
 * loads [PAGE] bytes at a time and shows at most [LIMIT] bytes; a larger one
 * stays truncated and says so instead of loading more.
 */
object DiffPages {
    const val PAGE = 1 shl 20
    const val LIMIT = 4L * PAGE
    const val TOO_LARGE = "This diff is too large to show in full; its first 4 MB are shown."

    /** Whether another page of [diff] may load. */
    fun hasMore(diff: FileDiff?): Boolean = diff?.truncated == true && diff.next_offset < LIMIT

    /**
     * Reads the first page of [request] from [daemonId], or the page after
     * [loaded]; the result carries every page read so far.
     */
    suspend fun read(sessions: MachineSessions, daemonId: String, request: GetDiffRequest, loaded: FileDiff? = null): FileDiff {
        val paged = request.copy(offset = loaded?.next_offset ?: 0, limit = PAGE)
        val page = sessions.call(daemonId, Deadlines.READ) { client ->
            if (paged.commit_sha.isNotEmpty()) client.GetCommitDiff().execute(paged) else client.GetFileDiff().execute(paged)
        }
        return if (loaded != null) page.copy(patch = loaded.patch + page.patch) else page
    }
}

/** How long a surface follows one Git operation before it stops waiting. */
private val GIT_OPERATION_LIMIT: Duration = 1.hours

/**
 * Follows [operation] on [daemonId] until [settled] accepts it: every
 * [interval] it takes the state [streamed] already holds for it, else reads
 * it. Stops when [keep] turns false or after [GIT_OPERATION_LIMIT] and
 * returns the last state seen. A failed read ends the wait unless
 * [retryReads], which tries again at the next interval.
 */
suspend fun MachineSessions.followGitOperation(
    daemonId: String,
    operation: GitOperation,
    interval: Duration,
    keep: () -> Boolean = { true },
    settled: (GitOperation) -> Boolean = { it.status !in GitOperations.ACTIVE },
    streamed: () -> GitOperation? = { null },
    retryReads: Boolean = false,
    onRead: (GitOperation) -> Unit = {},
): GitOperation {
    var current = operation
    val started = TimeSource.Monotonic.markNow()
    while (keep() && !settled(current) && started.elapsedNow() < GIT_OPERATION_LIMIT) {
        delay(interval)
        current = streamed()?.takeIf { it.id == operation.id && settled(it) } ?: try {
            call(daemonId, Deadlines.READ) { it.GetGitOperation().execute(GitOperationRef(operation_id = operation.id)) }
        } catch (error: Throwable) {
            if (error is CancellationException || !retryReads) throw error
            continue
        }
        onRead(current)
    }
    return current
}
