export type EffectId = string & { readonly __effectId: unique symbol };

export function effectId(value: string): EffectId {
  return value as EffectId;
}

export interface EffectContext<Action> {
  readonly signal: AbortSignal;
  send(action: Action): void;
}

interface RunEffect<Action> {
  readonly kind: "run";
  readonly id: EffectId | undefined;
  readonly cancelInFlight: boolean;
  readonly operation: (context: EffectContext<Action>) => void | Promise<void>;
}

interface CancelEffect {
  readonly kind: "cancel";
  readonly id: EffectId;
}

export type Effect<Action> = RunEffect<Action> | CancelEffect;

export const Effect = {
  run<Action>(
    operation: (context: EffectContext<Action>) => void | Promise<void>,
    options: {
      readonly id?: EffectId;
      readonly cancelInFlight?: boolean;
    } = {},
  ): Effect<Action> {
    return {
      kind: "run",
      id: options.id,
      cancelInFlight: options.cancelInFlight ?? false,
      operation,
    };
  },

  send<Action>(action: Action): Effect<Action> {
    return Effect.run(({ send }) => send(action));
  },

  cancel<Action>(id: EffectId): Effect<Action> {
    return { kind: "cancel", id };
  },

  map<Action, MappedAction>(
    effect: Effect<Action>,
    transform: (action: Action) => MappedAction,
  ): Effect<MappedAction> {
    if (effect.kind === "cancel") return Effect.cancel(effect.id);
    const options =
      effect.id === undefined
        ? { cancelInFlight: effect.cancelInFlight }
        : { id: effect.id, cancelInFlight: effect.cancelInFlight };
    return Effect.run(
      ({ send, signal }) =>
        effect.operation({
          signal,
          send: (action) => send(transform(action)),
        }),
      options,
    );
  },
} as const;

export interface Transition<State, Action, Output> {
  readonly state: State;
  readonly effects: readonly Effect<Action>[];
  readonly outputs: readonly Output[];
}

export function transition<State, Action = never, Output = never>(
  state: State,
  options: {
    readonly effects?: readonly Effect<Action>[];
    readonly outputs?: readonly Output[];
  } = {},
): Transition<State, Action, Output> {
  return {
    state,
    effects: options.effects ?? [],
    outputs: options.outputs ?? [],
  };
}

export type Reducer<State, Action, Output> = (
  state: State,
  action: Action,
) => Transition<State, Action, Output>;

export interface FlowDefinition<State, Action, Output> {
  readonly initialState: State;
  readonly reducer: Reducer<State, Action, Output>;
}

export function defineFlow<State, Action, Output = never>(
  definition: FlowDefinition<State, Action, Output>,
): FlowDefinition<State, Action, Output> {
  return definition;
}
