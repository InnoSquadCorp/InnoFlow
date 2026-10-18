import {
  Effect,
  transition,
  type Reducer,
} from "./model.js";

export function combineReducers<State, Action, Output>(
  ...reducers: readonly Reducer<State, Action, Output>[]
): Reducer<State, Action, Output> {
  return (initialState, action) => {
    let state = initialState;
    const effects = [];
    const outputs = [];

    for (const reducer of reducers) {
      const next = reducer(state, action);
      state = next.state;
      effects.push(...next.effects);
      outputs.push(...next.outputs);
    }

    return transition(state, { effects, outputs });
  };
}

export function scopeReducer<
  ParentState,
  ParentAction,
  ParentOutput,
  ChildState,
  ChildAction,
  ChildOutput,
>(options: {
  readonly reducer: Reducer<ChildState, ChildAction, ChildOutput>;
  readonly childState: (state: ParentState) => ChildState;
  readonly replaceChildState: (
    state: ParentState,
    childState: ChildState,
  ) => ParentState;
  readonly childAction: (action: ParentAction) => ChildAction | undefined;
  readonly parentAction: (action: ChildAction) => ParentAction;
  readonly parentOutput: (output: ChildOutput) => ParentOutput | undefined;
}): Reducer<ParentState, ParentAction, ParentOutput> {
  return (parentState, action) => {
    const childAction = options.childAction(action);
    if (childAction === undefined) return transition(parentState);

    const next = options.reducer(options.childState(parentState), childAction);
    return transition(
      options.replaceChildState(parentState, next.state),
      {
        effects: next.effects.map((effect) =>
          Effect.map(effect, options.parentAction),
        ),
        outputs: next.outputs
          .map(options.parentOutput)
          .filter((output): output is ParentOutput => output !== undefined),
      },
    );
  };
}
