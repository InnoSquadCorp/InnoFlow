package com.example

import com.innosquad.innoflow.FlowFeature
import com.innosquad.innoflow.InnoFlow
import com.innosquad.innoflow.Reducer
import com.innosquad.innoflow.transition

public data class CounterState(public val count: Int = 0)

public sealed interface CounterAction {
    public data object Increment : CounterAction
}

@InnoFlow
public class CounterFeature : FlowFeature<CounterState, CounterAction, Nothing> {
    override val initialState: CounterState = CounterState()
    override val reducer: Reducer<CounterState, CounterAction, Nothing> = Reducer { state, action ->
        when (action) {
            CounterAction.Increment -> transition(state.copy(count = state.count + 1))
        }
    }
}
