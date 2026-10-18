import type {
  Effect,
  EffectContext,
  EffectId,
  FlowDefinition,
} from "./model.js";

export interface FlowInstrumentation<State, Action, Output> {
  actionQueued?(event: {
    readonly action: Action;
    readonly pendingActionCount: number;
  }): void;
  actionReduced?(event: {
    readonly action: Action;
    readonly oldState: State;
    readonly newState: State;
  }): void;
  outputEmitted?(output: Output): void;
  effectStarted?(id: EffectId | undefined): void;
  effectFinished?(id: EffectId | undefined): void;
  dispatchFailed?(event: {
    readonly action: Action | undefined;
    readonly error: unknown;
  }): void;
  observerFailed?(error: unknown): void;
  actionQueueDrained?(event: {
    readonly processedActionCount: number;
    readonly pendingActionHighWaterMark: number;
  }): void;
}

class DispatchContext {
  readonly controller = new AbortController();
  readonly finished: Promise<void>;
  private pending = 1;
  private completed = false;
  private readonly cancellationListeners = new Set<() => void>();
  private resolve!: () => void;
  private reject!: (error: unknown) => void;

  constructor() {
    this.finished = new Promise<void>((resolve, reject) => {
      this.resolve = resolve;
      this.reject = reject;
    });
  }

  get isCompleted(): boolean {
    return this.completed;
  }

  retain(): boolean {
    if (this.completed || this.controller.signal.aborted) return false;
    this.pending += 1;
    return true;
  }

  onCancel(listener: () => void): () => void {
    if (this.controller.signal.aborted) listener();
    else this.cancellationListeners.add(listener);
    return () => this.cancellationListeners.delete(listener);
  }

  private cancelChildren(): void {
    for (const listener of [...this.cancellationListeners]) listener();
    this.cancellationListeners.clear();
  }

  release(): void {
    if (this.pending > 0) this.pending -= 1;
    if (this.pending === 0 && !this.completed) {
      this.completed = true;
      this.resolve();
    }
  }

  fail(error: unknown): void {
    if (this.completed) return;
    this.completed = true;
    this.controller.abort(error);
    this.cancelChildren();
    this.reject(error);
  }

  cancel(): void {
    if (this.completed) return;
    this.completed = true;
    this.controller.abort();
    this.cancelChildren();
    this.resolve();
  }
}

export interface FlowTask {
  readonly isCompleted: boolean;
  finished(): Promise<void>;
  cancel(): void;
}

export class FlowQueueFullError extends Error {
  constructor(readonly capacity: number) {
    super(`FlowStore action queue is full (capacity ${capacity})`);
    this.name = "FlowQueueFullError";
  }
}

class StoreFlowTask implements FlowTask {
  constructor(private readonly context: DispatchContext) {}

  get isCompleted(): boolean {
    return this.context.isCompleted;
  }

  finished(): Promise<void> {
    return this.context.finished;
  }

  cancel(): void {
    this.context.cancel();
  }
}

type StateListener = () => void;
type OutputListener<Output> = (output: Output) => void;

interface Envelope<Action> {
  readonly action: Action;
  readonly context: DispatchContext;
}

export class FlowStore<State, Action, Output> {
  private state: State;
  private readonly queue: Envelope<Action>[] = [];
  private readonly stateListeners = new Set<StateListener>();
  private readonly outputListeners = new Set<OutputListener<Output>>();
  private readonly activeContexts = new Set<DispatchContext>();
  private readonly effectsById = new Map<EffectId, Set<AbortController>>();
  private readonly initialState: State;
  private queueHead = 0;
  private processedActionCount = 0;
  private pendingActionHighWaterMark = 0;
  private draining = false;
  private closed = false;

