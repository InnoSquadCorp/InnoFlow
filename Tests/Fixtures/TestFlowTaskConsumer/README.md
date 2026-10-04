# Testing dispatch public consumer

Build and run the default target against the repository's supported Swift 6.3/6.4
Apple toolchains. It imports only Core and Testing, uses generic/protocol wrappers,
checks Sendable, and exercises root, scoped, phase, and explicit Void-adapter calls.

Set `INNOFLOW_CONSUMER_PACKAGE_PATH` to an absolute package path when needed.
`INNOFLOW_TESTFLOWTASK_NEGATIVE=1 swift build` must fail at the assignment to the
legacy `async -> Void` method value. Ordinary send statements remain compatible;
wrappers can explicitly discard the new handle. The negative fixture is not a
runtime failure or a missing dependency check.

The 6.0 freeze also verifies the single canonical handle name, complete source
coordinates on new APIs, preserved stable file:line: calls, reducer: lifetime
labels and an exhaustive EffectAdmission switch. Sixteen draft-only forms have
independent negative compiler controls; each compiled against the prior c874a85
development source and must fail for its intended diagnostic after the freeze.
