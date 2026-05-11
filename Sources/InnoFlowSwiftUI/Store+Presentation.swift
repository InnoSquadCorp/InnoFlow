// MARK: - Store+Presentation.swift
// InnoFlow - SwiftUI integration
// Copyright © 2025 InnoSquad. All rights reserved.

@_exported public import InnoFlowCore
public import SwiftUI

extension View {
  /// Presents a sheet driven by an optional slice of a `Store`'s state.
  ///
  /// The sheet is shown while `store.state[keyPath: state]` is non-nil. When
  /// SwiftUI dismisses the sheet (via a swipe, programmatic dismiss, or any
  /// other route), the helper sends `onDismiss()` to the parent store so the
  /// reducer can clear the underlying optional state. Pair this with an
  /// `IfLet` child reducer that scopes off the same key path.
  ///
  /// The content closure receives the *unwrapped* child state captured at the
  /// moment of presentation; it does not maintain its own subscription. For
  /// SwiftUI views that need to observe child mutations, scope a child store
  /// at the call site (`store.scope(state: ..., action: ...)`) and pass it
  /// to the destination view.
  public func innoFlowSheet<R: Reducer, Child>(
    store: Store<R>,
    state stateKeyPath: KeyPath<R.State, Child?>,
    onDismiss: @escaping @Sendable () -> R.Action,
    @ViewBuilder content: @escaping (Child) -> some View
  ) -> some View {
    modifier(
      InnoFlowOptionalPresentation(
        store: store,
        stateKeyPath: stateKeyPath,
        onDismiss: onDismiss,
        style: .sheet,
        destinationContent: content
      )
    )
  }

  /// Presents a full-screen cover driven by an optional slice of a `Store`'s
  /// state. See ``innoFlowSheet(store:state:onDismiss:content:)`` for the
  /// underlying contract; this overload uses
  /// `View.fullScreenCover(isPresented:)` instead.
  #if !os(macOS)
    public func innoFlowFullScreenCover<R: Reducer, Child>(
      store: Store<R>,
      state stateKeyPath: KeyPath<R.State, Child?>,
      onDismiss: @escaping @Sendable () -> R.Action,
      @ViewBuilder content: @escaping (Child) -> some View
    ) -> some View {
      modifier(
        InnoFlowOptionalPresentation(
          store: store,
          stateKeyPath: stateKeyPath,
          onDismiss: onDismiss,
          style: .fullScreenCover,
          destinationContent: content
        )
      )
    }
  #endif

  /// Pushes a destination onto a parent `NavigationStack` when an optional
  /// slice of state becomes non-nil. SwiftUI's
  /// `navigationDestination(isPresented:)` modifier owns the actual stack
  /// surface; this helper only adapts the optional-state contract.
  public func innoFlowNavigationDestination<R: Reducer, Child>(
    store: Store<R>,
    state stateKeyPath: KeyPath<R.State, Child?>,
    onDismiss: @escaping @Sendable () -> R.Action,
    @ViewBuilder content: @escaping (Child) -> some View
  ) -> some View {
    modifier(
      InnoFlowOptionalPresentation(
        store: store,
        stateKeyPath: stateKeyPath,
        onDismiss: onDismiss,
        style: .navigationDestination,
        destinationContent: content
      )
    )
  }
}

private enum InnoFlowPresentationStyle {
  case sheet
  case fullScreenCover
  case navigationDestination
}

private struct InnoFlowOptionalPresentation<R: Reducer, Child, Destination: View>: ViewModifier {
  let store: Store<R>
  let stateKeyPath: KeyPath<R.State, Child?>
  let onDismiss: @Sendable () -> R.Action
  let style: InnoFlowPresentationStyle
  let destinationContent: (Child) -> Destination

  @MainActor
  private var isPresentedBinding: Binding<Bool> {
    Binding(
      get: { store.state[keyPath: stateKeyPath] != nil },
      set: { newValue in
        // SwiftUI only writes `false` here — the present-true edge is owned
        // by the reducer that produced the non-nil state. Translate the
        // false write into a dismiss action so the reducer can clear state.
        guard newValue == false else { return }
        guard store.state[keyPath: stateKeyPath] != nil else { return }
        store.send(onDismiss())
      }
    )
  }

  func body(content: Content) -> some View {
    switch style {
    case .sheet:
      content.sheet(isPresented: isPresentedBinding) {
        snapshotDestination
      }
    case .fullScreenCover:
      #if os(macOS)
        // macOS has no fullScreenCover; fall back to a sheet so the helper
        // keeps a uniform contract across platforms when authors gate on
        // availability themselves.
        content.sheet(isPresented: isPresentedBinding) {
          snapshotDestination
        }
      #else
        content.fullScreenCover(isPresented: isPresentedBinding) {
          snapshotDestination
        }
      #endif
    case .navigationDestination:
      content.navigationDestination(isPresented: isPresentedBinding) {
        snapshotDestination
      }
    }
  }

  @ViewBuilder
  private var snapshotDestination: some View {
    if let child = store.state[keyPath: stateKeyPath] {
      destinationContent(child)
    } else {
      // SwiftUI may briefly evaluate the destination builder after the
      // reducer has cleared optional state but before the binding write
      // has settled. Render nothing rather than crashing.
      EmptyView()
    }
  }
}
