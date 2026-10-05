# Stable migration consumers

`scripts/check-migration-consumer.sh` builds the V5 consumer against annotated
tag `5.1.1` and the V6 consumer against the candidate checkout. The gate rejects
a changed baseline tag object or commit before building:

- Tag object: `7782c370bd6c769e1b9fc475146bd1aabce6b97f`
- Commit: `00a73ed2d2cb94114b0be5c9fbd59c187a4b67c7`
- Original `EffectTask.swift` blob: `3e6227a43edbeb8fd90d4d797f4a887f469ee75d`

The executable and testing targets verify shared observable behavior. The
standalone `EffectTaskExtensions` files then import the actual built
`InnoFlowCore` modules as external clients; they are not package target sources.
The same gate runs on the supported Swift 6.3 and 6.4 toolchains.

| Extension form | Stable 5.1.1 | Current 6.0 |
| --- | --- | --- |
| `EffectTask`, bare `EffectTask` return | Compiles | Requires generic arguments |
| `EffectTask`, `Self` return | Compiles | Compiles, including a real-Output receiver |
| `EffectTask`, `EffectTask<Action>` return | Compiles | Compiles; return remains Never even on a real-Output receiver |
| `ReducerEffect where Output == Never`, `Self` return | New API | Compiles for Never; rejects String Output |

The two negative controls require their specific diagnostic and exactly one
compiler error. Missing imports, unrelated compiler errors, or an unexpected
success fail the gate. Both positive forms and output restrictions matter:
the alias preserves ordinary specialized values, but does not implicitly
restrict extension members to Never.

The codemod deliberately reports recognized alias extensions for manual review.
It does not choose between an output-free replacement and a generic helper.
Its separate unit and real-CLI controls check source preservation, blocker exit
codes, batch refusal, backups, and idempotence.

`INNOFLOW_KEEP_MIGRATION_FIXTURE=1 scripts/check-migration-consumer.sh` retains
the build directories and per-control logs. The compiler helper can also take
explicit prebuilt module directories or build roots, but such reuse must record
their source revision and compiler. A source-slice module or a Linux mirror
is focused typechecking evidence, not a full stable-package, Apple-platform,
SwiftSyntax source-build, or release-preflight result.
