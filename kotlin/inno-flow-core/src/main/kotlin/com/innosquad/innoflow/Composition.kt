package com.innosquad.innoflow

public fun <State, Action, Output> combineReducers(
    vararg reducers: Reducer<State, Action, Output>,
): Reducer<State, Action, Output> = Reducer { initialState, action ->
    var state = initialState
    val effects = mutableListOf<Effect<Action>>()
    val outputs = mutableListOf<Output>()

    reducers.forEach { reducer ->
        val transition = reducer.reduce(state, action)
        state = transition.state
        effects += transition.effects
        outputs += transition.outputs
    }

    Transition.create(state, effects, outputs)
}

public fun <ParentState, ParentAction, ParentOutput, ChildState, ChildAction, ChildOutput>
    Reducer<ChildState, ChildAction, ChildOutput>.scope(
    childState: (ParentState) -> ChildState,
    replaceChildState: (ParentState, ChildState) -> ParentState,
    childAction: (ParentAction) -> ChildAction?,
    parentAction: (ChildAction) -> ParentAction,
    parentOutput: (ChildOutput) -> ParentOutput?,
): Reducer<ParentState, ParentAction, ParentOutput> = Reducer { parentState, action ->
    val localAction = childAction(action)
        ?: return@Reducer transition(parentState)
    val local = reduce(childState(parentState), localAction)

    Transition.create(
        state = replaceChildState(parentState, local.state),
        effects = local.effects.map { it.map(parentAction) },
        outputs = local.outputs.mapNotNull(parentOutput),
    )
}
