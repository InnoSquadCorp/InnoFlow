# SwiftUI conveniences and Inspector

The optional InnoFlowSwiftUI product supplies six presentation adapters: innoFlowSheet, innoFlowFullScreenCover outside macOS, innoFlowNavigationDestination, innoFlowPopover outside tvOS/watchOS, innoFlowAlert and innoFlowConfirmationDialog. State controls presentation and the explicit onDismiss action returns ownership to the reducer. Route stacks remain outside InnoFlow.

Alert and confirmation dialog title overloads mirror SwiftUI: LocalizedStringKey for localized keys/literals, StringProtocol for dynamic text, and Text for an explicit title. Stored method values may require an adapter for the generic StringProtocol form. macOS never enters a hidden full-screen-cover fallback; that helper and internal case are unavailable there.

Use innoFlowTask(store, action:) for view-owned work, or its id: form when changing input should restart it. The underlying SwiftUI task cancels only the dispatch it started and joins physical work through FlowTask.finish. A pre-cancelled task does not send. Parent, sibling and unrelated Store work are unaffected; uncooperative operations are not declared finished early. Core-only contract tests exercise cancellation/replacement, while Apple tests must verify actual SwiftUI mounting and overload resolution.

InnoFlowInspector is a separate product depending only on Core. Mount FlowInspector behind an app-controlled DEBUG presentation. It shows a display-only phase graph/current node, bounded active-dispatch/recent-event diagnostics and optional anonymous scheduler lane admission snapshots. Labels are explicitly supplied; feature State and action/output payloads are never inspected or logged. Lane head admission is not physical running-work count. tvOS/watchOS use a compact list, without platform-specific developer controls. The Phase-Driven FSM sample includes a DEBUG Inspector entry.

Learning progression is Level 1 (Reduce, Store, BindableField, TestStore), Level 2 (Scope, ForEach, select, Output), Level 3 (lifetimes, run lanes, PhaseMap, diagnostics, Inspector). Existing sample screens are grouped by that progression. The new optional-child model and tests demonstrate close/reopen of one business ID with fresh instance identities; they add no navigation or persistence feature.

Apple SDK compilation, localization runtime behavior, animation and Inspector rendering are not certified by Linux mirror tests. These remain explicit Apple CI checks before release.

The task lifecycle follows [Apple's SwiftUI task documentation](https://developer.apple.com/documentation/swiftui/view/task(id:name:priority:file:line:_:)); alerts follow [Apple's alert documentation](https://developer.apple.com/documentation/swiftui/view/alert(_:item:actions:message:)).

The independent Tests/Fixtures/SwiftUIConsumer target exercises literal, LocalizedStringKey, String, Substring and styled Text titles; both view-task forms; and all platform-available presentation helpers. Its gate refuses Linux with exit2 rather than claiming an SDK-free pass. Source parsing and Core lifetime tests cannot certify SwiftUI overload selection or localization/rendering. The target and sample UI tests require the supported Apple platform matrix.
