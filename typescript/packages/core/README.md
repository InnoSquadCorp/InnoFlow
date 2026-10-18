# @innosquad/inno-flow

Framework-neutral InnoFlow 1.0 runtime for TypeScript.

```bash
npm install @innosquad/inno-flow@1.0.0
```

```ts
import { createStore, defineFlow, transition } from "@innosquad/inno-flow";

const counter = defineFlow({
  initialState: { count: 0 },
  reducer: (state, action: { type: "increment" }) =>
    transition({ count: state.count + 1 }),
});

const store = createStore(counter);
await store.send({ type: "increment" }).finished();
store.close();
```

The package is ESM-only. Effects receive an `AbortSignal`, dispatch tasks own
their descendant work, and state can be consumed without a UI framework.

Return immutable state snapshots from reducers. `createStore(definition,
{ actionCapacity: 1024 })` bounds queued actions; a full reentrant queue fails
the new task with `FlowQueueFullError` without dropping earlier actions.
Observe failures with the returned task's `finished()` promise. Cancelling a
task suppresses late actions/output; effects must honor their AbortSignal
to release I/O resources. `close()` is idempotent and rejects later sends.

Output subscriptions are live and non-replaying. Unsubscribe when the owner
ends, and keep data needed for rendering/recovery in state. The runtime has
no React dependency. The 1.0.0 coordinates become available after the
separate maintainer-authorized registry release; local candidates can be
installed from `npm pack` tarballs.
