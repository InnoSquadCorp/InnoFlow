import {
  createContext,
  createElement,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useSyncExternalStore,
  type Context,
  type ReactNode,
} from "react";
import type { FlowStore } from "@innosquad/inno-flow";

export function useFlowState<State, Action, Output>(
  store: FlowStore<State, Action, Output>,
  getServerSnapshot: () => State = store.getInitialState,
): State {
  return useSyncExternalStore(store.subscribe, store.getState, getServerSnapshot);
}

export function useFlowSelector<State, Action, Output, Selection>(
  store: FlowStore<State, Action, Output>,
  selector: (state: State) => Selection,
  isEqual: (lhs: Selection, rhs: Selection) => boolean = Object.is,
  getServerSnapshot: () => State = store.getInitialState,
): Selection {
  const committed = useRef<{ readonly value: Selection } | undefined>(undefined);
  // Each render's selector/comparator owns its memo. Only committed results are
  // shared between render attempts, so an abandoned render cannot poison them.
  const [getSelection, getServerSelection] = useMemo(() => {
    let memo: { state: State; selection: Selection } | undefined;
    const select = (state: State): Selection => {
      if (memo !== undefined && Object.is(memo.state, state)) return memo.selection;
      const selected = selector(state);
      const previous = memo !== undefined ? { value: memo.selection } : committed.current;
      const selection = previous !== undefined && isEqual(previous.value, selected)
        ? previous.value
        : selected;
      memo = { state, selection };
      return selection;
    };
    return [() => select(store.getState()), () => select(getServerSnapshot())];
  }, [store, selector, isEqual, getServerSnapshot]);
  const selection = useSyncExternalStore(store.subscribe, getSelection, getServerSelection);
  useEffect(() => { committed.current = { value: selection }; }, [selection]);
  return selection;
}

export interface FlowReactContext<State, Action, Output> {
  readonly Provider: (props: {
    readonly store: FlowStore<State, Action, Output>;
    readonly children?: ReactNode;
  }) => ReactNode;
  readonly useStore: () => FlowStore<State, Action, Output>;
  readonly useState: () => State;
  readonly useSelector: <Selection>(
    selector: (state: State) => Selection,
    isEqual?: (lhs: Selection, rhs: Selection) => boolean,
  ) => Selection;
}

export function createFlowContext<State, Action, Output>(): FlowReactContext<
  State,
  Action,
  Output
> {
  const context: Context<FlowStore<State, Action, Output> | null> =
    createContext<FlowStore<State, Action, Output> | null>(null);

  function useStore(): FlowStore<State, Action, Output> {
    const store = useContext(context);
    if (store === null) {
      throw new Error("InnoFlow Provider is missing from the React tree");
    }
    return store;
  }

  return {
    Provider: ({ store, children }) =>
      createElement(context.Provider, { value: store }, children),
    useStore,
    useState: () => useFlowState(useStore()),
    useSelector: <Selection>(
      selector: (state: State) => Selection,
      isEqual?: (lhs: Selection, rhs: Selection) => boolean,
    ) => useFlowSelector(useStore(), selector, isEqual),
  };
}
