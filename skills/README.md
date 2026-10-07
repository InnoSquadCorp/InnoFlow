# InnoFlow agent skill

The canonical [InnoFlow skill](innoflow/SKILL.md) lives in this library repository.
It supports stable **6.0.x** (`>=6.0.0, <6.1.0`) with an exact **6.0.0** tagged
consumer baseline at `188c2732d26350cf01afadade3dac89a2b73b68f`. Support for a
patch series is not a claim that all patches were tested. The tag exists;
no matching GitHub Release page was found on 2026-10-07.

## Ownership and distribution

Update `skills/innoflow/` alongside library changes that affect consumer guidance.
The central `innosquad-agent-skills` repository owns plugin manifests, catalogs,
locked snapshots, and Codex/Claude Code installation and behavioral evaluation.
It copies the entire skill at an exact source commit and records its Git tree,
supported range, and separately validated library release/revision. The skill
source commit can be newer than the library tag being taught.

Keep all runtime references, scripts, fixtures, and license notices inside the
skill directory. Central copies are distribution snapshots, not independent
instruction sources. Automatic collection and public plugin publication are
separate work. This source and its examples carry InnoFlow's MIT license; retain
[THIRD_PARTY_NOTICES.md](innoflow/THIRD_PARTY_NOTICES.md) when redistributing.

## Standalone installation

Copy the complete `skills/innoflow` directory from a reviewed source commit.
Compare an existing destination before replacing it.

| Host | Consumer-relative destination | Explicit invocation |
| --- | --- | --- |
| Codex | `.agents/skills/innoflow/` | `$innoflow` |
| Claude Code | `.claude/skills/innoflow/` | `/innoflow` |

Restart/start a new session after installation. Automatic selection is enabled.
Choose standalone or plugin installation in a given project to avoid duplicate
guidance. Adding a SwiftPM dependency alone does not install an AI skill.

Example: “이 프로젝트의 InnoFlow 버전에 맞춰 로딩 상태와 실패·재시도를
구현하고 TestStore로 검증해 줘.” In the central plugin, explicit invocations
are `$innosquad:innoflow` and `/innosquad:innoflow`.

## Consumer validation

From the library root on an Apple development host with Python 3:

```bash
python3 skills/innoflow/scripts/validate_consumer.py --scratch-path /tmp/innoflow-skill-validation
```

The standard-library-only helper copies the fixture to external scratch space,
resolves exact remote dependencies, verifies graph/workspace/checkouts, then runs
strict-concurrency tests with warnings as errors. Logs and JSON remain in that
scratch directory. It never replaces the application's graph or installs an AI
plugin. See [validation.md](validation.md) for results and boundaries.

The fixture covers macro authoring, binding, phases, failure/retry, active error
mapping, typed outputs, scoped composition, manual time, dispatch cancellation,
and lexical ownership. UI helpers compile; no device UI lifecycle is exercised.
This focused external consumer is allowed under the repository's CI-only release
policy, but is not release-preflight or framework-wide acceptance evidence.
