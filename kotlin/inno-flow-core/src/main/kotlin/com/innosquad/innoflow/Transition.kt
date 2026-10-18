package com.innosquad.innoflow

public class Transition<State, Action, Output> private constructor(
    public val state: State,
    internal val effects: List<Effect<Action>>,
    internal val outputs: List<Output>,
) {
    public fun withEffect(effect: Effect<Action>): Transition<State, Action, Output> =
        Transition(state, effects + effect, outputs)

    public fun withEffects(vararg effects: Effect<Action>): Transition<State, Action, Output> =
        Transition(state, this.effects + effects, outputs)

    public fun withOutput(output: Output): Transition<State, Action, Output> =
        Transition(state, effects, outputs + output)

    public fun withOutputs(vararg outputs: Output): Transition<State, Action, Output> =
        Transition(state, effects, this.outputs + outputs)

    internal companion object {
        internal fun <State, Action, Output> create(
            state: State,
            effects: List<Effect<Action>>,
            outputs: List<Output>,
        ): Transition<State, Action, Output> = Transition(state, effects, outputs)
    }
}

public fun <State, Action, Output> transition(
    state: State,
): Transition<State, Action, Output> = Transition.create(state, emptyList(), emptyList())
