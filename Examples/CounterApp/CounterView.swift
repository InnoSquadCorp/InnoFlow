// MARK: - CounterView.swift
// 카운터 뷰

import SwiftUI
import InnoFlow

struct CounterView: View {
    @State private var store = Store(reducer: CounterFeature())
    
    var body: some View {
        VStack(spacing: 30) {
            // 카운터 표시
            Text("\(store.count)")
                .font(.system(size: 72, weight: .bold))
                .foregroundColor(store.count == 0 ? .secondary : .primary)
            
            // 버튼들
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
            
            // 스텝 설정
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
}

#Preview {
    NavigationStack {
        CounterView()
    }
}


