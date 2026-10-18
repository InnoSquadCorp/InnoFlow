import { readFile } from "node:fs/promises";
import { describe, expect, it } from "vitest";
import {
  Effect,
  createStore,
  defineFlow,
  effectId,
  transition,
  type Reducer,
} from "./index.js";

type CounterState = Readonly<{ count: number }>;
type CounterAction =
  | Readonly<{ type: "increment" }>
  | Readonly<{ type: "decrement" }>
  | Readonly<{ type: "reset" }>
  | Readonly<{ type: "incrementLater" }>;

const reducer: Reducer<CounterState, CounterAction, never> = (state, action) => {
  switch (action.type) {
    case "increment":
      return transition({ count: state.count + 1 });
    case "decrement":
      return transition({ count: state.count - 1 });
    case "reset":
      return transition({ count: 0 });
    case "incrementLater":
      return transition(state, {
        effects: [Effect.send<CounterAction>({ type: "increment" })],
      });
  }
};

describe("FlowStore", () => {
  it("waits for descendant actions", async () => {
    const store = createStore(
      defineFlow({ initialState: { count: 0 }, reducer }),
    );

    await store.send({ type: "incrementLater" }).finished();

    expect(store.getState()).toEqual({ count: 1 });
  });

  it("keeps instrumentation failures outside runtime semantics", async () => {
    const store = createStore(
      defineFlow({ initialState: { count: 0 }, reducer }),
      {
        instrumentation: {
          actionReduced: () => {
            throw new Error("observer failure");
          },
          observerFailed: () => {
            throw new Error("secondary observer failure");
          },
        },
      },
    );

    await store.send({ type: "increment" }).finished();

    expect(store.getState()).toEqual({ count: 1 });
  });

  it("cancels only the requested latest-wins effect", async () => {
    type SearchState = Readonly<{ value: string }>;
    type SearchAction =
      | Readonly<{ type: "search"; value: string }>
      | Readonly<{ type: "loaded"; value: string }>;
    const pending = new Map<string, (value: string) => void>();
    const search = effectId("search");
    const flow = defineFlow<SearchState, SearchAction>({
      initialState: { value: "" },
      reducer: (state, action) => {
        if (action.type === "loaded") return transition({ value: action.value });
        return transition(state, {
          effects: [
            Effect.run<SearchAction>(
              async ({ send, signal }) => {
                const value = await new Promise<string>((resolve) => {
                  pending.set(action.value, resolve);
                });
                if (!signal.aborted) send({ type: "loaded", value });
              },
              { id: search, cancelInFlight: true },
            ),
          ],
        });
      },
    });
    const store = createStore(flow);

    const first = store.send({ type: "search", value: "first" });
    await Promise.resolve();
    const second = store.send({ type: "search", value: "second" });
    await Promise.resolve();
    pending.get("second")?.("fresh");
    await second.finished();
    await first.finished();

    expect(store.getState()).toEqual({ value: "fresh" });
    expect(first.isCompleted).toBe(true);
  });

  it("passes the shared counter conformance fixture", async () => {
    const fixture = JSON.parse(
      await readFile(new URL("../../../../contracts/conformance/counter-v1.json", import.meta.url), "utf8"),
    ) as {
      readonly scenarios: readonly {
        readonly name: string;
        readonly initial: number;
        readonly actions: readonly ("increment" | "decrement" | "reset")[];
        readonly expected: number;
      }[];
    };

    for (const scenario of fixture.scenarios) {
      const store = createStore(
        defineFlow({ initialState: { count: scenario.initial }, reducer }),
      );
      for (const type of scenario.actions) {
        await store.send({ type }).finished();
      }
      expect(store.getState().count, scenario.name).toBe(scenario.expected);
    }
  });

  it("isolates reducer failures and keeps the store usable", async () => {
    const store = createStore(
      defineFlow<number, "fail" | "increment">({
        initialState: 0,
        reducer: (state, action) => {
          if (action === "fail") throw new Error("expected reducer failure");
          return transition(state + 1);
        },
      }),
    );

    await expect(store.send("fail").finished()).rejects.toThrow(
      "expected reducer failure",
    );
    await store.send("increment").finished();

    expect(store.getState()).toBe(1);
  });

  it("reports lossless FIFO queue metrics for descendant bursts", async () => {
    type BurstAction =
      | Readonly<{ type: "start"; count: number }>
      | Readonly<{ type: "increment" }>;
    const drains: number[] = [];
    const store = createStore(
      defineFlow<number, BurstAction>({
        initialState: 0,
        reducer: (state, action) =>
          action.type === "start"
            ? transition(state, {
                effects: Array.from({ length: action.count }, () =>
                  Effect.send<BurstAction>({ type: "increment" }),
                ),
              })
            : transition(state + 1),
      }),
      {
        instrumentation: {
          actionQueueDrained: ({ processedActionCount }) =>
            drains.push(processedActionCount),
        },
      },
    );

    await store.send({ type: "start", count: 2_000 }).finished();

    expect(store.getState()).toBe(2_000);
    expect(drains.reduce((sum, value) => sum + value, 0)).toBe(2_001);
  });

  it("rejects an effect failure without poisoning later dispatches", async () => {
    const store = createStore(
      defineFlow<number, "fail" | "increment">({
        initialState: 0,
        reducer: (state, action) =>
          action === "fail"
            ? transition(state, {
                effects: [
                  Effect.run(async () => {
                    throw new Error("expected effect failure");
                  }),
                ],
              })
            : transition(state + 1),
      }),
    );

    await expect(store.send("fail").finished()).rejects.toThrow(
      "expected effect failure",
    );
    await store.send("increment").finished();

    expect(store.getState()).toBe(1);
  });

  it("delivers typed outputs only while a listener is subscribed", async () => {
    const values: number[] = [];
    const store = createStore(
      defineFlow<number, number, number>({
        initialState: 0,
        reducer: (state, action) =>
          transition(state + action, { outputs: [action] }),
      }),
    );
    const unsubscribe = store.subscribeOutput((value) => values.push(value));

    await store.send(1).finished();
    await store.send(2).finished();
    unsubscribe();
    await store.send(3).finished();

    expect(values).toEqual([1, 2]);
  });

  it("close cancels active tasks and rejects later sends", async () => {
    const store = createStore(
      defineFlow<number, "start">({
        initialState: 0,
        reducer: (state) =>
          transition(state, {
            effects: [
              Effect.run(
                ({ signal }) =>
                  new Promise<void>((resolve) => {
                    signal.addEventListener("abort", () => resolve(), {
                      once: true,
                    });
                  }),
              ),
            ],
          }),
      }),
    );
    const task = store.send("start");
    await Promise.resolve();

    store.close();
    await task.finished();

    expect(task.isCompleted).toBe(true);
    expect(() => store.send("start")).toThrow("FlowStore is closed");
  });
});
