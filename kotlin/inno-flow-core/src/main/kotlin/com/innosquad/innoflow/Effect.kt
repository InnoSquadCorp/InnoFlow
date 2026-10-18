package com.innosquad.innoflow

@JvmInline
public value class EffectId(public val value: String)

public interface EffectScope<Action> {
    public suspend fun send(action: Action)
}

public class Effect<Action> private constructor(
    internal val operation: Operation<Action>,
) {
    public fun <MappedAction> map(
        transform: (Action) -> MappedAction,
    ): Effect<MappedAction> = when (val current = operation) {
        is Operation.Cancel -> cancel(current.id)
        is Operation.Run -> run(current.id, current.cancelInFlight) {
            val mappedScope = this
            current.block(
                object : EffectScope<Action> {
                    override suspend fun send(action: Action) {
                        mappedScope.send(transform(action))
                    }
                },
            )
        }
    }

    public companion object {
        public fun <Action> run(
            id: EffectId? = null,
            cancelInFlight: Boolean = false,
            block: suspend EffectScope<Action>.() -> Unit,
        ): Effect<Action> = Effect(Operation.Run(id, cancelInFlight, block))

        public fun <Action> send(action: Action): Effect<Action> = run { send(action) }

        public fun <Action> cancel(id: EffectId): Effect<Action> = Effect(Operation.Cancel(id))
    }

    internal sealed interface Operation<Action> {
        class Run<Action>(
            internal val id: EffectId?,
            internal val cancelInFlight: Boolean,
            internal val block: suspend EffectScope<Action>.() -> Unit,
        ) : Operation<Action>

        class Cancel<Action>(internal val id: EffectId) : Operation<Action>
    }
}
