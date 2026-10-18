import {
  createStore,
  type FlowDefinition,
  type FlowInstrumentation,
  type FlowStore,
} from "@innosquad/inno-flow";
import { dequal } from "dequal";

function format(value: unknown): string {
  const seen = new WeakSet<object>();
  return JSON.stringify(value, (_key, item: unknown) => {
    if (typeof item === "bigint") return `${item}n`;
    if (typeof item === "object" && item !== null) {
      if (seen.has(item)) return "[Circular]";
      seen.add(item);
    }
    return item;
  }) ?? String(value);
}

export interface TestStoreOptions<State, Action, Output> {
  readonly stateEquals?: (lhs: State, rhs: State) => boolean;
  readonly actionEquals?: (lhs: Action, rhs: Action) => boolean;
  readonly outputEquals?: (lhs: Output, rhs: Output) => boolean;
}

export class TestStore<State, Action, Output> {
  readonly store: FlowStore<State, Action, Output>;
  private readonly actions: Action[] = [];
  private readonly outputs: Output[] = [];
  private readonly stateEquals: (lhs: State, rhs: State) => boolean;
  private readonly actionEquals: (lhs: Action, rhs: Action) => boolean;
  private readonly outputEquals: (lhs: Output, rhs: Output) => boolean;

  constructor(
    definition: FlowDefinition<State, Action, Output>,
    options: TestStoreOptions<State, Action, Output> = {},
  ) {
    this.stateEquals = options.stateEquals ?? dequal;
    this.actionEquals = options.actionEquals ?? dequal;
    this.outputEquals = options.outputEquals ?? dequal;

    const instrumentation: FlowInstrumentation<State, Action, Output> = {
      actionReduced: ({ action }) => this.actions.push(action),
      outputEmitted: (output) => this.outputs.push(output),
    };
    this.store = createStore(definition, { instrumentation });
  }

  get state(): State {
    return this.store.getState();
  }

  async send(action: Action, ...expected: [] | [State]): Promise<void> {
    await this.store.send(action).finished();
    if (
      expected.length === 1 &&
      !this.stateEquals(expected[0], this.store.getState())
    ) {
      throw new Error(
        `State mismatch. Expected <${format(expected[0])}>, actual <${format(this.store.getState())}>`,
      );
    }
  }

  async finish(): Promise<void> {
    await this.store.finish();
  }

  assertActions(expected: readonly Action[]): void {
    this.assertSequence("Action", expected, this.actions, this.actionEquals);
  }

  assertOutputs(expected: readonly Output[]): void {
    this.assertSequence("Output", expected, this.outputs, this.outputEquals);
  }

  resetTrace(): void {
    this.actions.length = 0;
    this.outputs.length = 0;
  }

  close(): void {
    this.store.close();
  }

  private assertSequence<Value>(
    label: string,
    expected: readonly Value[],
    actual: readonly Value[],
    equals: (lhs: Value, rhs: Value) => boolean,
  ): void {
    const matches =
      expected.length === actual.length &&
      expected.every((value, index) => {
        // Equal lengths establish this index even when Value includes undefined.
        return equals(value, actual[index] as Value);
      });
    if (!matches) {
      throw new Error(
        `${label} sequence mismatch. Expected <${format(expected)}>, actual <${format(actual)}>`,
      );
    }
  }
}
