# TestFlowTask public consumer

Build and run the default target against the repository's supported Swift 6.3/6.4
Apple toolchains. It imports only Core and Testing, uses generic/protocol wrappers,
checks Sendable, and exercises root, scoped, phase, and explicit Void-adapter calls.

Set `INNOFLOW_CONSUMER_PACKAGE_PATH` to an absolute package path when needed.
`INNOFLOW_TESTFLOWTASK_NEGATIVE=1 swift build` must fail at the assignment to the
legacy `async -> Void` method value. Ordinary send statements remain compatible;
wrappers can explicitly discard the new handle. The negative fixture is not a
runtime failure or a missing dependency check.
