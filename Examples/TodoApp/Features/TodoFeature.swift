// MARK: - TodoFeature.swift
// Todo 기능을 위한 Reducer

import Foundation
import InnoFlow

/// Todo 목록을 관리하는 Feature
@InnoFlow
struct TodoFeature {
    
    // MARK: - State
    
    struct State: Equatable, Sendable, DefaultInitializable {
        var todos: [Todo] = []
        var isLoading = false
        var errorMessage: String?
        var filter = BindableProperty(Filter.all)
        
        enum Filter: String, CaseIterable, Equatable, Sendable {
            case all = "전체"
            case active = "미완료"
            case completed = "완료"
        }
        
        var filteredTodos: [Todo] {
            switch filter.value {
            case .all:
                return todos
            case .active:
                return todos.filter { !$0.isCompleted }
            case .completed:
                return todos.filter { $0.isCompleted }
            }
        }
        
        var completedCount: Int {
            todos.filter { $0.isCompleted }.count
        }
        
        var activeCount: Int {
            todos.filter { !$0.isCompleted }.count
        }
    }
    
    // MARK: - Action
    
    enum Action: Equatable, Sendable {
        // UI Actions
        case loadTodos
        case addTodo(String)
        case toggleTodo(UUID)
        case deleteTodo(UUID)
        case deleteCompleted
        case setFilter(State.Filter)
        case editTodo(UUID, String)
        case dismissError
        
        // Internal Actions (from effects)
        case _todosLoaded([Todo])
        case _loadFailed(String)
    }
    
    // MARK: - Dependencies
    
    let todoService: TodoServiceProtocol
    
    init(todoService: TodoServiceProtocol = TodoService.shared) {
        self.todoService = todoService
    }
    
    // MARK: - Reduce
    
    func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
        switch action {
        // UI Actions
        case .loadTodos:
            state.isLoading = true
            state.errorMessage = nil
            let todoService = self.todoService
            return .run { send in
                do {
                    let todos = try await todoService.loadTodos()
                    await send(._todosLoaded(todos))
                } catch {
                    await send(._loadFailed(error.localizedDescription))
                }
            }
            .cancellable("todo-load", cancelInFlight: true)
            
        case .addTodo(let title):
            guard !title.trimmingCharacters(in: .whitespaces).isEmpty else {
                return .none
            }
            let newTodo = Todo(title: title)
            state.todos.append(newTodo)
            return saveTodosEffect(state.todos)
            
        case .toggleTodo(let id):
            if let index = state.todos.firstIndex(where: { $0.id == id }) {
                state.todos[index].isCompleted.toggle()
            }
            return saveTodosEffect(state.todos)
            
        case .deleteTodo(let id):
            state.todos.removeAll { $0.id == id }
            return saveTodosEffect(state.todos)
            
        case .deleteCompleted:
            state.todos.removeAll { $0.isCompleted }
            return saveTodosEffect(state.todos)
            
        case .setFilter(let filter):
            state.filter.value = filter
            return .none
            
        case .editTodo(let id, let newTitle):
            if let index = state.todos.firstIndex(where: { $0.id == id }) {
                state.todos[index].title = newTitle
            }
            return saveTodosEffect(state.todos)
            
        // Internal Actions
        case ._todosLoaded(let todos):
            state.todos = todos
            state.isLoading = false
            state.errorMessage = nil
            return .none
            
        case ._loadFailed(let error):
            state.isLoading = false
            state.errorMessage = error
            return .none
            
        case .dismissError:
            state.errorMessage = nil
            return .none
        }
    }

    private func saveTodosEffect(_ todos: [Todo]) -> EffectTask<Action> {
        let todoService = self.todoService
        return .run { _ in
            try? await todoService.saveTodos(todos)
        }
        .cancellable("todo-save", cancelInFlight: true)
    }
}
