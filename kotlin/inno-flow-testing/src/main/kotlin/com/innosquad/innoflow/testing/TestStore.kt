package com.innosquad.innoflow.testing

import com.innosquad.innoflow.FlowInstrumentation
import com.innosquad.innoflow.FlowStore
import com.innosquad.innoflow.Reducer
import kotlinx.coroutines.CoroutineScope

public class TestStore<State, Action, Output>(
    initialState: State,
    reducer: Reducer<State, Action, Output>,
    scope: CoroutineScope,
    private val stateEquals: (State, State) -> Boolean = { lhs, rhs -> lhs == rhs },
    private val actionEquals: (Action, Action) -> Boolean = { lhs, rhs -> lhs == rhs },
    private val outputEquals: (Output, Output) -> Boolean = { lhs, rhs -> lhs == rhs },
) : AutoCloseable {
    private val recordedActions = mutableListOf<Action>()
    private val recordedOutputs = mutableListOf<Output>()

    private val store = FlowStore(
        initialState = initialState,
        reducer = reducer,
        scope = scope,
        instrumentation = object : FlowInstrumentation<State, Action, Output> {
            override fun actionReduced(action: Action, oldState: State, newState: State) {
                recordedActions += action
            }

            override fun outputEmitted(output: Output) {
                recordedOutputs += output
            }
        },
    )

    public val state: State
        get() = store.states.value

    public suspend fun send(action: Action, expectedState: State) {
        store.send(action).finish()
        if (!stateEquals(expectedState, state)) {
            throw AssertionError("State mismatch. Expected <$expectedState>, actual <$state>")
        }
    }

    public suspend fun send(action: Action, assertState: (State) -> Unit = {}) {
        store.send(action).finish()
        assertState(state)
    }

    public suspend fun finish() {
        store.finish()
    }

    public fun assertActions(expected: List<Action>) {
        assertSequence("Action", expected, recordedActions, actionEquals)
    }

    public fun assertOutputs(expected: List<Output>) {
        assertSequence("Output", expected, recordedOutputs, outputEquals)
    }

    public fun resetTrace() {
        recordedActions.clear()
        recordedOutputs.clear()
    }

    override fun close() {
        store.close()
    }

    private fun <Value> assertSequence(
        label: String,
        expected: List<Value>,
        actual: List<Value>,
        equals: (Value, Value) -> Boolean,
    ) {
        val matches = expected.size == actual.size &&
            expected.zip(actual).all { (lhs, rhs) -> equals(lhs, rhs) }
        if (!matches) {
            throw AssertionError("$label sequence mismatch. Expected <$expected>, actual <$actual>")
        }
    }
}
