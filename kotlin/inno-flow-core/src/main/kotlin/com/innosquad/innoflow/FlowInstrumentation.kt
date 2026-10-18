package com.innosquad.innoflow

public interface FlowInstrumentation<State, Action, Output> {
    public fun actionQueued(action: Action, pendingActionCount: Int) {}

    public fun actionReduced(action: Action, oldState: State, newState: State) {}

    public fun outputEmitted(output: Output) {}

    public fun outputDropped(output: Output) {}

    public fun actionQueueDrained(metrics: FlowQueueMetrics) {}

    public fun effectStarted(id: EffectId?) {}

    public fun effectFinished(id: EffectId?) {}

    public fun dispatchFailed(action: Action?, error: Throwable) {}

    public companion object {
        public fun <State, Action, Output> none(): FlowInstrumentation<State, Action, Output> =
            object : FlowInstrumentation<State, Action, Output> {}
    }
}

public class FlowQueueMetrics internal constructor(
    public val processedActionCount: Int,
    public val pendingActionHighWaterMark: Int,
)
