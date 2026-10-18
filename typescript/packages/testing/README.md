# @innosquad/inno-flow-testing

State, action, and typed-output trace assertions for `@innosquad/inno-flow`
1.0.

```bash
npm install --save-dev @innosquad/inno-flow-testing@1.0.0
```

Use `TestStore` to send actions and assert state plus the recorded action and
output sequences without a UI renderer.

State, actions and output use structural equality by default (including
nested objects, Map/Set/Date and explicit `undefined` expectations).
`TestStoreOptions` accepts `stateEquals`, `actionEquals` and `outputEquals`
for cyclic graphs or domain-specific comparisons. Use `close()` to release
the store and `resetTrace()` only when intentionally starting a new trace.

This is a source 1.0.0 candidate until the separately authorized registry
release. Install the core and testing local tarballs together beforehand.
