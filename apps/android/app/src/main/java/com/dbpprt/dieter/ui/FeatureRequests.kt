package com.dbpprt.dieter.ui

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/** Main-dispatcher request ownership. Every completion, including failure, checks its original binding. */
internal class FeatureRequests(
    private val scope: CoroutineScope,
    private val binding: () -> Any?,
    private val onError: (String, Throwable) -> Unit,
) {
    inner class Request internal constructor(private val key: String, private val owner: Any?, private val token: Any) {
        val current: Boolean get() = binding() == owner && tokens[key] === token && jobs[key]?.isActive == true
        fun check() { if (!current) throw CancellationException("Feature binding retired") }
    }
    private val tokens = mutableMapOf<String, Any>()
    private val jobs = mutableMapOf<String, Job>()

    fun launch(key: String, block: suspend Request.() -> Unit): Job {
        cancel(key)
        val token = Any()
        val request = Request(key, binding(), token)
        tokens[key] = token
        val job = scope.launch(start = CoroutineStart.LAZY) {
            try { request.check(); request.block()
            } catch (cancelled: CancellationException) { throw cancelled
            } catch (error: Throwable) { if (request.current) onError(key, error) }
        }
        jobs[key] = job
        job.invokeOnCompletion {
            if (tokens[key] === token) { tokens.remove(key); jobs.remove(key) }
        }
        job.start()
        return job
    }

    fun cancel(key: String) { tokens.remove(key); jobs.remove(key)?.cancel() }
    fun cancelAll() = tokens.keys.toList().forEach(::cancel)
}
