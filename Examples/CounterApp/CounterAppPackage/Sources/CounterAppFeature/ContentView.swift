import SwiftUI
import InnoFlow

// MARK: - CounterFeature

@InnoFlow
struct CounterFeature {
    
    struct State: Equatable, Sendable, DefaultInitializable {
        var count = 0
        var step = BindableProperty(1)
    }
    
    enum Action: Equatable, Sendable {
        case increment
        case decrement
        case reset
        case setStep(Int)
    }
    
    func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
        switch action {
        case .increment:
            state.count += state.step.value
            return .none
            
        case .decrement:
            state.count -= state.step.value
            return .none
            
        case .reset:
            state.count = 0
            return .none
            
        case .setStep(let step):
            state.step.value = max(1, step)
            return .none
        }
    }
}

// MARK: - CounterView

public struct ContentView: View {
    @State private var store = Store(reducer: CounterFeature())
    
    public var body: some View {
        VStack(spacing: 30) {
            Text("\(store.count)")
                .font(.system(size: 72, weight: .bold))
                .foregroundColor(store.count == 0 ? .secondary : .primary)
            
            HStack(spacing: 20) {
                Button(action: { store.send(.decrement) }) {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 44))
                }
                .buttonStyle(.bordered)
                
                Button(action: { store.send(.reset) }) {
                    Text("리셋")
                        .font(.headline)
                        .frame(width: 80)
                }
                .buttonStyle(.bordered)
                .disabled(store.count == 0)
                
                Button(action: { store.send(.increment) }) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 44))
                }
                .buttonStyle(.bordered)
            }
            
            Divider()
                .padding(.vertical)
            
            VStack(spacing: 12) {
                Text("증감 단위: \(store.step)")
                    .font(.headline)
                
                Stepper(
                    "스텝",
                    value: store.binding(\.step, send: { .setStep($0) }),
                    in: 1...10
                )
                .labelsHidden()
            }
            .padding()
            .background(Color(.systemGray6))
            .cornerRadius(12)
        }
        .padding()
        .navigationTitle("카운터")
        .navigationBarTitleDisplayMode(.large)
    }
    
    public init() {}
}
