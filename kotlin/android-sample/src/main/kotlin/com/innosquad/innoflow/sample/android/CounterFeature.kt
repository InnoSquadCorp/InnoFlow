package com.innosquad.innoflow.sample.android

import com.innosquad.innoflow.FlowFeature
import com.innosquad.innoflow.InnoFlow
import com.innosquad.innoflow.Reducer
import com.innosquad.innoflow.transition

public data class CounterState(public val count: Int = 0)

public sealed interface CounterAction {
    public data object Increment : CounterAction
    public data object Decrement : CounterAction
}

@InnoFlow
public class CounterFeature(initialCount: Int = 0) : FlowFeature<CounterState, CounterAction, Nothing> {
    override val initialState: CounterState = CounterState(initialCount)
    override val reducer: Reducer<CounterState, CounterAction, Nothing> = Reducer { state, action ->
        when (action) {
            CounterAction.Increment -> transition(state.copy(count = state.count + 1))
            CounterAction.Decrement -> transition(state.copy(count = state.count - 1))
        }
    }
}
