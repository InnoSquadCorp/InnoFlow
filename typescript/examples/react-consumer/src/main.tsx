import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { createStore, defineFlow, transition } from "@innosquad/inno-flow";
import { createFlowContext } from "@innosquad/inno-flow-react";

type CounterState = Readonly<{ count: number }>;
type CounterAction = Readonly<{ type: "increment" | "decrement" }>;

const counter = defineFlow<CounterState, CounterAction>({
  initialState: { count: 0 },
  reducer: (state, action) =>
    transition({
      count: state.count + (action.type === "increment" ? 1 : -1),
    }),
});
const store = createStore(counter);
const flow = createFlowContext<CounterState, CounterAction, never>();

function Counter() {
  const count = flow.useSelector((state) => state.count);
  const currentStore = flow.useStore();
  return (
    <main>
      <h1>InnoFlow React Consumer</h1>
      <output aria-live="polite">Count: {count}</output>
      <button onClick={() => currentStore.send({ type: "decrement" })}>Decrease</button>
      <button onClick={() => currentStore.send({ type: "increment" })}>Increase</button>
    </main>
  );
}

const root = document.getElementById("root");
if (root === null) throw new Error("Missing root element");

createRoot(root).render(
  <StrictMode>
    <flow.Provider store={store}>
      <Counter />
    </flow.Provider>
  </StrictMode>,
);
