package com.innosquad.innoflow

import java.io.Closeable
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.buffer
import kotlinx.coroutines.flow.channelFlow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch

/** A synchronous send was rejected without dropping any previously accepted action. */
public class FlowQueueFullException(public val capacity: Int) :
    IllegalStateException("FlowStore action queue is full (capacity $capacity)")

public class FlowStore<State, Action, Output>(
    initialState: State,
    private val reducer: Reducer<State, Action, Output>,
    scope: CoroutineScope,
    private val instrumentation: FlowInstrumentation<State, Action, Output> =
        FlowInstrumentation.none(),
    private val actionCapacity: Int = 1024,
) : Closeable {
    private class Envelope<Action>(
        val action: Action,
        val context: DispatchContext,
    ) {
        val completed = AtomicBoolean(false)
    }

    // A rejected constructor has no instance to close: validate before
    // attaching the store's Job to its owner's lifecycle.
    init {
        require(actionCapacity in 1 until Channel.UNLIMITED) {
            "actionCapacity must be positive and bounded"
        }
    }

    private val lock = Any()
    private val parentJob = SupervisorJob(scope.coroutineContext[Job])
    private val storeScope = CoroutineScope(scope.coroutineContext.minusKey(Job) + parentJob)
    private val queue = Channel<Envelope<Action>>(
        capacity = actionCapacity,
        onUndeliveredElement = { completeEnvelope(it) },
    )
    private val contexts = mutableSetOf<DispatchContext>()
    private val effectsById = mutableMapOf<EffectId, MutableSet<Job>>()
    private var closed = false
    private var pendingActionCount = 0
    private var pendingActionHighWaterMark = 0
    private var processedActionCount = 0
    private val closeSignal = CompletableDeferred<Unit>()

    private val mutableStates = MutableStateFlow(initialState)
    private val mutableOutputs = MutableSharedFlow<Output>(
        replay = 0,
        extraBufferCapacity = 64,
    )

    public val states: StateFlow<State> = mutableStates.asStateFlow()
    public val outputs: Flow<Output> = channelFlow {
        if (closeSignal.isCompleted) return@channelFlow
        val collector = launch(start = CoroutineStart.UNDISPATCHED) {
            mutableOutputs.collect { send(it) }
        }
        closeSignal.await()
        collector.cancelAndJoin()
    }.buffer(0)

    init {
        parentJob.invokeOnCompletion { close() }
        storeScope.launch(start = CoroutineStart.UNDISPATCHED) {
            try {
                for (envelope in queue) process(envelope)
            } finally {
                close()
            }
        }
    }

    public fun send(action: Action): FlowTask {
        val context = synchronized(lock) {
            check(!closed) { "FlowStore is closed" }
            DispatchContext(parentJob).also { contexts += it }
        }
        context.completion.invokeOnCompletion {
            synchronized(lock) { contexts -= context }
        }

        if (!enqueue(Envelope(action, context))) {
            context.cancel()
        }
        return FlowTask(context)
    }

    public suspend fun finish() {
        while (true) {
            val snapshot = synchronized(lock) { contexts.map { it.completion } }
            if (snapshot.isEmpty()) return
            snapshot.forEach { it.await() }
        }
    }

    override fun close() {
        val activeContexts: List<DispatchContext>
        val activeEffects: List<Job>
        synchronized(lock) {
            if (closed) return
            closed = true
            activeContexts = contexts.toList()
            activeEffects = effectsById.values.flatMap { it.toList() }
            effectsById.clear()
        }

        activeContexts.forEach(DispatchContext::cancel)
        activeEffects.forEach(Job::cancel)
        closeSignal.complete(Unit)
        queue.cancel()
        parentJob.cancel()
    }

    private fun process(envelope: Envelope<Action>) {
        val context = envelope.context
        try {
            if (context.isCancelled()) return

            val oldState = mutableStates.value
            val next = reducer.reduce(oldState, envelope.action)
            mutableStates.value = next.state
            observe { instrumentation.actionReduced(envelope.action, oldState, next.state) }

            for (output in next.outputs) {
                if (context.isCancelled()) break
                if (mutableOutputs.tryEmit(output)) {
                    observe { instrumentation.outputEmitted(output) }
                } else {
                    observe { instrumentation.outputDropped(output) }
                }
            }
            for (effect in next.effects) {
                if (context.isCancelled()) break
                launch(effect, context)
            }
        } catch (error: Throwable) {
            if (!context.isCancelled()) {
                observe { instrumentation.dispatchFailed(envelope.action, error) }
                context.fail(error)
            }
        } finally {
            completeEnvelope(envelope)
        }
    }

    private fun enqueue(envelope: Envelope<Action>): Boolean {
        val pending = synchronized(lock) {
            if (closed) {
                envelope.context.release()
                return false
            }
            pendingActionCount += 1
            pendingActionHighWaterMark = maxOf(pendingActionHighWaterMark, pendingActionCount)
            pendingActionCount
        }

        if (queue.trySend(envelope).isSuccess) {
            observe { instrumentation.actionQueued(envelope.action, pending) }
            return true
        }

        val error = FlowQueueFullException(actionCapacity)
        observe { instrumentation.dispatchFailed(envelope.action, error) }
        envelope.context.fail(error)
        completeEnvelope(envelope, processed = false)
        return false
    }

    private suspend fun enqueueSuspending(envelope: Envelope<Action>) {
        val pending = synchronized(lock) {
            if (closed) {
                envelope.context.release()
                return
            }
            pendingActionCount += 1
            pendingActionHighWaterMark = maxOf(pendingActionHighWaterMark, pendingActionCount)
            pendingActionCount
        }
        try {
            queue.send(envelope)
            observe { instrumentation.actionQueued(envelope.action, pending) }
        } catch (error: Throwable) {
            completeEnvelope(envelope)
            throw error
        }
    }

    private fun completeEnvelope(envelope: Envelope<Action>, processed: Boolean = true) {
        if (envelope.completed.compareAndSet(false, true)) {
            envelope.context.release()
            actionProcessed(processed)
        }
    }

    private fun actionProcessed(processed: Boolean) {
        val metrics = synchronized(lock) {
            if (pendingActionCount > 0) pendingActionCount -= 1
            if (processed) processedActionCount += 1
            if (pendingActionCount != 0) {
                null
            } else {
                FlowQueueMetrics(
                    processedActionCount = processedActionCount,
                    pendingActionHighWaterMark = pendingActionHighWaterMark,
                ).also {
                    processedActionCount = 0
                    pendingActionHighWaterMark = 0
                }
            }
        }
        if (metrics != null) {
            observe { instrumentation.actionQueueDrained(metrics) }
        }
    }

    private fun launch(effect: Effect<Action>, context: DispatchContext) {
        when (val operation = effect.operation) {
            is Effect.Operation.Cancel -> cancelEffect(operation.id)
            is Effect.Operation.Run -> launchEffect(operation, context)
        }
    }

    private fun cancelEffect(id: EffectId) {
        val jobs = synchronized(lock) { effectsById.remove(id)?.toList() }
        jobs?.forEach(Job::cancel)
    }

    private fun launchEffect(
        operation: Effect.Operation.Run<Action>,
        context: DispatchContext,
    ) {
        if (!context.retain()) return

        if (operation.cancelInFlight) {
            operation.id?.let(::cancelEffect)
        }

        lateinit var effectJob: Job
        val started = AtomicBoolean(false)
        val dispatchScope = CoroutineScope(
            storeScope.coroutineContext.minusKey(Job) + context.job,
        )
        effectJob = dispatchScope.launch(start = CoroutineStart.LAZY) {
            started.set(true)
            observe { instrumentation.effectStarted(operation.id) }
            try {
                currentCoroutineContext().ensureActive()
                operation.block(
                    object : EffectScope<Action> {
                        override suspend fun send(action: Action) {
                            if (!effectJob.isActive || !context.retain()) return
                            enqueueSuspending(Envelope(action, context))
                        }
                    },
                )
            } catch (cancellation: CancellationException) {
                throw cancellation
            } catch (error: Throwable) {
                if (effectJob.isActive && !context.isCancelled()) {
                    observe { instrumentation.dispatchFailed(null, error) }
                    context.fail(error)
                }
            }
        }

        operation.id?.let { id ->
            synchronized(lock) { effectsById.getOrPut(id) { mutableSetOf() }.add(effectJob) }
        }
        effectJob.invokeOnCompletion {
            operation.id?.let { id ->
                synchronized(lock) {
                    effectsById[id]?.let { jobs ->
                        jobs.remove(effectJob)
                        if (jobs.isEmpty()) effectsById.remove(id)
                    }
                }
            }
            if (started.get()) observe { instrumentation.effectFinished(operation.id) }
            context.release()
        }
        effectJob.start()
    }

    private inline fun observe(event: () -> Unit) {
        try {
            event()
        } catch (_: Throwable) {
            // Instrumentation must not change reducer or effect semantics.
        }
    }
}
