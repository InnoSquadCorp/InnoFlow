# Getting Started

Create a reducer, hold it in a ``Store``, and send actions from SwiftUI.

```swift
import InnoFlow
import SwiftUI

@InnoFlow
struct CounterFeature {
  @ObservableState
  struct State {
    var count = 0
  }

  enum Action {
    case increment
    case decrement
  }

  var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .increment:
        state.count += 1
        return .none
      case .decrement:
        state.count -= 1
        return .none
      }
    }
  }
}
```

For more complex features, keep reducers focused on business state and move explicit
phase transitions into a documented phase graph. See <doc:PhaseDrivenModeling>.