  constructor(
    private readonly definition: FlowDefinition<State, Action, Output>,
    private readonly instrumentation: FlowInstrumentation<State, Action, Output> = {},
    private readonly actionCapacity = 1024,
  ) {
    if (!Number.isSafeInteger(actionCapacity) || actionCapacity <= 0) {
      throw new RangeError("actionCapacity must be a positive safe integer");
    }
    this.state = definition.initialState;
    this.initialState = definition.initialState;
  }

  getState = (): State => this.state;

  /** Stable request-local snapshot for SSR and the first hydration render. */
  getInitialState = (): State => this.initialState;

  subscribe = (listener: StateListener): (() => void) => {
    this.assertOpen();
    this.stateListeners.add(listener);
    return () => this.stateListeners.delete(listener);
  };

  subscribeOutput(listener: OutputListener<Output>): () => void {
    this.assertOpen();
    this.outputListeners.add(listener);
    return () => this.outputListeners.delete(listener);
  }

  send(action: Action): FlowTask {
    this.assertOpen();
    const context = new DispatchContext();
    this.activeContexts.add(context);
    void context.finished.then(
      () => this.activeContexts.delete(context),
      () => this.activeContexts.delete(context),
    );
    this.enqueue({ action, context });
    return new StoreFlowTask(context);
  }

  async finish(): Promise<void> {
    while (this.activeContexts.size > 0) {
      await Promise.all([...this.activeContexts].map((context) => context.finished));
    }
  }

  close(): void {
    if (this.closed) return;
    this.closed = true;
    this.queue.length = 0;
    this.queueHead = 0;
    for (const context of this.activeContexts) context.cancel();
    for (const controllers of this.effectsById.values()) {
      for (const controller of controllers) controller.abort();
    }
    this.activeContexts.clear();
    this.effectsById.clear();
    this.stateListeners.clear();
    this.outputListeners.clear();
  }

  private assertOpen(): void {
    if (this.closed) throw new Error("FlowStore is closed");
  }

  private enqueue(envelope: Envelope<Action>): void {
    if (this.closed || envelope.context.controller.signal.aborted) {
      envelope.context.release();
      return;
    }
    if (this.queue.length - this.queueHead >= this.actionCapacity) {
      const error = new FlowQueueFullError(this.actionCapacity);
      this.callObserver(() => this.instrumentation.dispatchFailed?.({ action: envelope.action, error }));
      envelope.context.fail(error);
      envelope.context.release();
      return;
    }
    this.queue.push(envelope);
    const pendingActionCount = this.queue.length - this.queueHead;
    this.pendingActionHighWaterMark = Math.max(
      this.pendingActionHighWaterMark,
      pendingActionCount,
    );
    this.callObserver(() =>
      this.instrumentation.actionQueued?.({
        action: envelope.action,
        pendingActionCount,
      }),
    );
    this.drain();
  }

  private drain(): void {
    if (this.draining) return;
    this.draining = true;
    try {
      while (this.queueHead < this.queue.length) {
        const envelope = this.queue[this.queueHead];
        this.queueHead += 1;
        if (envelope !== undefined) {
          this.processedActionCount += 1;
          this.reduce(envelope);
        }
        if (this.queueHead >= 1024 && this.queueHead * 2 >= this.queue.length) {
          this.queue.splice(0, this.queueHead);
          this.queueHead = 0;
        }
      }
    } finally {
      const processedActionCount = this.processedActionCount;
      const pendingActionHighWaterMark = this.pendingActionHighWaterMark;
      this.queue.length = 0;
      this.queueHead = 0;
      this.processedActionCount = 0;
      this.pendingActionHighWaterMark = 0;
      this.draining = false;
      if (processedActionCount > 0) {
        this.callObserver(() =>
          this.instrumentation.actionQueueDrained?.({
            processedActionCount,
            pendingActionHighWaterMark,
          }),
        );
      }
    }
  }

