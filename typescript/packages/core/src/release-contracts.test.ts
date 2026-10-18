import { describe, expect, it } from "vitest";
import { Effect, FlowQueueFullError, createStore, defineFlow, effectId, transition, type FlowTask } from "./index.js";

describe("1.0 runtime contracts", () => {
  it("does not start an effect cancelled before its first microtask", async () => {
    let runs = 0;
    const store = createStore(defineFlow<number, null>({ initialState: 0,
      reducer: state => transition(state + 1, { effects: [Effect.run(() => { runs += 1; })] }),
    }));
    const task = store.send(null);
    task.cancel();
    await task.finished();
    await Promise.resolve();
    expect(runs).toBe(0);
    expect(store.getState()).toBe(1);
    store.close();
  });

  it("cancels all same-ID runs without touching another ID", async () => {
    const shared = effectId("shared");
    const other = effectId("other");
    const signals: AbortSignal[] = [];
    const store = createStore(defineFlow<number, "start" | "other" | "cancel">({ initialState: 0,
      reducer: (state, action) => transition(state, { effects: [action === "cancel"
        ? Effect.cancel(shared)
        : Effect.run(({ signal }) => new Promise<void>(resolve => {
            signals.push(signal);
            signal.addEventListener("abort", () => resolve(), { once: true });
          }), { id: action === "other" ? other : shared })] }),
    }));
    const first = store.send("start");
    const second = store.send("start");
    const independent = store.send("other");
    await Promise.resolve();
    await store.send("cancel").finished();
    await Promise.all([first.finished(), second.finished()]);
    expect(signals.map(signal => signal.aborted)).toEqual([true, true, false]);
    expect(independent.isCompleted).toBe(false);
    independent.cancel();
    await independent.finished();
    store.close();
  });

  it("suppresses outputs and effects when a state observer closes the store", async () => {
    let runs = 0;
    const outputs: string[] = [];
    const store = createStore(defineFlow<number, null, string>({ initialState: 0,
      reducer: state => transition(state + 1, { outputs: ["late"], effects: [Effect.run(() => { runs += 1; })] }),
    }));
    store.subscribeOutput(value => outputs.push(value));
    store.subscribe(() => store.close());
    await store.send(null).finished();
    await Promise.resolve();
    expect(store.getState()).toBe(1);
    expect(outputs).toEqual([]);
    expect(runs).toBe(0);
  });

  it("rejects bounded reentrant overflow and then recovers", async () => {
    const nested: FlowTask[] = [];
    const store = createStore(defineFlow<number, null>({ initialState: 0, reducer: state => transition(state + 1) }), { actionCapacity: 2 });
    const unsubscribe = store.subscribe(() => {
      unsubscribe();
      for (let i = 0; i < 10; i += 1) nested.push(store.send(null));
    });
    await store.send(null).finished();
    const results = await Promise.allSettled(nested.map(task => task.finished()));
    expect(results.filter(result => result.status === "fulfilled")).toHaveLength(2);
    for (const result of results.slice(2)) {
      expect(result.status).toBe("rejected");
      if (result.status === "rejected") expect(result.reason).toBeInstanceOf(FlowQueueFullError);
    }
    expect(store.getState()).toBe(3);
    await store.send(null).finished();
    expect(store.getState()).toBe(4);
    store.close();
  });

  it("drains a long reentrant chain without recursive reducer calls", async () => {
    const store = createStore(defineFlow<number, null>({ initialState: 0, reducer: state => transition(state + 1) }), { actionCapacity: 1 });
    store.subscribe(() => { if (store.getState() < 20_000) store.send(null); });
    await store.send(null).finished();
    await store.finish();
    expect(store.getState()).toBe(20_000);
    store.close();
  });

  it("rejects invalid capacities", () => {
    const flow = defineFlow<number, null>({ initialState: 0, reducer: state => transition(state) });
    for (const actionCapacity of [0, -1, NaN, Infinity, 1.5]) {
      expect(() => createStore(flow, { actionCapacity })).toThrow(RangeError);
    }
  });

  it("ignores late sends and errors from uncooperative cancelled work", async () => {
    let resume: () => void = () => {};
    const store = createStore(defineFlow<number, "start" | "late" | "retry">({ initialState: 0,
      reducer: (state, action) => action === "start" ? transition(state, { effects: [Effect.run(async ({ send }) => {
        await new Promise<void>(resolve => { resume = resolve; });
        send("late");
        throw new Error("cancelled late failure");
      })] }) : transition(state + 1),
    }));
    const task = store.send("start");
    await Promise.resolve();
    task.cancel();
    resume();
    await task.finished();
    await store.send("retry").finished();
    await Promise.resolve();
    expect(store.getState()).toBe(1);
    store.close();
  });
});
