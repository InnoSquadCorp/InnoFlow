# InnoFlow skill validation

## Published 6.0.2 — 2026-10-10

The exact remote 6.0.2 fixture at
`1176de1e4783b638c03a9334f43cc49378957148` passed 11 tests in one suite on this
Apple host (Xcode 27.1 / Swift 6.4, arm64), with strict concurrency and warnings
as errors. The verifier checked remote tag identity, exact manifest/lock,
active graph/workspace, SwiftSyntax 604.0.0, checkout SHAs and cleanliness.
[Fresh evidence](validation/consumer-evidence-6.0.2.json) records toolchains,
fixture hashes, all commands, log locations, graph and test results. Raw logs
remain in the recorded external scratch directory and are not bundled here.

This validates the skill fixture, not every 6.0.x patch or the user's app.
SwiftUI helpers compile; device UI lifecycle, Inspector, scheduler admission,
optional-child lifetime, combined frameworks and the full release matrix remain
outside this fixture. The tag and GitHub Release publication were verified
separately. SwiftPM and AI-skill installation are separate operations.

## Historical 6.0.0 validation — 2026-10-07

The original record and its evidence below apply only to that earlier tag.
They have not been relabeled as 6.0.2 evidence.


The skill supports stable `>=6.0.0, <6.1.0`. This record validates the exact
**6.0.0** tag at `188c2732d26350cf01afadade3dac89a2b73b68f`, separately from
that support range. A GitHub Release page was not found at the check; the
remote tag and its commit were verified directly.

## Consumer and packaging checks

- The isolated remote consumer passed **11 tests in 1 suite**, strict concurrency
  complete and warnings as errors, on macOS 27 arm64 / Xcode 27 / Swift 6.4.
- The exact remote graph used InnoFlow 6.0.0 and SwiftSyntax 604.0.0. Manifest,
  lock, active graph/workspace, prebuilt selection, checkout SHAs and cleanliness
  were checked. No local-path override was substituted.
- A disposable copy with an incorrect expected InnoFlow revision was rejected
  before any build, providing a negative control for the reusable helper.
- Skill structure, relative resource links, and exact-tag upstream reference
  targets were checked. The entire runtime directory is self-contained.

The [machine-readable evidence](validation/consumer-evidence.json) retains
fixture hashes, toolchain, dependencies, support range, and test results. Full
logs stay in external scratch space. The helper uses only Python's standard library.

## Behavior exercised

The suite checks exhaustive reducer authoring, canonical SwiftUI binding,
phase-managed success, failure and retry, thrown CancellationError mapping while
active, typed output assertions, scoped child/output lifting, synchronous output
capture, registration-aware manual time, individual dispatch cancellation, and
FlowScope cleanup with surviving untracked work.

The first fixture compile failed because its custom `.run { send, context in }`
closure allowed a clock error to escape. That closure is nonthrowing in the
actual API. Explicit clock cancellation handling corrected the example; the
reference now distinguishes this signature from `.perform`. The library source
was unchanged, and the corrected full fixture passed. This was a fixture error,
not a library defect.

## Boundaries

UI helpers compile, but no Simulator/device lifecycle was run. The fixture does
not qualify scheduler admission, optional-child lifetime, Inspector, migration
execution, combined Inno dependencies, other SwiftSyntax/toolchains, or later
patches. The repository's full release preflight remains CI-only and separate
from this focused external consumer. AI host installation, automatic selection,
and generated-code evidence belong to the central plugin repository; a passing
Swift fixture alone does not prove those outcomes.
