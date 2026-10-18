package com.innosquad.innoflow.android

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.ViewModelStore
import com.innosquad.innoflow.Effect
import com.innosquad.innoflow.FlowFeature
import com.innosquad.innoflow.FlowStore
import com.innosquad.innoflow.Reducer
import com.innosquad.innoflow.transition
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
public class ViewModelFlowStoreTest {
    private val dispatcher = StandardTestDispatcher()

    @Before
    public fun setUp() {
        Dispatchers.setMain(dispatcher)
    }

    @After
    public fun tearDown() {
        Dispatchers.resetMain()
    }

    @Test
    public fun viewModelStoreClearClosesOwnedFlowStore() = runTest(dispatcher) {
        val owner = ViewModelStore()
        val viewModel = ViewModelProvider(
            owner,
            object : ViewModelProvider.Factory {
                @Suppress("UNCHECKED_CAST")
                override fun <T : ViewModel> create(modelClass: Class<T>): T = TestViewModel() as T
            },
        )[TestViewModel::class.java]

        val task = viewModel.flowStore.send(Unit)
        runCurrent()
        owner.clear()
        task.finish()

        assertTrue(task.isCompleted)
        assertEquals(0, viewModel.flowStore.states.value)
    }

    private class TestViewModel : ViewModel() {
        val flowStore: FlowStore<Int, Unit, Nothing> = createFlowStore(
            object : FlowFeature<Int, Unit, Nothing> {
                override val initialState: Int = 0
                override val reducer: Reducer<Int, Unit, Nothing> = Reducer { state, _ ->
                    transition<Int, Unit, Nothing>(state)
                        .withEffect(Effect.run { awaitCancellation() })
                }
            },
        )
    }
}
