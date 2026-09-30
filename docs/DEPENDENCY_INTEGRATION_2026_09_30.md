# Dependency integration, 2026-09-30

This integrates the changes proposed by [PR 42](https://github.com/InnoSquadCorp/InnoFlow/pull/42)
and [PR 40](https://github.com/InnoSquadCorp/InnoFlow/pull/40) into PR 48. It does
not merge or close either source PR, publish a release or change live settings.

## Exact inputs

- Main: `5a17eebacc2603ad31420ca70121aa47fa421510`
- PR 48 before integration: `cbb3cbe5161f8ed94d675aacab25c54ad74e5ad8`
- PR 42: `8d08a56aeb5f38d8f744425db30720c8d4383598`
- PR 40: `86fd37eb0b6449d7f88d5be087807e46eb3c5f2f`

Every current checkout action, including the new trusted coordinator/publisher,
uses 7.0.1 at `3d3c42e5aac5ba805825da76410c181273ba90b1`. Release publication
uses action-gh-release 3.0.3 at `efb35369e0ad2afab669f228072c1b0d510eae64`.
The old deploy-pages action was already removed by PR 48's API-only publisher;
it is not reintroduced merely to apply PR 42's now-inapplicable third action bump.
No unsafe checkout opt-in, write scope or credential persistence is added.

SwiftSyntax is 604.0.0 at `050f1a346fbbac0ca2cfb15a95274f7bd1cf0ccf` in all four
live locks. Root, sample-package and the exact temporary DocC manifest were
resolved with official SwiftPM 6.3.3. The Xcode workspace pin is synchronized,
but its existing Xcode-owned originHash is preserved for hosted Apple validation;
Linux cannot regenerate that Xcode workspace metadata. DocC plugin/SymbolKit
versions and revisions remain unchanged. Frozen DocC/sample resolution remains.

## Compatibility and performance boundary

Swift tools 6.3, primary Xcode 26.6, all platform floors, public/runtime sources,
coverage/runtime performance thresholds, existing job timeouts and the 32 release
checks are unchanged. The bounded 603/604 manifest admits no 605 line. Two new
blocking CI lanes cover 603.0.0 on Swift 6.3 and 604.0.0 on Swift 6.4, including
macro and external compile contracts with warnings-as-errors. Existing full CI
validates committed 604 on the primary toolchain.

An isolated Linux VM probe used official Swift 6.3.3 and the unchanged actual
InnoFlow macro target, fresh separate build directories, two compiler jobs and
warnings-as-errors. Both default SwiftPM invocations built SwiftSyntax from source:

| Resolution | Result | One cold-build wall time |
| --- | --- | --- |
| 603.0.1 baseline | Passed | 140.45 s |
| 604.0.0 candidate | Passed | 119.30 s |

A separate macro-only diagnostic harness used the unchanged actual
`Sources/InnoFlowMacros` and `Tests/InnoFlowMacrosTests` files with the same Swift
6 language/upcoming-feature settings. Both 604.0.0 and the advertised 603.0.0
floor passed all 68 macro tests with warnings-as-errors on Swift 6.3.3. That
harness excludes Apple runtime products and cannot replace their hosted tests.

These are one-run diagnostics, not statistically calibrated results or an Apple
performance guarantee. They establish source-build compatibility and measure the
clean-build cost required by the existing macro operations policy. They do not
replace hosted macro/runtime tests, budgets or release evidence.

The current hosted primary reports Apple Swift 6.3.3
`swiftlang-6.3.3.1.3`; its Xcode 26.6 image uses the `macosx26.5` SDK. SwiftPM's
[official manifest naming implementation](https://github.com/swiftlang/swift-package-manager/blob/swift-6.3.3-RELEASE/Sources/PackageModel/PrebuiltLibrary.swift)
combines that compiler version with the SDK canonical name. The official
[603.0.2 manifest](https://download.swift.org/prebuilts/swift-syntax/603.0.2/swiftlang-6.3.3.1.3-macosx26.5.json)
returned HTTP 200, while the corresponding 603.0.1 and 604.0.0 URLs returned 404.
This is an availability observation, not a signature/artifact-use proof. A green
default build does not demonstrate matching prebuilt use. Flow has an existing
explicit source fallback path; DI's separate matching-prebuilt requirement is
not imported as a new Flow policy. Hosted CI must still validate the final SHA.
