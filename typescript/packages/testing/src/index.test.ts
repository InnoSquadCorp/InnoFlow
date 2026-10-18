import { describe, expect, it } from "vitest";
import { Effect, defineFlow, transition } from "@innosquad/inno-flow";
import { TestStore } from "./index.js";

describe("TestStore", () => {
  it("records root and descendant actions", async () => {
    type Action = "start" | "finish";
    const testStore = new TestStore(
      defineFlow<number, Action>({
        initialState: 0,
        reducer: (state, action) =>
          action === "start"
            ? transition(state, { effects: [Effect.send<Action>("finish")] })
            : transition(state + 1),
      }),
    );

    await testStore.send("start", 1);

    testStore.assertActions(["start", "finish"]);
    expect(testStore.state).toBe(1);
  });

  it("compares nested object state, actions and outputs structurally", async () => {
    const store = new TestStore(defineFlow<{ count: number; nested: { tags: string[] } }, { count: number }, { done: number }>({
      initialState: { count: 0, nested: { tags: ["test"] } },
      reducer: (state, action) => transition({ ...state, count: action.count }, { outputs: [{ done: action.count }] }),
    }));
    await store.send({ count: 3 }, { count: 3, nested: { tags: ["test"] } });
    store.assertActions([{ count: 3 }]);
    store.assertOutputs([{ done: 3 }]);
    await expect(store.send({ count: 4 }, { count: 5, nested: { tags: ["test"] } })).rejects.toThrow('"count":5');
    store.close();
  });

  it("asserts undefined state and undefined trace values", async () => {
    const store = new TestStore(defineFlow<number | undefined, undefined, undefined>({
      initialState: 1,
      reducer: () => transition(undefined, { outputs: [undefined] }),
    }));
    await store.send(undefined, undefined);
    store.assertActions([undefined]);
    store.assertOutputs([undefined]);
    store.close();
    const mismatch = new TestStore(defineFlow<number | undefined, null>({ initialState: 1, reducer: state => transition(state) }));
    await expect(mismatch.send(null, undefined)).rejects.toThrow("State mismatch");
    mismatch.close();
  });

  it("supports dates, maps, sets and custom comparators", async () => {
    const initialState = { date: new Date(0), map: new Map([[1, "one"]]), set: new Set([2, 3]) };
    const store = new TestStore(defineFlow<typeof initialState, null>({ initialState, reducer: state => transition(state) }));
    await store.send(null, { date: new Date(0), map: new Map([[1, "one"]]), set: new Set([3, 2]) });
    store.close();
    const custom = new TestStore(defineFlow<{ value: number }, null>({ initialState: { value: 1 }, reducer: state => transition(state) }), {
      stateEquals: (lhs, rhs) => Math.floor(lhs.value) === Math.floor(rhs.value),
    });
    await custom.send(null, { value: 1.9 });
    custom.close();
  });
});
