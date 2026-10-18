package com.innosquad.innoflow

@Target(AnnotationTarget.CLASS)
@Retention(AnnotationRetention.SOURCE)
public annotation class InnoFlow

public interface FlowFeature<State, Action, Output> {
    public val initialState: State
    public val reducer: Reducer<State, Action, Output>
}

public fun interface Reducer<State, Action, Output> {
    public fun reduce(state: State, action: Action): Transition<State, Action, Output>
}
