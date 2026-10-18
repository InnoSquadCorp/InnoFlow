package com.innosquad.innoflow.sample

import com.innosquad.innoflow.Effect
import com.innosquad.innoflow.EffectId
import com.innosquad.innoflow.FlowStore
import com.innosquad.innoflow.FlowInstrumentation
import com.innosquad.innoflow.Reducer
import com.innosquad.innoflow.testing.TestStore
import com.innosquad.innoflow.transition
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

@OptIn(ExperimentalCoroutinesApi::class)
public class FlowRuntimeTest {
    private data class SearchState(val value: String = "")

    private sealed interface SearchAction {
        data class Search(val query: String) : SearchAction
        data class Loaded(val value: String) : SearchAction
    }

    @Test
    public fun cancellationIdImplementsLatestWins() = runTest {
        val results = mutableMapOf<String, CompletableDeferred<String>>()
        val searchId = EffectId("search")
        val reducer = Reducer<SearchState, SearchAction, Nothing> { state, action ->
            when (action) {
                is SearchAction.Loaded -> transition(state.copy(value = action.value))
                is SearchAction.Search -> transition<SearchState, SearchAction, Nothing>(state)
                    .withEffect(
                        Effect.run(id = searchId, cancelInFlight = true) {
                            val result = results.getOrPut(action.query) { CompletableDeferred() }.await()
                            send(SearchAction.Loaded(result))
                        },
                    )
            }
        }
        val store = FlowStore(SearchState(), reducer, backgroundScope)

        val first = store.send(SearchAction.Search("first"))
        runCurrent()
        val second = store.send(SearchAction.Search("second"))
        runCurrent()
        results.getValue("second").complete("fresh")
        second.finish()
        first.finish()

        assertEquals(SearchState("fresh"), store.states.value)
        store.close()
    }

    @Test
    public fun typedOutputIsRecordedOutsideState() = runTest {
        val reducer = Reducer<Int, Unit, String> { state, _ ->
            transition<Int, Unit, String>(state + 1).withOutput("completed")
        }

        TestStore(0, reducer, backgroundScope).use { store ->
            store.send(Unit, 1)
            store.assertOutputs(listOf("completed"))
        }
    }

    @Test
    public fun instrumentationFailureDoesNotChangeRuntimeSemantics() = runTest {
        val reducer = Reducer<Int, Unit, Nothing> { state, _ -> transition(state + 1) }
        val store = FlowStore(
            initialState = 0,
            reducer = reducer,
            scope = backgroundScope,
            instrumentation = object : FlowInstrumentation<Int, Unit, Nothing> {
                override fun actionReduced(action: Unit, oldState: Int, newState: Int) {
                    error("observer failure")
                }
            },
        )

        store.send(Unit).finish()

        assertEquals(1, store.states.value)
        store.close()
    }

    @Test
    public fun ownerScopeCancellationFinishesDispatchTasks() = runTest {
        val owner = Job()
        val store = FlowStore(
            initialState = 0,
            reducer = Reducer<Int, Unit, Nothing> { state, _ ->
                transition<Int, Unit, Nothing>(state)
                    .withEffect(Effect.run { awaitCancellation() })
            },
            scope = CoroutineScope(coroutineContext + owner),
        )
        val task = store.send(Unit)
        runCurrent()

        owner.cancel()
        task.finish()

        assertEquals(true, task.isCompleted)
    }

    @Test
    public fun reducerFailureRejectsOnlyItsDispatchTreeAndStoreRemainsUsable() = runTest {
        val reducer = Reducer<Int, Boolean, Nothing> { state, shouldFail ->
            if (shouldFail) error("expected reducer failure")
            transition(state + 1)
        }
        val store = FlowStore(0, reducer, backgroundScope)

        assertFailsWith<IllegalStateException> { store.send(true).finish() }
        store.send(false).finish()

        assertEquals(1, store.states.value)
        store.close()
    }

    @Test
    public fun actionQueueRemainsLosslessAcrossLargeBursts() = runTest {
        val queueMetrics = mutableListOf<Pair<Int, Int>>()
        val store = FlowStore(
            initialState = 0,
            reducer = Reducer<Int, Unit, Nothing> { state, _ -> transition(state + 1) },
            scope = backgroundScope,
            actionCapacity = 10_000,
            instrumentation = object : FlowInstrumentation<Int, Unit, Nothing> {
                override fun actionQueueDrained(metrics: com.innosquad.innoflow.FlowQueueMetrics) {
                    queueMetrics += metrics.processedActionCount to
                        metrics.pendingActionHighWaterMark
                }
            },
        )

        repeat(10_000) { store.send(Unit) }
        store.finish()

        assertEquals(10_000, store.states.value)
        assertEquals(10_000, queueMetrics.sumOf { it.first })
        assertTrue(queueMetrics.maxOf { it.second } > 0)
        store.close()
    }

    @Test
    public fun liveOutputCollectorReceivesOutputsInOrder() = runTest {
        val store = FlowStore(
            initialState = 0,
            reducer = Reducer<Int, Int, Int> { state, value ->
                transition<Int, Int, Int>(state + value).withOutput(value)
            },
            scope = backgroundScope,
        )
        val values = mutableListOf<Int>()
        val receivedBoth = CompletableDeferred<Unit>()
        val collector = backgroundScope.launch {
            store.outputs.collect {
                values += it
                if (values.size == 2) receivedBoth.complete(Unit)
            }
        }
        runCurrent()

        store.send(1).finish()
        store.send(2).finish()
        receivedBoth.await()
        collector.cancelAndJoin()

        assertEquals(listOf(1, 2), values)
        store.close()
    }

    @Test
    public fun slowLiveOutputCollectorReportsBackpressureDrops() = runTest {
        var dropped = 0
        val releaseCollector = CompletableDeferred<Unit>()
        val store = FlowStore(
            initialState = 0,
            reducer = Reducer<Int, Int, Int> { state, value ->
                transition<Int, Int, Int>(state + 1).withOutput(value)
            },
            scope = backgroundScope,
            instrumentation = object : FlowInstrumentation<Int, Int, Int> {
                override fun outputDropped(output: Int) {
                    dropped += 1
                }
            },
        )
        val collector = backgroundScope.launch {
            store.outputs.collect { releaseCollector.await() }
        }
        runCurrent()

        repeat(100) { store.send(it) }
        runCurrent()
        store.finish()

        assertTrue(dropped > 0)
        releaseCollector.complete(Unit)
        collector.cancelAndJoin()
        store.close()
    }

    @Test
    public fun closeCancelsActiveTasksAndRejectsLaterSends() = runTest {
        val store = FlowStore(
            initialState = 0,
            reducer = Reducer<Int, Unit, Nothing> { state, _ ->
                transition<Int, Unit, Nothing>(state)
                    .withEffect(Effect.run { awaitCancellation() })
            },
            scope = backgroundScope,
        )
        val task = store.send(Unit)
        runCurrent()

        store.close()
        task.finish()

        assertTrue(task.isCompleted)
        assertFailsWith<IllegalStateException> { store.send(Unit) }
    }
}
