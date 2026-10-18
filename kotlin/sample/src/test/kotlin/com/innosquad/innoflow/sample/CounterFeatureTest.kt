package com.innosquad.innoflow.sample

import com.innosquad.innoflow.testing.TestStore
import java.io.File
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlin.test.Test
import kotlin.test.assertEquals

@OptIn(ExperimentalCoroutinesApi::class)
public class CounterFeatureTest {
    @Test
    public fun generatedFactoryRunsDescendantActions() = runTest {
        val store = CounterFeatureFlow.create(CounterFeature(), backgroundScope)

        store.send(CounterAction.IncrementLater).finish()

        assertEquals(CounterState(count = 1), store.states.value)
        store.close()
    }

    @Test
    public fun testStoreRecordsExhaustiveActionOrder() = runTest {
        TestStore(
            initialState = CounterState(),
            reducer = CounterFeature().reducer,
            scope = backgroundScope,
        ).use { store ->
            store.send(CounterAction.IncrementLater, CounterState(count = 1))
            store.assertActions(
                listOf(CounterAction.IncrementLater, CounterAction.Increment),
            )
        }
    }

    @Test
    public fun sharedCounterConformanceFixture() = runTest {
        val contracts = File(requireNotNull(System.getProperty("innoflow.contracts")))
        val root = Json.parseToJsonElement(
            contracts.resolve("conformance/counter-v1.json").readText(),
        ).jsonObject

        root.getValue("scenarios").jsonArray.forEach { scenarioElement ->
            val scenario = scenarioElement.jsonObject
            val initial = scenario.getValue("initial").jsonPrimitive.content.toInt()
            val feature = CounterFeature(CounterState(initial))
            val store = CounterFeatureFlow.create(feature, backgroundScope)

            scenario.getValue("actions").jsonArray.forEach { actionElement ->
                val action = when (actionElement.jsonPrimitive.content) {
                    "increment" -> CounterAction.Increment
                    "decrement" -> CounterAction.Decrement
                    "reset" -> CounterAction.Reset
                    else -> error("Unknown conformance action: $actionElement")
                }
                store.send(action).finish()
            }

            assertEquals(
                scenario.getValue("expected").jsonPrimitive.content.toInt(),
                store.states.value.count,
                scenario.getValue("name").jsonPrimitive.content,
            )
            store.close()
        }
    }
}
