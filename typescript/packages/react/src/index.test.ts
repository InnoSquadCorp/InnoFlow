// @vitest-environment jsdom

import { StrictMode, createElement } from "react";
import { renderToString } from "react-dom/server";
import { hydrateRoot, type Root } from "react-dom/client";
import { act, cleanup, render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";
import { createStore, defineFlow, transition } from "@innosquad/inno-flow";
import { createFlowContext, useFlowSelector, useFlowState } from "./index.js";

describe("React adapter", () => {
  it("hydrates the serialized initial snapshot before adopting newer client state", async () => {
    const flow = defineFlow<{ count: number }, null>({ initialState: { count: 7 }, reducer: state => transition({ count: state.count + 1 }) });
    const server = createStore(flow);
    const client = createStore({ ...flow, initialState: JSON.parse(JSON.stringify(server.getState())) as { count: number } });
    function Counter({ store }: { store: typeof server }) { return createElement("span", null, useFlowState(store).count); }
    const container = document.createElement("div");
    container.innerHTML = renderToString(createElement(Counter, { store: server }));
    document.body.appendChild(container);
    await client.send(null).finished();
    const errors: unknown[] = [];
    let root: Root | undefined;
    await act(async () => { root = hydrateRoot(container, createElement(Counter, { store: client }), { onRecoverableError: error => errors.push(error) }); });
    expect(container.textContent).toBe("8");
    expect(errors).toEqual([]);
    await act(async () => { root?.unmount(); });
    container.remove();
    server.close(); client.close();
  });

  it("recomputes when equality changes while the state and selector stay the same", async () => {
    const store = createStore(defineFlow<{ count: number }, null>({ initialState: { count: 1 }, reducer: state => transition({ count: state.count + 1 }) }));
    const select = (state: { count: number }) => state.count;
    const same = () => true;
    function Counter({ equals }: { equals: (a: number, b: number) => boolean }) { return createElement("span", null, useFlowSelector(store, select, equals)); }
    const view = render(createElement(Counter, { equals: same }));
    await act(async () => store.send(null).finished());
    expect(view.container.textContent).toBe("1");
    view.rerender(createElement(Counter, { equals: Object.is }));
    expect(view.container.textContent).toBe("2");
    view.unmount(); store.close();
  });

  it("updates captured selector inputs and accepts undefined selections", () => {
    const store = createStore(defineFlow<{ count: number }, null>({ initialState: { count: 2 }, reducer: state => transition(state) }));
    function Counter({ multiplier }: { multiplier: number | undefined }) {
      const value = useFlowSelector(store, state => multiplier === undefined ? undefined : state.count * multiplier);
      return createElement("span", null, value ?? "none");
    }
    const view = render(createElement(Counter, { multiplier: 2 }));
    expect(view.container.textContent).toBe("4");
    view.rerender(createElement(Counter, { multiplier: 5 }));
    expect(view.container.textContent).toBe("10");
    view.rerender(createElement(Counter, { multiplier: undefined }));
    expect(view.container.textContent).toBe("none");
    view.unmount(); store.close();
  });

  it("releases StrictMode subscriptions on unmount", () => {
    const store = createStore(defineFlow<number, null>({ initialState: 1, reducer: state => transition(state) }));
    let active = 0;
    const subscribe = store.subscribe;
    store.subscribe = listener => { active += 1; const off = subscribe(listener); return () => { active -= 1; off(); }; };
    function Counter() { return createElement("span", null, useFlowState(store)); }
    const view = render(createElement(StrictMode, null, createElement(Counter)));
    expect(active).toBe(1);
    view.unmount();
    expect(active).toBe(0);
    store.close();
  });
  it("reads the store through a typed provider", () => {
    type State = Readonly<{ count: number }>;
    type Action = Readonly<{ type: "increment" }>;
    const store = createStore(
      defineFlow<State, Action>({
        initialState: { count: 7 },
        reducer: (state) => transition({ count: state.count + 1 }),
      }),
    );
    const flow = createFlowContext<State, Action, never>();

    function Counter() {
      const count = flow.useSelector((state) => state.count);
      return createElement("span", null, count);
    }

    const html = renderToString(
      createElement(flow.Provider, { store }, createElement(Counter)),
    );

    expect(html).toContain(">7</span>");
  });

  it("rerenders a selector only when its selected value changes", async () => {
    type State = Readonly<{ count: number; ignored: number }>;
    type Action = Readonly<{ type: "increment" | "touchIgnored" }>;
    const store = createStore(
      defineFlow<State, Action>({
        initialState: { count: 0, ignored: 0 },
        reducer: (state, action) =>
          action.type === "increment"
            ? transition({ ...state, count: state.count + 1 })
            : transition({ ...state, ignored: state.ignored + 1 }),
      }),
    );
    let renders = 0;

    function Counter() {
      renders += 1;
      const count = useFlowSelector(store, (state) => state.count);
      return createElement("span", null, count);
    }

    const view = render(createElement(Counter));
    expect(renders).toBe(1);

    await act(async () => store.send({ type: "touchIgnored" }).finished());
    expect(renders).toBe(1);

    await act(async () => store.send({ type: "increment" }).finished());
    expect(renders).toBe(2);
    expect(screen.getByText("1")).toBeTruthy();
    view.unmount();
    store.close();
  });

  it("supports StrictMode and provider store replacement", async () => {
    type State = Readonly<{ count: number }>;
    type Action = Readonly<{ type: "increment" }>;
    const first = createStore(
      defineFlow<State, Action>({
        initialState: { count: 1 },
        reducer: (state) => transition({ count: state.count + 1 }),
      }),
    );
    const second = createStore(
      defineFlow<State, Action>({
        initialState: { count: 9 },
        reducer: (state) => transition({ count: state.count + 1 }),
      }),
    );
    const flow = createFlowContext<State, Action, never>();

    function Counter() {
      return createElement("span", null, flow.useSelector((state) => state.count));
    }

    const view = render(
      createElement(
        StrictMode,
        null,
        createElement(flow.Provider, { store: first }, createElement(Counter)),
      ),
    );
    expect(screen.getByText("1")).toBeTruthy();

    view.rerender(
      createElement(
        StrictMode,
        null,
        createElement(flow.Provider, { store: second }, createElement(Counter)),
      ),
    );
    expect(screen.getByText("9")).toBeTruthy();

    await act(async () => second.send({ type: "increment" }).finished());
    expect(screen.getByText("10")).toBeTruthy();
    view.unmount();
    first.close();
    second.close();
    cleanup();
  });
});
