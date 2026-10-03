# Level 1 external consumer

This executable uses only Reduce, Store, BindableField and TestStore through canonical macro authoring. It deliberately does not need PhaseMap, lanes, scopes, diagnostics or Inspector. Run scripts/check-level-one-consumer.sh. INNOFLOW_PACKAGE_PATH selects an independently frozen candidate for validation. It belongs outside the root product dependency graph.
