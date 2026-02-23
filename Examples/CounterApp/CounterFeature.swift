// MARK: - CounterFeature.swift
// 간단한 카운터 기능을 위한 Reducer

import Foundation
import InnoFlow

/// 카운터 기능을 관리하는 Feature
/// Effect가 없는 간단한 예제
@InnoFlow
struct CounterFeature {
    
    // MARK: - State
    
    struct State: Equatable, Sendable, DefaultInitializable {
        var count = 0
        var step = BindableProperty(1)
    }
    
    // MARK: - Action
    
    enum Action: Equatable, Sendable {
        case increment
        case decrement
        case reset
        case setStep(Int)
    }

    // MARK: - Reduce

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
