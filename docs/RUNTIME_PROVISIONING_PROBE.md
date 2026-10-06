# Legacy runtime diagnostic probe

The manual Runtime Provisioning Probe is prepared for explicit publication/execution approval. It has not run in the VM and never installs Apple runtimes on a user computer. It only executes on GitHub-hosted runners and main.

Four isolated macos-26/Xcode 26.6 jobs reuse the existing exact-version download/import logic. One iOS 18.5 job additionally runs the reviewed focused runtime inventory. A macos-15/Xcode 26.3 job records its installed Swift version and runtime catalog. Raw environment, import errors, catalog, and smoke result are retained separately. No release receipt is emitted.

W0-2 routing is deliberately unchanged until actual probe results justify a supported runtime/toolchain pair. Never substitute another OS version or count diagnostic success as the final 28-check required Preflight. W0-4 release environment protection is a separate administrator/security approval and is not changed by this workflow.
