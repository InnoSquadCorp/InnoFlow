package com.innosquad.innoflow.sample

import com.innosquad.innoflow.*
import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import kotlinx.coroutines.flow.collect
import kotlin.test.*

@OptIn(ExperimentalCoroutinesApi::class)
class ReleaseContractsTest {
    @Test
    fun boundedRootAdmissionRejectsOnlyOverflowAndRecovers() = runTest {
        val failures = mutableListOf<Throwable>()
        val drained = mutableListOf<FlowQueueMetrics>()
        val store = FlowStore(0, Reducer<Int, Unit, Nothing> { state, _ -> transition(state + 1) },
            backgroundScope, object : FlowInstrumentation<Int, Unit, Nothing> {
                override fun dispatchFailed(action: Unit?, error: Throwable) { failures += error }
                override fun actionQueueDrained(metrics: FlowQueueMetrics) { drained += metrics }
            }, actionCapacity = 1)
        val first = store.send(Unit)
        val second = store.send(Unit)
        val overflow = store.send(Unit)
        assertFailsWith<FlowQueueFullException> { overflow.finish() }
        first.finish()
        second.finish()
        assertEquals(2, store.states.value)
        assertEquals(1, failures.size)
        store.send(Unit).finish()
        assertEquals(3, store.states.value)
        assertEquals(listOf(2, 1), drained.map { it.processedActionCount })
        store.close()
    }

    @Test
    fun effectProducerSuspendsInsteadOfDroppingActions() = runTest {
        val store = FlowStore(0, Reducer<Int, Boolean, Nothing> { state, start ->
            if (start) transition<Int, Boolean, Nothing>(state).withEffect(
                Effect.run { repeat(10_000) { send(false) } })
            else transition(state + 1)
        }, backgroundScope, actionCapacity = 1)
        store.send(true).finish()
        assertEquals(10_000, store.states.value)
        store.close()
    }

    @Test
    fun effectFailureIsObservedAndRetryRemainsUsable() = runTest {
        val store = FlowStore(0, Reducer<Int, Boolean, Nothing> { state, fail ->
            if (fail) transition<Int, Boolean, Nothing>(state).withEffect(Effect.run { error("effect failed") })
            else transition(state + 1)
        }, backgroundScope)
        assertFailsWith<IllegalStateException> { store.send(true).finish() }
        store.send(false).finish()
        assertEquals(1, store.states.value)
        store.close()
    }

    @Test
    fun cancellationIdCancelsEveryMatchingRun() = runTest {
        var cancelled = 0
        val id = EffectId("shared")
        val store = FlowStore(0, Reducer<Int, Boolean, Nothing> { state, start ->
            transition<Int, Boolean, Nothing>(state).withEffect(if (start) Effect.run(id) {
                try { awaitCancellation() } finally { cancelled += 1 }
            } else Effect.cancel(id))
        }, backgroundScope)
        val first = store.send(true)
        val second = store.send(true)
        runCurrent()
        store.send(false).finish()
        first.finish()
        second.finish()
        assertEquals(2, cancelled)
        store.close()
    }

    @Test
    fun cancelledAdmissionDoesNotReduceButIndependentDispatchDoes() = runTest {
        val store = FlowStore(0, Reducer<Int, Unit, Nothing> { state, _ -> transition(state + 1) }, backgroundScope)
        val cancelled = store.send(Unit)
        cancelled.cancel()
        cancelled.finish()
        runCurrent()
        assertEquals(0, store.states.value)
        store.send(Unit).finish()
        assertEquals(1, store.states.value)
        store.close()
    }

    @Test
    fun cancellationFromObserverSuppressesOutputAndEffects() = runTest {
        var outputs = 0
        var runs = 0
        lateinit var task: FlowTask
        val store = FlowStore(0, Reducer<Int, Unit, String> { state, _ ->
            transition<Int, Unit, String>(state + 1).withOutput("late")
                .withEffect(Effect.run { runs += 1 })
        }, backgroundScope, object : FlowInstrumentation<Int, Unit, String> {
            override fun actionReduced(action: Unit, oldState: Int, newState: Int) { task.cancel() }
            override fun outputEmitted(output: String) { outputs += 1 }
        })
        task = store.send(Unit)
        runCurrent()
        task.finish()
        assertEquals(1, store.states.value)
        assertEquals(0, outputs)
        assertEquals(0, runs)
        store.close()
    }

