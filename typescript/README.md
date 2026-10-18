# InnoFlow for TypeScript and React 1.0

- `@innosquad/inno-flow`: framework-neutral reducer/effect/store runtime.
- `@innosquad/inno-flow-react`: selector-aware external-store hooks and typed
  context factory.
- `@innosquad/inno-flow-testing`: action, state, and output trace assertions.

The public packages are ESM-only and emit declaration files. The runtime has no
React dependency and requires no Babel, Vite, Next.js, or custom TypeScript
transform. `examples/react-consumer` is a real Vite production build.

```bash
npm ci
npm test
```

The test command builds all declarations, runs runtime and React DOM tests,
builds the Vite consumer, and validates all packed package manifests with
`publint` and Are the Types Wrong, plus declaration/JavaScript source-map
resolution. Tests themselves are typechecked as well.

Run actual tarball consumers with both supported React major versions:

```bash
npm exec playwright install chromium --only-shell
INNOFLOW_REACT_VERSION=18.2.0 npm run test:packed
INNOFLOW_REACT_VERSION=19.2.8 npm run test:packed
```

These resolve packages outside the workspace and verify public types, SSR,
hydration and click behavior in Chromium. Node 20.19.0 and Node 22 are the
tooling CI lanes; React 18.2 and React 19 are the supported UI peer lines.
The versions are a source release candidate until separately published.

See [`../docs/MULTIPLATFORM.md`](../docs/MULTIPLATFORM.md) for installation and
authoring examples.
