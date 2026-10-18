package com.innosquad.innoflow.sample.android

import androidx.lifecycle.SavedStateHandle
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.*
import org.junit.Assert.assertEquals
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class SavedStateTest {
    @Test
    fun reconstructsTheFeatureFromExplicitSavedState() = runTest {
        Dispatchers.setMain(StandardTestDispatcher(testScheduler))
        val saved = SavedStateHandle(mapOf("count" to 9))
        val first = CounterViewModel(saved)
        try {
            first.store.send(CounterAction.Increment).finish()
            assertEquals(10, saved.get<Int>("count"))
            val restored = CounterViewModel(SavedStateHandle(mapOf("count" to saved.get<Int>("count"))))
            try { assertEquals(10, restored.store.states.value.count) }
            finally { restored.store.close() }
        } finally { first.store.close(); Dispatchers.resetMain() }
    }
}
