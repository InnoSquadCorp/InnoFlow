import { readFile } from "node:fs/promises";
import { expect, it } from "vitest";
import { Effect, createStore, defineFlow, transition, type FlowTask } from "./index.js";

it("executes shared failure, cancellation, output, close and recovery fixtures", async () => {
  const fixture = JSON.parse(await readFile(new URL("../../../../contracts/conformance/runtime-v1.json", import.meta.url), "utf8")) as {
    scenarios: { name: string; initial: number; steps: string[]; state: number; outputs: number[]; failures: number }[];
  };
  for (const scenario of fixture.scenarios) {
    let release = () => {};
    const gate = new Promise<void>(resolve => { release = resolve; });
    const outputs: number[] = [];
    let failures = 0;
    let delayed: FlowTask | undefined;
    const store = createStore(defineFlow<number, string, number>({ initialState: scenario.initial,
      reducer: (state, action) => {
        switch (action) {
          case "increment": return transition(state + 1);
          case "later": return transition(state, { effects: [Effect.send("increment")] });
          case "emit": return transition(state, { outputs: [state] });
          case "failReducer": throw new Error("fixture reducer failure");
          case "failEffect": return transition(state, { effects: [Effect.run(() => { throw new Error("fixture effect failure"); })] });
          case "startDelayed": return transition(state, { effects: [Effect.run(async ({ send }) => { await gate; send("increment"); })] });
          default: throw new Error(`Unknown fixture action ${action}`);
        }
      },
    }));
    store.subscribeOutput(value => outputs.push(value));
    try {
      for (const step of scenario.steps) {
        try {
          if (step === "cancel") delayed?.cancel();
          else if (step === "release") { release(); await Promise.resolve(); }
          else if (step === "close") store.close();
          else if (step === "startDelayed") { delayed = store.send(step); await Promise.resolve(); }
          else await store.send(step).finished();
        } catch { failures += 1; }
      }
      await store.finish();
      expect(store.getState(), scenario.name).toBe(scenario.state);
      expect(outputs, scenario.name).toEqual(scenario.outputs);
      expect(failures, scenario.name).toBe(scenario.failures);
    } finally { release(); store.close(); }
  }
});
