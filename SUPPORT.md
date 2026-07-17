# InnoFlow Support

InnoFlow is maintained as an open-source project on a best-effort basis. There
is no guaranteed response time or compatibility support for untagged commits.
The latest stable major release and the current `main` development line are the
supported surfaces described in `SECURITY.md` and `RELEASING.md`.

## Before opening an issue

1. Check the [README](README.md), [API documentation](https://innosquadcorp.github.io/InnoFlow/documentation/innoflow/), and existing [issues](https://github.com/InnoSquadCorp/InnoFlow/issues).
2. Reduce the problem to the smallest feature, reducer, or consumer package
   that reproduces it.
3. Record the InnoFlow version or commit, Swift version, Xcode version, and
   destination platform.

## Where to ask

- Use the [bug report](https://github.com/InnoSquadCorp/InnoFlow/issues/new?template=bug_report.md)
  for reproducible behavior that conflicts with the documented contract.
- Use the [question template](https://github.com/InnoSquadCorp/InnoFlow/issues/new?template=question.md)
  when the documentation does not answer a focused usage question.
- Use the [feature request](https://github.com/InnoSquadCorp/InnoFlow/issues/new?template=feature_request.md)
  for a new API or a change to framework ownership boundaries.
- Report suspected vulnerabilities only through
  [GitHub Private Vulnerability Reporting](https://github.com/InnoSquadCorp/InnoFlow/security/advisories/new),
  never through a public issue.

Questions about app-specific navigation, transport, session lifecycle, or
dependency-container construction may be closed when they fall outside
InnoFlow's documented framework boundary. A minimal example that demonstrates
a missing integration contract is still welcome.

## What maintainers need

Please keep reproductions public and dependency-minimal when possible. Remove
credentials, customer data, and proprietary source. Maintainers may ask for a
standalone Swift package or a fork before classifying an issue; an unreproducible
report can be closed and reopened when that evidence is available.
