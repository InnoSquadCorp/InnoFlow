# Security Policy

## Supported Versions

Security fixes are prioritized for the latest public major release and the
current `main` branch before a release is cut.

| Version | Supported |
| --- | --- |
| 4.x | Yes |
| 3.x and earlier | No |

## Reporting a Vulnerability

Please do not open public issues for suspected vulnerabilities. Report them
through GitHub Private Vulnerability Reporting:
https://github.com/InnoSquadCorp/InnoFlow/security/advisories/new.

Include:

- affected package version or commit
- a minimal reproduction, if available
- expected and actual behavior
- any known impact or workaround

The maintainers will acknowledge valid reports, scope impact, and coordinate a
fix before public disclosure.

## Response and Disclosure

The project targets an initial acknowledgment within 7 calendar days and an
initial severity/scope update within 14 calendar days. These are best-effort
targets, not a service-level agreement. If more investigation is required, the
maintainer will coordinate the next update through the private advisory.

Please allow a fix and supported-version release to be prepared before public
disclosure. The reporter and maintainers should agree on disclosure timing;
credit is offered unless the reporter prefers anonymity. Do not include secrets,
customer data, or unrelated proprietary source in the report.

Reports may cover the runtime libraries, `InnoFlowTesting`, compiler macros,
package/build behavior, and repository release automation. Vulnerabilities in
an upstream dependency are coordinated with that upstream project as needed.
