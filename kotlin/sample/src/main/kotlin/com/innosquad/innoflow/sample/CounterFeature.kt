package com.innosquad.innoflow.sample

import com.innosquad.innoflow.Effect
import com.innosquad.innoflow.FlowFeature
import com.innosquad.innoflow.InnoFlow
import com.innosquad.innoflow.Reducer
import com.innosquad.innoflow.transition

public data class CounterState(val count: Int = 0)

public sealed interface CounterAction {
    public data object Increment : CounterAction
    public data object Decrement : CounterAction
    public data object IncrementLater : CounterAction
    public data object Reset : CounterAction
}

@InnoFlow
public class CounterFeature(
    override val initialState: CounterState = CounterState(),
) : FlowFeature<CounterState, CounterAction, Nothing> {
    override val reducer: Reducer<CounterState, CounterAction, Nothing> =
        Reducer { state, action ->
            when (action) {
                CounterAction.Increment -> transition(state.copy(count = state.count + 1))
                CounterAction.Decrement -> transition(state.copy(count = state.count - 1))
                CounterAction.Reset -> transition(state.copy(count = 0))
                CounterAction.IncrementLater -> transition<CounterState, CounterAction, Nothing>(state)
                    .withEffect(Effect.send(CounterAction.Increment))
            }
        }
}
