package com.innosquad.innoflow.compose

import androidx.activity.ComponentActivity
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.testing.TestLifecycleOwner
import com.innosquad.innoflow.*
import kotlinx.coroutines.*
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test

class LifecycleCollectionTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    @Test
    fun stateCollectionPausesAndResumesWithLatestValue() {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        val store = FlowStore(0, Reducer<Int, Int, Nothing> { state, delta -> transition(state + delta) }, scope)
        val owner = TestLifecycleOwner(Lifecycle.State.RESUMED)
        try {
            compose.setContent {
                CompositionLocalProvider(LocalLifecycleOwner provides owner) {
                    val state by store.collectStateWithLifecycle()
                    Text("Count: $state")
                }
            }
            compose.runOnIdle { store.send(1) }
            compose.onNodeWithText("Count: 1").assertExists()
            compose.runOnIdle { owner.currentState = Lifecycle.State.CREATED }
            compose.waitForIdle()
            compose.runOnIdle { store.send(2) }
            compose.onNodeWithText("Count: 1").assertExists()
            compose.runOnIdle { owner.currentState = Lifecycle.State.RESUMED }
            compose.onNodeWithText("Count: 3").assertExists()
        } finally { store.close(); scope.cancel() }
    }

    @Test
    fun outputsUseLatestHandlerAndNeverReplayBackgroundEvents() {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
        val store = FlowStore(0, Reducer<Int, Int, Int> { state, value -> transition<Int, Int, Int>(state).withOutput(value) }, scope)
        val owner = TestLifecycleOwner(Lifecycle.State.RESUMED)
        val outputs = mutableListOf<String>()
        var handler by mutableStateOf("first")
        try {
            compose.setContent {
                val current = handler
                CompositionLocalProvider(LocalLifecycleOwner provides owner) {
                    store.CollectOutputsWithLifecycle { outputs += "$current:$it" }
                }
            }
            compose.waitForIdle()
            compose.runOnIdle { store.send(1) }
            compose.waitUntil { outputs.size == 1 }
            compose.runOnIdle { handler = "second" }
            compose.waitForIdle()
            compose.runOnIdle { store.send(2) }
            compose.waitUntil { outputs.size == 2 }
            compose.runOnIdle { owner.currentState = Lifecycle.State.CREATED }
            compose.waitForIdle()
            compose.runOnIdle { store.send(3) }
            compose.runOnIdle { owner.currentState = Lifecycle.State.RESUMED }
            compose.waitForIdle()
            compose.runOnIdle { store.send(4) }
            compose.waitUntil { outputs.size == 3 }
            compose.runOnIdle { assertEquals(listOf("first:1", "second:2", "second:4"), outputs) }
        } finally { store.close(); scope.cancel() }
    }
}
