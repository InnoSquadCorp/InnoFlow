# Documentation refresh audit — 2026-10-10

This is the scope and validation record for the PR #63 refresh based on
`c0d7197e8380f3355133c4ea56cf1da6c7da29bb`, compared with published 6.0.2 at
`1176de1e4783b638c03a9334f43cc49378957148`. It is not release certification.

## Inventory and exit criteria

The audit covered root README/release/migration/contribution/architecture and
community documents; DocC articles; current authoring, dependency, lifecycle,
scheduler, instrumentation, toolchain and CI guides; sample setup/README/rules;
benchmark/reproducer and migration-tool/consumer-fixture instructions; the
library-owned skill and its contracts; dated plans/reviews/ledgers and ADRs.
The original read-only audit inventoried 128 documentation paths, including
Markdown, rule text and plain-text resources. New language pages and this
refresh add to that inventory. Counts are scope records, not executed tests.

Completion requires release/API accuracy, seven matching entry READMEs,
no unresolved navigable local links, a complete digest-bound Swift fence ledger,
targeted validator regressions, real focused consumer/example checks, and a
review of the exact final diff. Device tests, full release preflight, permission
changes, DI edits/CI monitoring, InnoNetwork work and the cancelled InnoSample
task are excluded. Absence of their results is not a PASS.

## Findings and corrections

| Area | Evidence and change |
| --- | --- |
| Published versus development | All production `Sources/` files match 6.0.2. Development CI/test/tooling/docs are identified as unreleased. README, release instructions, API decisions and skill state now point to the published release; immutable tag and dated evidence retain original state. |
| API baseline | Current five-product comparison reads `STABLE_VERSION`; Inspector is included. Historical 5.1.1→6.0 migration remains separate. The checker uses the same default and missing-tag controls fail closed. |
| CI tag preparation | [Old-head run 38007103547](https://github.com/InnoSquadCorp/InnoFlow/actions/runs/38007103547/job/114078355904) failed before API comparison because the static job's shallow checkout omitted the baseline tag. That job now fetches full history; workflow negative controls reject shallow or omitted tag history. This is distinct from an observed API incompatibility. |
| Consumer diagnostics | Nonzero structured-command exits and timeouts name stdout and stderr logs; real subprocess regressions retain both streams and reject failure. Process-group cleanup remains tested. |
| Languages | English, Korean, Spanish, German, Simplified Chinese, Japanese and Russian use InnoDI's canonical filenames/order/switcher. Same section scope, Swift examples, links, versions and critical identifiers are checked. Old filenames remain compatibility pages. Native editorial certification is not claimed. |
| Detailed guide | Existing detailed README content and its executable fence contexts are preserved in [USER_GUIDE.md](USER_GUIDE.md). Whole-parent snapshot `select(memoize: true)` is distinguished from future fine-grained dependency inference. |
| Installation/products | README manifests explicitly name external products; five products, Swift 6.3 minimum, Swift 6 mode, SwiftSyntax 603/604 range and five platform floors match manifests. |
| Sample | The local package path is `../../../`; setup links to all ten demos and distinguishes local checkout use from a remote release. iOS-first interactive behavior and other-platform limits remain explicit. |
| Testing/release claims | Current 28-required/four-optional runtime policy is reflected in maintained guides. Historical 32-check receipts/counts remain dated. Parsing, contextual typechecking, runtime tests, UI behavior and release certification remain distinct. |
| Links/navigation | Existing source/test paths are repaired where uniquely resolvable. Absent local `.build`, temporary and out-of-repository artifacts retain path text with an explicit unavailable-historical label. The absent old API evaluation is not presented as a live link. |
| Skill | Exact remote fixture is updated to 6.0.2; a fresh 11-test result is separate from the preserved 2026-10-07 6.0.0 evidence. Combined framework graphs and AI host selection remain unverified. |

## Validation evidence

[Current skill validation](../skills/validation.md) links the fresh remote
consumer evidence. On this checkout, the supported Ruby 3.4 and Swift 6.4 /
Xcode 27.1 environment passed the static gates, including the five-product API
comparison against 6.0.2. The documentation harness compiled 46 external targets
from 121 distinct exact Swift fences (127 uses), parsed eight installation
manifests from 16 fences, and passed 39 Swift Testing example tests.

The complete 164-fence review ledger has no pending bindings: syntax validation
parsed 139 fences and classified 25 as contextual, with no unexpected failures.
These categories overlap compilation evidence; they are not counts to add
together. Seven-language parity and 703 offline local destinations/anchors pass.
The repository Python policy suite ran 411 tests without failures, skipping only
one Linux-specific environment control on this Mac. Its nine targeted consumer
output/timeout tests cover nonzero exits, separate diagnostics and process
cleanup. Gate selftests and workflow negative controls pass, including missing
tag history; actionlint 1.7.12 checked all 15 workflows. The PR/task report gives
the final exact head. CI status must be read for that pushed head;
an earlier green run is not proof for these edits.

Local relative file/heading links are checked without fetching external URLs.
Current external release/source links were inspected via GitHub; general URL
reachability and hosted DocC deployment freshness are outside the offline
checker. Translations have technical parity checks and manual prose review,
with no native-speaker quality certification.
