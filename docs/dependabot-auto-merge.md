# Dependabot auto-merge: prepared, not activated

The repository prepares native squash auto-merge for verified Dependabot PRs,
including majors and SwiftSyntax updates. Existing review, compatibility, API,
coverage and performance checks remain in force. Human PRs are never automatically
armed by this coordinator. No new PAT, App installation, credential or bypass is
created, and this implementation does not change repository settings.

## Trusted execution

`scripts/dependabot-merge-policy.py` executes only from trusted default-main code.
Every job and mutating CLI command requires the repository, `refs/heads/main` and
exact default-main workflow reference. Coordinator checkouts are SHA-pinned actions, `ref: refs/heads/main`, sparse
`scripts`, and `persist-credentials: false`. The separate read-only native reporter
checks out `github.workflow_sha`, binding execution to immutable trusted-main code.
It reads API metadata only: no PR checkout, dependencies, caches, downloaded
artifacts or PR-controlled shell commands execute with write permission.

| Job | Dedicated token scopes |
| --- | --- |
| inspect | contents, actions, checks, pull-requests read |
| ready-plan | contents, actions, checks, pull-requests read |
| ready-refresh | contents, checks, pull-requests read; actions write |
| bot-ready | contents, pull-requests write; actions, checks read |
| post-merge-plan | contents, actions, pull-requests read |
| native Ready | contents, actions, checks, pull-requests read |
| post-merge | contents, pull-requests read; actions write |
| Review Notice | no permissions, checkout, dependencies, secrets or artifacts |

These scopes are prepared code and need owner review before merging/activation.
The post-merge job's actions-write scope has no arbitrary dispatch interface:
only the hardcoded `ci.yml`, `main`, and an actually merged bot PR are accepted.

## Exact proof and native enforcement

The bot identity must match login `dependabot[bot]`, ID `49699333`, type `Bot`.
The PR must be open, non-draft, conflict-free, same-repository, and based on main.
Actor, labels, title, branch prefix and semver category are not authorization.

The coordinator validates the latest exact-head `pull_request` CI run and latest
attempt: active workflow ID/path, repository IDs, unique PR association, head/base
SHAs and current test-merge parents must agree. Every expanded Flow job in `CORE`
must succeed, including both sanitizers, all platform/runtime/sample matrix cells,
API/migration checks, coverage, principles, DocC, planner and both aggregates.
All required validation steps are explicitly inventoried; removing a secondary
step also fails. Only the recovery-origin guard, PR DocC upload and failed-runtime
artifact preservation may be expected skipped steps. Whole validation jobs cannot
skip in a bot proof.

Jobs are bound to exact GitHub Actions app/suite/check/job IDs, details URL,
head/test-merge SHA and attempt. All API pages are read. Missing, duplicate,
foreign, stale, pending, failed, cancelled, neutral and unexpected skipped results
fail closed. Earlier completed runs/attempts can be superseded only by the fully
validated latest attempt. Additional current-head checks/statuses must succeed.
Ready does not wait on itself.

Requested reviews, unresolved threads, effective changes-requested/pending reviews
and native review decisions block readiness. A comment does not clear requested
changes. Review events wake a zero-permission notice; the trusted coordinator
re-reads APIs. Thread resolution has no dedicated Actions event and is checked on
the next wake or hourly reconciliation. There is a review-event race between the
last read and processing a new event; this is not an atomic review lock. Existing
native review-thread resolution remains enforced independently. Activation also
requires an applicable active repository-native `pull_request` rule, verified
through the same source and visible-bypass checks as native CI rules, with
`required_review_thread_resolution=true` in at least one applicable PR rule.
GitHub's [native PR rule](https://docs.github.com/en/pull-requests/how-tos/review-pull-requests/reviewing-proposed-changes-in-a-pull-request#submitting-your-review)
blocks `CHANGES_REQUESTED` from reviewers with write/admin/owner access. This does
not impose a new positive approval count: the existing zero-approval policy is
retained. Reviews from other readers remain sampled metadata checks, not a native
atomic veto. Missing, inactive or unverifiable native PR protections block
activation; this code never changes repository settings to satisfy the guard.

Native active strict main rules must require **CI Required**, **Build Documentation**
and **Dependabot Merge Ready**, each from Actions app `15368`. Visible bypass
capability is rejected. Every applicable CI/PR ruleset must report this workflow
token's `current_user_can_bypass=never`. Redacted `bypass_actors` is not an empty
list; absent runtime no-bypass proof leaves automation in standby. An owner audit
does not replace that runtime proof or justify an admin credential in the workflow.

GitHub owns one unconditional, fixed-name **Dependabot Merge Ready** job in
`dependabot-ready.yml`; no API creates or patches its verdict. Its read-only
snapshot validates current eligibility, and an always-running enforcement step
requires an explicit true result. Infrastructure/API/evaluation failure, missing
output, cancellation or ambiguous provenance cannot become green readiness.
Human PR success means only “manual policy applies”; it grants no auto-merge.

