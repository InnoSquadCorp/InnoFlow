# InnoFlow 6.0 review closure plan

Status: planned before implementation of this additional review batch.
Base: PR #53 head `c874a85d3eba86020c178a55a091017727d3a436`.
The user requested a plan, implementation in that order, and publication to the
existing PR after the additional batch is complete. Merge/tag/release are separate.
Existing CI repairs are retained as a separate work stream and evidence set.

## Findings and evidence boundary

- Confirmed P0: optionalChild changes a bare child send from synchronous draining
  to an asynchronous owned wrapper. Real Store controls at this source produced
  immediate count 1 versus 0, reordered `start/follow/tick` into `start/tick/follow`,
  and dropped the follow-up without emission/drop observation when immediately
  closed. Three contract assertions failed only for the owned variant.
- Confirmed migration gap: a bare `EffectTask` return type in its extension fails
  at the current API. Self-returning extensions compile and also extend effects
  with real Output, contradicting the current migration wording. The exact 5.1.1
  source and compiler controls still need to be pinned for the migration record.
- Codemod scope, draft-only API labels/aliases, large-state copies, lifetime index
  complexity, TestStore UUID costs and stress failures require their own probes.
  Syntax-only migration is not a compiler certificate.
- The supplied latency, 2.2x ratio, five flaky tests, worktree count and script
  percentage lack source-identified raw evidence here. They are hypotheses, not
  reproduced results. No outside worktree or environment is assumed accessible.
- Apple coverage at earlier `b28c761` passed 955 Swift Testing declarations and
  two XCTest location checks. It is not a verdict for this future batch. Full
  32-check Release Preflight remains main-only; PR CI cannot replace it.

## Ordered work and local commits

### 0. Close existing CI interpretation and fixture defects

Preserve the benchmark public-API fix and sample terminal-admission fix. Keep
308 focused runtime identifiers and all 32 release checks. Classify the two
intentional diagnostic tests by exact IDs, exact expected-issue counts, strict
Swift matchers and negative verifier controls. Reject other failures, skips,
missing/extra IDs, warnings and changed counts. Preserve old failed receipts.

### 1. Restore synchronous Store ownership semantics

Add real Store and TestStore controls for a direct child send/output, a following
parent action, immediate removal/replacement/reentry, nested owners, equal-ID
siblings and discarded handles. A transparent ownership wrapper must preserve
the underlying synchronous send/output behavior and carry owner context through
queueing. Keep explicit asynchronous operations/composite semantics unchanged.
Assert emission/drop observation and per-dispatch accounting. Cancellation-ignoring
operations must remain physically active until return; no optimistic completion.
Commit only after the original reproductions turn green and controls stay green.

### 2. Pin stable migration and codemod boundaries

Use the exact annotated 5.1.1 tag and immutable commit, current API and supported
Swift 6.3/6.4 compilers. Inventory stable changes separately from unreleased draft
churn. Test extension forms, helper return types and output restrictions in actual
external consumers. Repair migration text and conservative codemod diagnostics;
unsupported known shapes must require review rather than imply compiler success.
Preserve original input bytes, dry-run reports, idempotence and write/backup rules.

### 3. Freeze the reviewed public API

Choose and document one canonical testing dispatch name, explicit compatibility
policy for draft aliases, stable-versus-new source-location overloads, consistent
child reducer labels and the public enum evolution rule. Do not remove a stable
API merely because a draft is untidy. Each choice needs a reason, updated docs,
positive usage and exact negative/transition compiler controls. Re-run migration,
JSON, external consumers and API inventory checks before performance baselines.

### 4. Measure and improve lifetime and large-state costs

Freeze a correctness-passing post-step-3 baseline before optimizing. Diagnose
registered/live child lifetimes at 1/32/128/512/1000 entries, array versus
IdentifiedArray lookup, unrelated parent actions, and no-observer versus observed
large-array mutation. Preserve final-state removal/replacement reconciliation,
parent/sibling isolation, instance identity and observation counts. Address measured
algorithmic work and unnecessary copying; do not skip lifetime guarantees.

### 5. Measure TestStore costs and harden load-sensitive verification

Profile current send/receive/output/finish workloads before changing internal
UUID/token bookkeeping. Preserve public correlation IDs, exact dispatch ownership,
selective cancellation and physical completion. Search current CI/source for the
claimed flaky cases; if they cannot be identified, say so and use a named fixed
stress matrix rather than assert that an unknown five were repaired. Prefer
handshakes/manual clocks over scheduler-count assumptions. Sort diagnostic output
only where ordering is otherwise unstable and verify emitted content remains exact.

### 6. Integrate and publish the complete additional batch

Review the public diff by behavior/module, keep useful evidence and eliminate only
justified duplication. File/script counts alone do not justify deletion. Update
source-derived test inventories, examples, docs and API/migration controls. Run
final correctness and performance qualification at frozen source revisions, retain
per-stage commits and recovery evidence, then push the complete batch to PR #53.
Track exact-head Apple/API/consumer/migration/sanitizer/UI checks to terminal
results. Disclose main-only preflight, missing environments and unproven claims.

## Performance admission protocol

The baseline is the corrected post-API source, not the known-broken owned-send
version. Before comparative runs, record exact scenarios, iteration counts,
compiler/linker commands, transitive module flags, tool/runtime hashes, source
hashes and semantic oracles in a separate immutable protocol appendix.

- One baseline-only, untimed qualification chooses iteration counts targeting
  roughly 0.4 seconds per timed loop, using a fixed formula and capped limits.
  No comparative effect is inspected when choosing counts.
- Fixed 64 rounds per admitted scenario, each with baseline A, identical baseline
  A' and candidate. Use a predeclared seed and balanced six-order permutations.
  No replacement samples, subset rescue, early success stopping or reruns until pass.
- Primary metric: median paired candidate/baseline timed-loop wall ratio. Use
  10,000 seeded paired IID and fixed-block bootstrap resamples and the conservative
  envelope of their 95% intervals. CPU, RSS and order diagnostics are secondary.
- Adoption requires at least 5% median improvement on the named primary target,
  an upper interval bound below 1.0, and no scenario's median or upper bound above
  1.05. Identical-binary A'/A intervals must remain within [1/1.02, 1.02].
  All required gates must pass; inconclusive calibration does not establish success.
- Array lifetime lookup additionally records scaling at the frozen sizes; avoid
  claiming O(N) solely from a single large-N speedup. Preserve operation/return,
  state/output, observation, owner-isolation and cleanup oracles on both sides.
- Freeze final binaries separately from test builds and verify hashes before/after.
  Coordinate an exclusive VM timing window with DI/Router; use fixed CPU affinity
  and process/environment receipts. Visible VM quiet is not physical-host isolation.
- Source changes after a cohort invalidate attribution to a later SHA until the
  impact is explicitly assessed and any required final non-regression check passes.
  Prior 0c693e2 Linux evidence and future cohorts remain separate. No Apple/UI/TCA
  or universal performance claim follows from Linux results.
