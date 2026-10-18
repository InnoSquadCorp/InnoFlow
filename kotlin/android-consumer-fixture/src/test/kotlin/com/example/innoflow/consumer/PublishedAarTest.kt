package com.example.innoflow.consumer

import com.innosquad.innoflow.testing.TestStore
import kotlinx.coroutines.test.runTest
import org.junit.Test

class PublishedAarTest {
    @Test fun consumesPublishedTestingAndReducer() = runTest {
        TestStore(CounterState(), CounterFeature.reducer, backgroundScope).use { store ->
            store.send(Unit, CounterState(1))
            store.assertActions(listOf(Unit))
            store.finish()
        }
    }
}
