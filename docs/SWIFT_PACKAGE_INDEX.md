# Swift Package Index

The root [`.spi.yml`](../.spi.yml) uses SPI manifest version 1 and points to
the existing [InnoFlow DocC site](https://innosquadcorp.github.io/InnoFlow/documentation/innoflow/).
This follows the [SPI external-documentation configuration](https://swiftpackageindex.com/swiftpackageindex/spimanifest/documentation/spimanifest/commonusecases).
The manifest uses JSON syntax, which is also valid YAML, matching the InnoDI
and InnoRouter repository convention.

## Registration evidence

On 2026-09-30, the official [SPI PackageList](https://github.com/SwiftPackageIndex/PackageList/blob/main/packages.json)
contained `https://github.com/InnoSquadCorp/InnoFlow.git`; no duplicate registration
request is needed. The [public SPI listing](https://swiftpackageindex.com/InnoSquadCorp/InnoFlow)
is available. The retrieved page snapshot is dated 2026-08-26 and shows 5.1.1,
so it is not evidence that unreleased 6.0.0 or today's main has been freshly indexed.

## Package and documentation boundaries

- `InnoFlow` is the macro-first authoring facade. Its documentation shares the
  main site with `InnoFlowCore`, the compiler-plugin-free runtime product.
- `InnoFlowSwiftUI` contains the separate SwiftUI integration product. The
  current DocC generator does not produce a separate symbol-graph site for
  this target; its supported usage is described in the README and source.
  The SPI external link does not claim additional generated coverage.
- `InnoFlowInspector` is an opt-in development diagnostic UI product. Its dependency
  is Core only; it reads bounded payload-free diagnostics, and it does not add a
  compiler plugin, test runtime or separate SPI package. Apple UI validation is
  required before claiming platform support for a particular candidate.
- `InnoFlowTesting` is a test-only product. Its generated documentation is
  published under the main site's `testing/documentation/innoflowtesting/` path.
- `InnoFlowMacros` is an implementation target, not a public library product
  or a separate SPI package. The example and compiler-reproducer packages
  are also not represented as additional products by this manifest.

[`Tools/generate-docc.sh`](../Tools/generate-docc.sh) owns generation, combining
`InnoFlowCore` and `InnoFlow` and generating `InnoFlowTesting` separately.
It uses a temporary documentation package and the pinned
[`Tools/docc-package.resolved`](../Tools/docc-package.resolved) tool graph.
The consumer manifest continues to carry only its existing SwiftSyntax
dependency; SPI integration must not add a DocC plugin to `Package.swift`.

## Validation and operational limits

Run `python3 scripts/check-package-index.py` and
`python3 -m unittest discover -s scripts/tests -p 'test_package_index_policy.py'`
for offline configuration, product-inventory, and dependency-boundary checks.
`scripts/check-community-health.sh` includes the configuration check.
These checks do not prove that SPI has indexed the repository or that the live
documentation is current. Maintainers must verify the SPI listing and published
DocC entry after separately approved deployment or release work.

The external documentation URL serves the current Pages deployment, which may
describe `main` rather than the version a consumer has installed. Use the
exact release's DocC asset and matching tagged source for version-specific
review. Do not treat this URL as immutable candidate evidence.

Do not add builder overrides that pretend an unavailable Swift/Xcode version
passed. SPI build availability is separate from the hosted release evidence
policy: missing support does not waive any of InnoFlow's 32 preflight checks.
See [RELEASING.md](../RELEASING.md), [MACRO_OPERATIONS.md](MACRO_OPERATIONS.md),
and the [OSS policy](OSS_POLICY.md).
