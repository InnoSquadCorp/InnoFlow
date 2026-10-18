package com.innosquad.innoflow

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CompletableJob
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob

public class FlowTask internal constructor(
    private val context: DispatchContext,
) {
    public suspend fun finish() {
        context.completion.await()
    }

    public fun cancel() {
        context.cancel()
    }

    public val isCompleted: Boolean
        get() = context.completion.isCompleted
}

internal class DispatchContext(parent: Job) {
    private val lock = Any()
    private var pending = 1
    private var cancelled = false
    private var terminal = false

    internal val job: CompletableJob = SupervisorJob(parent)
    internal val completion = CompletableDeferred<Unit>()

    internal fun retain(): Boolean = synchronized(lock) {
        if (terminal || !job.isActive) {
            false
        } else {
            pending += 1
            true
        }
    }

    internal fun release() {
        val shouldComplete = synchronized(lock) {
            if (pending > 0) pending -= 1
            (pending == 0 && !terminal).also { if (it) terminal = true }
        }
        if (shouldComplete) {
            job.complete()
            completion.complete(Unit)
        }
    }

    internal fun fail(error: Throwable) {
        synchronized(lock) {
            if (terminal) return
            cancelled = true
            terminal = true
        }
        job.cancel()
        completion.completeExceptionally(error)
    }

    internal fun cancel() {
        synchronized(lock) {
            if (terminal) return
            cancelled = true
            terminal = true
        }
        job.cancel()
        completion.complete(Unit)
    }

    internal fun isCancelled(): Boolean = synchronized(lock) { cancelled || !job.isActive }
}
