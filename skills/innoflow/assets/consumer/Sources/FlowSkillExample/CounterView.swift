import InnoFlow
import InnoFlowSwiftUI
import SwiftUI

struct CounterView: View {
    let store: Store<CounterFeature>
    var body: some View {
        VStack {
            Text("Count: \(store.state.count)")
            Stepper("Step", value: store.binding(\.$step, to: CounterFeature.Action.setStep))
            Button("Increment") { store.send(.increment) }
        }
    }
}
