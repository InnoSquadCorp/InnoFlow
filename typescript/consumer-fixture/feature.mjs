import { createElement } from "react";
import { createStore, defineFlow, transition } from "@innosquad/inno-flow";
import { createFlowContext } from "@innosquad/inno-flow-react";

export const flow = createFlowContext();
export function makeStore(initialState) {
  return createStore(defineFlow({ initialState, reducer: (state, action) => transition({ count: state.count + action.delta }) }));
}
export function Counter() {
  const { count } = flow.useState();
  const store = flow.useStore();
  return createElement("main", null,
    createElement("h1", null, "InnoFlow packed consumer"),
    createElement("output", { "aria-live": "polite" }, `Count: ${count}`),
    createElement("button", { onClick: () => store.send({ delta: 1 }) }, "Increase"),
    createElement("button", { onClick: () => store.send({ delta: -1 }) }, "Decrease"));
}
export function App({ store }) { return createElement(flow.Provider, { store }, createElement(Counter)); }