    @Test
    fun cancelledIdSuppressesUncooperativeLateEmission() = runTest {
        val gate = CompletableDeferred<Unit>()
        val id = EffectId("late")
        val store = FlowStore(0, Reducer<Int, String, Nothing> { state, action ->
            when (action) {
                "start" -> transition<Int, String, Nothing>(state).withEffect(Effect.run(id) {
                    withContext(NonCancellable) { gate.await(); send("late") }
                })
                "cancel" -> transition<Int, String, Nothing>(state).withEffect(Effect.cancel(id))
                else -> transition(state + 1)
            }
        }, backgroundScope)
        val task = store.send("start")
        runCurrent()
        store.send("cancel").finish()
        gate.complete(Unit)
        task.finish()
        assertEquals(0, store.states.value)
        store.close()
    }

    @Test
    fun closeReleasesQueuedDispatches() = runTest {
        val store = FlowStore(0, Reducer<Int, Unit, Nothing> { state, _ -> transition(state + 1) }, backgroundScope)
        val tasks = List(100) { store.send(Unit) }
        store.close()
        tasks.forEach { it.finish(); assertTrue(it.isCompleted) }
        assertEquals(0, store.states.value)
        assertFailsWith<IllegalStateException> { store.send(Unit) }
    }

    @Test
    fun concurrentProducersSerializeAgainstLatestState() = runBlocking {
        val owner = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val store = FlowStore(0, Reducer<Int, Unit, Nothing> { state, _ -> transition(state + 1) }, owner, actionCapacity = 64)
        try {
            withTimeout(15_000) {
                coroutineScope { repeat(8) { launch(Dispatchers.Default) { repeat(500) { store.send(Unit).finish() } } } }
                store.finish()
            }
            assertEquals(4_000, store.states.value)
        } finally { store.close(); owner.cancel() }
    }

    @Test
    fun invalidCapacityIsRejected() = runTest {
        for (capacity in listOf(0, -1, Int.MAX_VALUE)) {
            assertFailsWith<IllegalArgumentException> {
                FlowStore(0, Reducer<Int, Unit, Nothing> { state, _ -> transition(state) }, backgroundScope, actionCapacity = capacity)
            }
        }
    }

    @Test
    fun rejectedConstructionKeepsParentAndSiblingUnchanged() = runTest {
        for (capacity in listOf(0, -1, Int.MIN_VALUE, Int.MAX_VALUE)) {
            val parent = Job()
            val sibling = Job(parent)
            val scope = CoroutineScope(backgroundScope.coroutineContext.minusKey(Job) + parent)
            try {
                assertFailsWith<IllegalArgumentException> {
                    FlowStore(0, Reducer<Int, Unit, Nothing> { state, _ -> transition(state) },
                        scope, actionCapacity = capacity)
                }
                assertEquals(listOf(sibling), parent.children.toList(), "capacity $capacity leaked an owned Job")
                assertTrue(parent.isActive)
                assertTrue(sibling.isActive)
                sibling.complete()
                parent.complete()
                withTimeout(1_000) { parent.join() }
            } finally { parent.cancelAndJoin() }
        }
    }

    @Test
    fun validConstructionAndCloseReleaseTheOwnedJob() = runTest {
        for (capacity in listOf(1, 8, 1_024)) {
            val parent = Job()
            val scope = CoroutineScope(backgroundScope.coroutineContext.minusKey(Job) + parent)
            try {
                val store = FlowStore(0, Reducer<Int, Unit, Nothing> { state, _ -> transition(state + 1) },
                    scope, actionCapacity = capacity)
                store.send(Unit).finish()
                assertEquals(1, store.states.value)
                store.close()
                runCurrent()
                assertTrue(parent.children.none())
                parent.complete()
                withTimeout(1_000) { parent.join() }
            } finally { parent.cancelAndJoin() }
        }
    }

    @Test
    fun outputCollectorsCompleteWhenStoreCloses() = runTest {
        val store = FlowStore(0, Reducer<Int, Unit, Int> { state, _ -> transition<Int, Unit, Int>(state).withOutput(1) }, backgroundScope)
        val values = mutableListOf<Int>()
        val collector = backgroundScope.launch { store.outputs.collect { values += it } }
        runCurrent()
        store.send(Unit).finish()
        runCurrent()
        store.close()
        runCurrent()
        assertTrue(collector.isCompleted)
        assertEquals(listOf(1), values)
    }
}
