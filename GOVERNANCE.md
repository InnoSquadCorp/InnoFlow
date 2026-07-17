# InnoFlow Governance

InnoFlow is owned by InnoSquadCorp and developed in public. This document
describes how project authority is exercised; GitHub repository permissions
remain the source of truth for who can merge or publish.

## Roles

- **Contributors** open issues and pull requests, improve documentation, and
  participate in technical discussion.
- **Reviewers** provide evidence-based review but do not gain merge or release
  authority solely by reviewing.
- **Maintainers** triage issues, enforce the architecture and security
  contracts, merge changes, and cut releases. The current active maintainer is
  [@Ethan-IS](https://github.com/Ethan-IS); InnoSquadCorp repository
  administrators retain final ownership and succession authority.

Maintainer status is based on sustained project work, sound technical judgment,
respectful collaboration, and the ability to operate the validation and release
gates. An existing administrator grants or removes the corresponding GitHub
role. Inactive maintainers may step down or be removed after ownership is
transferred and outstanding security/release work is handed off.

## Decisions and changes

Routine fixes are decided through issue or pull-request review. Maintainers may
merge once the change is scoped, documented where necessary, and proportionate
validation passes.

Changes to public API, concurrency semantics, macro authoring, effect ordering,
or framework ownership require explicit rationale plus aligned source, tests,
documentation, migration notes, and repository gates. Durable policy decisions
should be captured in `docs/adr`. Breaking changes are reserved for a major
release line; `main` currently represents 5.0 development.

When consensus is not immediate, the maintainer records the alternatives and
the deciding constraint in the issue, pull request, or ADR. The active
maintainer makes the final repository decision and is accountable for keeping
the written contract consistent with it.

## Releases and security

Only maintainers with repository release permission may publish a tag or
GitHub release, following `RELEASING.md`. A release must pass the documented
Debug, Release, sample, documentation, macro, and policy gates; emergency
security releases may minimize disclosure but do not skip validation relevant
to the fix.

Security reports follow `SECURITY.md` and are handled privately until a
coordinated disclosure is ready. Public governance discussion must not expose
embargoed details.

## Amendments

Governance changes use the same public review path as other contract changes.
Material role, decision, or release-policy changes must update this file in the
same commit that adopts them.
