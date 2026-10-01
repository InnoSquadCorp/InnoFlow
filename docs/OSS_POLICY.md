# Open-source operations policy

This page connects the existing policies without changing InnoFlow's API,
compatibility promises, or release evidence requirements.

## Ownership and community

- [GOVERNANCE.md](../GOVERNANCE.md) defines maintainer authority and decisions.
  Repository access remains authoritative; a bot review does not grant merge
  or release permission.
- [CONTRIBUTING.md](../CONTRIBUTING.md) and [CLAUDE.md](../CLAUDE.md) define
  contribution, architecture, and validation expectations.
- [CODE_OF_CONDUCT.md](../CODE_OF_CONDUCT.md) governs participation, and
  [SUPPORT.md](../SUPPORT.md) describes best-effort support and issue intake.
- [SECURITY.md](../SECURITY.md) owns supported security lines and private
  reporting. Public issues and automated review messages must not expose
  vulnerability details, credentials, customer data, or proprietary source.
- [LICENSE](../LICENSE) contains the project's MIT license. Dependency changes
  require review of upstream licensing and notices; this license does not
  replace the licenses of SwiftSyntax or documentation tooling.

## Automation and release boundaries

Dependency proposals and review automation follow
[automation-policy.md](automation-policy.md). Keep dependency and GitHub Action
updates reviewable and pinned according to that policy. SwiftSyntax and
compiler compatibility remain deliberate maintainer decisions, with no
automatic broadening of the consumer dependency constraint.

[RELEASING.md](../RELEASING.md) is the release authority. The candidate path is
read-only by default: all 32 hosted preflight checks bind receipts and raw
artifacts to the same exact SHA, and the evidence producer adds the existing
tag and explicit review approval. A verify-only Release Gate dispatch keeps
`publish_release=false`. A public tag already exposes a SwiftPM version;
creating that tag and publishing a GitHub Release require separate approval.

Within the release workflow, only the final publication job receives
`contents: write`, after evidence verification, explicit publication opt-in,
and entry into the `release`
environment. Required reviewers, tag-only deployment rules, immutable release
tags, required branch checks, and repository permissions are server-side
controls. Their declarations or documentation do not prove those controls are
enabled. Administrators must verify them separately before publication.

Documentation deployment and [Swift Package Index metadata](SWIFT_PACKAGE_INDEX.md)
do not confer release approval. A missing runner, runtime, raw artifact, or
external index build remains a blocked or unverified boundary, never a waiver.

## Checking policy changes

Run `scripts/check-community-health.sh`,
`scripts/check-release-evidence-workflow-selftest.sh`, and the dependency/CI
policy tests referenced by `automation-policy.md`. These offline/static and
fixture checks establish configuration behavior only. The complete release
matrix still runs exclusively in the hosted Release Preflight workflow.
