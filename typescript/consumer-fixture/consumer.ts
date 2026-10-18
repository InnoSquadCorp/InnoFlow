import { createElement } from "react";
import { createStore, defineFlow, transition } from "@innosquad/inno-flow";
import { createFlowContext } from "@innosquad/inno-flow-react";
import { TestStore } from "@innosquad/inno-flow-testing";
type State = { count: number };
type Action = { delta: number };
const definition = defineFlow<State, Action>({ initialState: { count: 0 }, reducer: (state, action) => transition({ count: state.count + action.delta }) });
const store = createStore(definition);
store.send({ delta: 1 });
// @ts-expect-error An external consumer must retain action payload checking.
store.send({ unknownAction: 1 });
const flow = createFlowContext<State, Action, never>();
createElement(flow.Provider, { store }, null);
const test = new TestStore(definition);
await test.send({ delta: 1 }, { count: 1 });
// @ts-expect-error Expected state must retain its declared shape.
await test.send({ delta: 1 }, { unknownState: 1 });