  private reduce(envelope: Envelope<Action>): void {
    const { action, context } = envelope;
    if (context.controller.signal.aborted) {
      context.release();
      return;
    }

    try {
      const oldState = this.state;
      const next = this.definition.reducer(oldState, action);
      this.state = next.state;
      this.callObserver(() =>
        this.instrumentation.actionReduced?.({
          action,
          oldState,
          newState: next.state,
        }),
      );
      for (const listener of [...this.stateListeners]) {
        if (this.closed || context.controller.signal.aborted) break;
        this.callObserver(listener);
      }
      for (const output of next.outputs) {
        if (this.closed || context.controller.signal.aborted) break;
        this.callObserver(() => this.instrumentation.outputEmitted?.(output));
        for (const listener of [...this.outputListeners]) {
          if (this.closed || context.controller.signal.aborted) break;
          this.callObserver(() => listener(output));
        }
      }
      for (const effect of next.effects) {
        if (this.closed || context.controller.signal.aborted) break;
        this.startEffect(effect, context);
      }
    } catch (error) {
      this.callObserver(() =>
        this.instrumentation.dispatchFailed?.({ action, error }),
      );
      context.fail(error);
    } finally {
      context.release();
    }
  }

  private startEffect(effect: Effect<Action>, context: DispatchContext): void {
    if (effect.kind === "cancel") {
      this.cancelEffects(effect.id);
      return;
    }
    if (!context.retain()) return;

    if (effect.cancelInFlight && effect.id !== undefined) {
      this.cancelEffects(effect.id);
    }

    const controller = new AbortController();
    const cancelWithTree = () => controller.abort(context.controller.signal.reason);
    const unsubscribeCancellation = context.onCancel(cancelWithTree);
    if (effect.id !== undefined) {
      const controllers = this.effectsById.get(effect.id) ?? new Set<AbortController>();
      controllers.add(controller);
      this.effectsById.set(effect.id, controllers);
    }
    this.callObserver(() => this.instrumentation.effectStarted?.(effect.id));

    let effectFinished = false;
    const finishEffect = () => {
      if (effectFinished) return;
      effectFinished = true;
      unsubscribeCancellation();
      controller.signal.removeEventListener("abort", finishEffect);
      if (effect.id !== undefined) {
        const controllers = this.effectsById.get(effect.id);
        controllers?.delete(controller);
        if (controllers?.size === 0) this.effectsById.delete(effect.id);
      }
      this.callObserver(() => this.instrumentation.effectFinished?.(effect.id));
      context.release();
    };
    controller.signal.addEventListener("abort", finishEffect, { once: true });

    const effectContext: EffectContext<Action> = {
      signal: controller.signal,
      send: (action) => {
        if (controller.signal.aborted || !context.retain()) return;
        this.enqueue({ action, context });
      },
    };

    void Promise.resolve()
      .then(() => {
        if (!controller.signal.aborted) return effect.operation(effectContext);
      })
      .catch((error: unknown) => {
        if (!controller.signal.aborted) {
          this.callObserver(() =>
            this.instrumentation.dispatchFailed?.({ action: undefined, error }),
          );
          context.fail(error);
        }
      })
      .finally(finishEffect);
  }

  private cancelEffects(id: EffectId): void {
    const controllers = this.effectsById.get(id);
    this.effectsById.delete(id);
    if (controllers !== undefined) {
      for (const controller of controllers) controller.abort();
    }
  }

  private callObserver(operation: () => void): void {
    try {
      operation();
    } catch (error) {
      try {
        this.instrumentation.observerFailed?.(error);
      } catch {
        // Instrumentation must not change reducer or effect semantics.
      }
    }
  }
}

export function createStore<State, Action, Output>(
  definition: FlowDefinition<State, Action, Output>,
  options: {
    readonly instrumentation?: FlowInstrumentation<State, Action, Output>;
    readonly actionCapacity?: number;
  } = {},
): FlowStore<State, Action, Output> {
  return new FlowStore(definition, options.instrumentation, options.actionCapacity);
}
