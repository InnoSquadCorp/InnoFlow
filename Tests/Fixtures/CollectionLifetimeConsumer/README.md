# Collection lifetime initializer contract

This independent Core-only package checks existing IfCaseLet constructor calls,
the explicit lifetimeID overload, and a closure adapter for the old initializer
function type. The negative source must reject an unwrapped previous four-argument
initializer reference because the canonical initializer now captures source
coordinates. CasePath's cache identity remains unchanged.

Run scripts/check-collection-lifetime-consumer.sh. For an explicitly documented
validation mirror, set INNOFLOW_CONSUMER_PACKAGE_PATH to that package directory.
The Linux mirror does not replace the pinned Apple compiler and release checks.
