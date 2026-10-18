package com.innosquad.innoflow.sample

import com.innosquad.innoflow.*
import java.io.File
import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import kotlinx.serialization.json.*
import kotlin.test.*

@OptIn(ExperimentalCoroutinesApi::class)
class RuntimeConformanceTest {
    @Test
    fun sharedRuntimeScenarios() = runTest {
        val fixture = Json.parseToJsonElement(File(System.getProperty("innoflow.contracts"), "conformance/runtime-v1.json").readText()).jsonObject
        for (entry in fixture.getValue("scenarios").jsonArray) {
            val scenario = entry.jsonObject
            val name = scenario.getValue("name").jsonPrimitive.content
            val gate = CompletableDeferred<Unit>()
            val outputs = mutableListOf<Int>()
            var failures = 0
            var delayed: FlowTask? = null
            val store = FlowStore(scenario.getValue("initial").jsonPrimitive.int, Reducer<Int, String, Int> { state, action ->
                when (action) {
                    "increment" -> transition(state + 1)
                    "later" -> transition<Int, String, Int>(state).withEffect(Effect.send("increment"))
                    "emit" -> transition<Int, String, Int>(state).withOutput(state)
                    "failReducer" -> error("fixture reducer failure")
                    "failEffect" -> transition<Int, String, Int>(state).withEffect(Effect.run { error("fixture effect failure") })
                    "startDelayed" -> transition<Int, String, Int>(state).withEffect(Effect.run {
                        withContext(NonCancellable) { gate.await(); send("increment") }
                    })
                    else -> error("Unknown fixture action $action")
                }
            }, backgroundScope, object : FlowInstrumentation<Int, String, Int> {
                override fun outputEmitted(output: Int) { outputs += output }
            })
            try {
                for (stepValue in scenario.getValue("steps").jsonArray) {
                    val step = stepValue.jsonPrimitive.content
                    try {
                        when (step) {
                            "cancel" -> delayed?.cancel()
                            "release" -> { gate.complete(Unit); runCurrent() }
                            "close" -> store.close()
                            "startDelayed" -> { delayed = store.send(step); runCurrent() }
                            else -> store.send(step).finish()
                        }
                    } catch (_: IllegalStateException) { failures += 1 }
                }
                store.finish()
                assertEquals(scenario.getValue("state").jsonPrimitive.int, store.states.value, name)
                assertEquals(scenario.getValue("outputs").jsonArray.map { it.jsonPrimitive.int }, outputs, name)
                assertEquals(scenario.getValue("failures").jsonPrimitive.int, failures, name)
            } finally { gate.complete(Unit); store.close() }
        }
    }
}
