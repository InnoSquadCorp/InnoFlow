# @innosquad/inno-flow-react

React hooks and a typed provider for `@innosquad/inno-flow` 1.0.

```bash
npm install @innosquad/inno-flow@1.0.0 \
  @innosquad/inno-flow-react@1.0.0
```

Use `useFlowState` for the complete state or `useFlowSelector` for a selected
value. Selectors accept a custom equality function and subscribe through
React's `useSyncExternalStore`. `createFlowContext` provides a typed Provider,
`useStore`, `useState`, and `useSelector` bundle.

Supports React 18.2 and React 19. Create SSR stores per request and initialize
the browser store from the identical serialized snapshot. Hooks default to
`store.getInitialState()` for server/first hydration rendering and accept an
explicit stable server snapshot when needed. Do not share server-request
state through a module-global store.

The Provider does not own or close its supplied store; its creator must call
`store.close()` at the appropriate lifetime boundary. Selectors should be
pure and state immutable. Use structural equality for object selections
when referential equality does not describe the desired update policy.

These are source 1.0.0 candidates until the separate registry release is
authorized; use all related local `npm pack` tarballs together beforehand.
