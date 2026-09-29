// MARK: - Store+Presentation.swift
// InnoFlow - SwiftUI integration
// Copyright © 2025 InnoSquad. All rights reserved.

@_exported public import InnoFlowCore
public import SwiftUI

extension Store {
  /// Creates a live Boolean presentation binding for an optional state slice.
  ///
  /// The reducer owns presentation by making the slice non-nil. SwiftUI owns
  /// interactive dismissal, which this binding translates back into one
  /// explicit action.
  public func presentationBinding<Child>(
    state stateKeyPath: KeyPath<R.State, Child?>,
    onDismiss: @escaping @Sendable () -> R.Action
  ) -> Binding<Bool> {
    Binding(
      get: { self.state[keyPath: stateKeyPath] != nil },
      set: { newValue in
        guard newValue == false else { return }
        guard self.state[keyPath: stateKeyPath] != nil else { return }
        self.send(onDismiss())
      }
    )
  }
}

@MainActor
package func innoFlowOptionalPresentationBinding<R: Reducer, Child>(
  store: Store<R>,
  state stateKeyPath: KeyPath<R.State, Child?>,
  onDismiss: @escaping @Sendable () -> R.Action
) -> Binding<Bool> {
  store.presentationBinding(state: stateKeyPath, onDismiss: onDismiss)
}

extension View {
  /// Presents a sheet driven by an optional slice of a `Store`'s state.
  ///
  /// The sheet is shown while `store.state[keyPath: state]` is non-nil. When
  /// SwiftUI dismisses the sheet (via a swipe, programmatic dismiss, or any
  /// other route), the helper sends `onDismiss()` to the parent store so the
  /// reducer can clear the underlying optional state. Pair this with an
  /// `IfLet` child reducer that scopes off the same key path.
  ///
  /// The content closure receives the currently rendered *unwrapped* child
  /// state. The helper re-reads `store.state[keyPath: state]` whenever SwiftUI
  /// evaluates the destination builder, but it does not maintain a child-store
  /// subscription of its own. For SwiftUI views that need to observe child
  /// mutations, scope a child store at the call site
  /// (`store.scope(state: ..., action: ...)`) and pass it to the destination
  /// view.
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

  #if !os(tvOS) && !os(watchOS)
    /// Presents a popover driven by an optional state slice.
    ///
    /// SwiftUI does not provide popovers on tvOS or watchOS, so this adapter
    /// is intentionally absent from those platform surfaces.
    public func innoFlowPopover<R: Reducer, Child>(
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
          style: .popover,
          destinationContent: content
        )
      )
    }
  #endif

  /// Presents an alert driven by an optional state slice.
  public func innoFlowAlert<R: Reducer, Child, Actions: View, Message: View>(
    _ title: String,
    store: Store<R>,
    state stateKeyPath: KeyPath<R.State, Child?>,
    onDismiss: @escaping @Sendable () -> R.Action,
    @ViewBuilder actions: @escaping (Child) -> Actions,
    @ViewBuilder message: @escaping (Child) -> Message
  ) -> some View {
    alert(
      title,
      isPresented: store.presentationBinding(state: stateKeyPath, onDismiss: onDismiss),
      presenting: store.state[keyPath: stateKeyPath],
      actions: actions,
      message: message
    )
  }

  /// Presents a confirmation dialog driven by an optional state slice.
  public func innoFlowConfirmationDialog<R: Reducer, Child, Actions: View, Message: View>(
    _ title: String,
    store: Store<R>,
    state stateKeyPath: KeyPath<R.State, Child?>,
    onDismiss: @escaping @Sendable () -> R.Action,
    @ViewBuilder actions: @escaping (Child) -> Actions,
    @ViewBuilder message: @escaping (Child) -> Message
  ) -> some View {
    confirmationDialog(
      title,
      isPresented: store.presentationBinding(state: stateKeyPath, onDismiss: onDismiss),
      presenting: store.state[keyPath: stateKeyPath],
      actions: actions,
      message: message
    )
  }
}

private enum InnoFlowPresentationStyle {
  case sheet
  case fullScreenCover
  case navigationDestination
  #if !os(tvOS) && !os(watchOS)
    case popover
  #endif
}

private struct InnoFlowOptionalPresentation<R: Reducer, Child, Destination: View>: ViewModifier {
  let store: Store<R>
  let stateKeyPath: KeyPath<R.State, Child?>
  let onDismiss: @Sendable () -> R.Action
  let style: InnoFlowPresentationStyle
  let destinationContent: (Child) -> Destination

  @MainActor
  private var isPresentedBinding: Binding<Bool> {
    store.presentationBinding(state: stateKeyPath, onDismiss: onDismiss)
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
    #if !os(tvOS) && !os(watchOS)
      case .popover:
        content.popover(isPresented: isPresentedBinding) {
          snapshotDestination
        }
    #endif
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
