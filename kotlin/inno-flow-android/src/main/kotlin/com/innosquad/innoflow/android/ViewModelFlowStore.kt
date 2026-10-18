package com.innosquad.innoflow.android

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.innosquad.innoflow.FlowFeature
import com.innosquad.innoflow.FlowInstrumentation
import com.innosquad.innoflow.FlowStore

/** Registers a store as a resource owned by this ViewModel. */
public fun <State, Action, Output> ViewModel.ownFlowStore(
    store: FlowStore<State, Action, Output>,
): FlowStore<State, Action, Output> {
    addCloseable(store)
    return store
}

/** Creates a compiler-plugin-free store and closes it when this ViewModel is cleared. */
public fun <State, Action, Output> ViewModel.createFlowStore(
    feature: FlowFeature<State, Action, Output>,
    instrumentation: FlowInstrumentation<State, Action, Output> = FlowInstrumentation.none(),
    actionCapacity: Int = 1024,
): FlowStore<State, Action, Output> = ownFlowStore(
    FlowStore(
        initialState = feature.initialState,
        reducer = feature.reducer,
        scope = viewModelScope,
        instrumentation = instrumentation,
        actionCapacity = actionCapacity,
    ),
)