The reporter's trusted run title and evaluation-step name bind PR number, head,
head/base repository IDs, main base and immutable source SHA. This permits a human
fork reporter whose REST `pull_requests` association is empty without inferring
identity from a branch/SHA alone. PR code is never checked out. Latest verdicts and
refresh writers require the original reporter/coordinator/policy blobs to match
trusted main; historical check attribution still verifies original main ancestry.
A superseded event/head cannot publish a late accepted verdict.

The bot coordinator validates the full proof and latest successful native Ready
repeatedly before `enablePullRequestAutoMerge(expectedHeadOid)`. Native strict
checks and resolved-thread rules own actual merge/base freshness. The request can
merge immediately, so a later metadata read is not presented as a rollback barrier.
Failed eligibility cancels a verified bot's existing native request before a
readiness refresh. There is no direct merge or admin bypass fallback.

Background events may request only a provenance-verified native reporter job
rerun when a terminal controlled verdict disagrees with current eligibility.
The actions-write writer is separate from contents/pull-request writes. Per-PR
queued serialization and authoritative prior-writer history prevent duplicate
requests for the same run/attempt; uncertain writes are read back, never blindly
retried. API/infrastructure failures require operator recovery. A new trusted
reporter definition needs a fresh PR lifecycle run; an old definition is not
rerun with different policy code.

Reconciliation lists all open PRs, managing main PRs plus verified bots retargeted
away from main so those old native requests are still cancelled. Non-main human
PRs remain outside that managed surface.
Uncertain writes are read back and never blindly retried. API denial is a blocker.

## Actual post-merge recovery

A GITHUB_TOKEN merge cannot be assumed to emit a normal push workflow. Reconciliation
finds a unique actually merged bot PR at **current main**, verifies author/repository,
closed/merged state and merge commit twice, then dispatches only `CI` on main.
An existing exact-main push or marked recovery run prevents duplicate dispatch,
including failures; failed-run retries require operator review.

The input alone grants no publication permission. CI Plan independently verifies
the actual bot merge and `GITHUB_SHA == current main`. Only that successful proof
can authorize recovery's DocC artifact. Pages deployment verifies the run and SHA
again. Main moving during dispatch fails closed; the next main push/reconciliation
covers the new tip. Recovery uses a separate CI concurrency group, and reusable
build groups include run ID, so an obsolete recovery cannot cancel a newer native
main push or its DocC/coverage jobs. Hourly schedules are best-effort, not an execution-time SLA.
This change does not assert that native Ready fork handling, main proof reuse or
post-merge recovery has been observed after deployment; fixture tests are distinct
from live activation evidence.

## Owner-approved flag-last activation

1. Review the final Draft PR SHA and CI, then separately approve/manual-merge this
   implementation. Do not enable auto-merge on a human implementation PR
2. Keep `DEPENDABOT_AUTO_MERGE_ENABLED` absent/false. Obtain a fresh PR lifecycle
   event after trusted-main deployment to establish the native Ready reporter.
   Existing API-created legacy Ready checks are not reused as native proof; bot
   heads with legacy checks need a fresh head/lifecycle run before admission.
   Confirm no bootstrap cycle before enabling new bot approvals
3. Preserve all existing main/tag protections, strict CI Required and Build
   Documentation, review-thread resolution and no bypass. Add only the new
   **Dependabot Merge Ready** Actions context to the main rule. Audit inherited
   and classic protections; inaccessible APIs are not evidence of absence
   Verify the active native PR rule and thread-resolution requirement without
   changing the existing approval count. Keep activation disabled if either
   native rule proof or the separate owner no-bypass audit is incomplete
4. Enable native auto-merge with squash retained. Inspect outstanding bot requests
   while the flag stays false. Do not arm unvalidated PRs manually
5. Set `DEPENDABOT_AUTO_MERGE_ENABLED=true` last, dispatch the coordinator on main,
   observe failing PRs staying blocked, and verify actual merged SHA main CI/docs

Turning the flag off prevents new approvals and later reconciliation cancels bot
requests; it is not a synchronous emergency stop. Disable the repository feature
or cancel outstanding native requests for an immediate stop. Missing custom labels,
release-environment protection and token-scope activation need explicit approval.

References: [Dependabot automation](https://docs.github.com/en/code-security/tutorials/secure-your-dependencies/automate-dependabot-with-actions),
[workflow events](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows),
[GITHUB_TOKEN recursion](https://docs.github.com/en/actions/concepts/security/github_token),
[native expected-head input](https://docs.github.com/en/graphql/reference/pulls#enablepullrequestautomergeinput).
