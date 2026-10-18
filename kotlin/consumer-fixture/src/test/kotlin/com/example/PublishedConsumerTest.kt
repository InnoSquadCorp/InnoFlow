package com.example

import com.innosquad.innoflow.testing.TestStore
import kotlinx.coroutines.test.runTest
import kotlin.test.Test

class PublishedConsumerTest {
    @Test
    fun generatedFactoryAndTestingArtifactAreConsumable() = runTest {
        val feature = CounterFeature()
        val store = CounterFeatureFlow.create(feature, backgroundScope)

        store.send(CounterAction.Increment).finish()

        TestStore(feature.initialState, feature.reducer, backgroundScope).use { testStore ->
            testStore.send(CounterAction.Increment) { state ->
                check(state.count == 1)
            }
        }
        check(store.states.value.count == 1)
        store.close()
    }
}
