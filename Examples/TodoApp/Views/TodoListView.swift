// MARK: - TodoListView.swift
// Todo 목록 뷰

import InnoFlow
import SwiftUI

struct TodoListView: View {
  @State private var store = Store(reducer: TodoFeature())
  @State private var newTodoTitle = ""
  @FocusState private var isTextFieldFocused: Bool

  var body: some View {
    VStack(spacing: 0) {
      // 헤더
      headerView

      // 필터 선택
      filterView

      // Todo 목록
      if store.isLoading {
        ProgressView()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if store.filteredTodos.isEmpty {
        emptyStateView
      } else {
        todoListView
      }

      // 입력 필드
      inputView
    }
    .navigationTitle("할 일")
    .navigationBarTitleDisplayMode(.large)
    .toolbar {
      ToolbarItem(placement: .navigationBarTrailing) {
        if store.completedCount > 0 {
          Button("완료 삭제") {
            store.send(.deleteCompleted)
          }
          .foregroundColor(.red)
        }
      }
    }
    .task {
      // 앱 시작 시 저장된 Todo 로드
      store.send(.loadTodos)
    }
    .alert(
      "오류",
      isPresented: Binding(
        get: { store.errorMessage != nil },
        set: { _ in }
      )
    ) {
      Button("확인", role: .cancel) {
        store.send(.dismissError)
      }
    } message: {
      if let error = store.errorMessage {
        Text(error)
      }
    }
  }

  // MARK: - Header View

  private var headerView: some View {
    VStack(spacing: 8) {
      HStack {
        Text("전체: \(store.todos.count)")
          .font(.caption)
          .foregroundColor(.secondary)
        Spacer()
        Text("완료: \(store.completedCount)")
          .font(.caption)
          .foregroundColor(.green)
        Spacer()
        Text("미완료: \(store.activeCount)")
          .font(.caption)
          .foregroundColor(.orange)
      }
      .padding(.horizontal)
      .padding(.vertical, 8)
    }
    .background(Color(.systemGray6))
  }

  // MARK: - Filter View

  private var filterView: some View {
    Picker(
      "필터",
      selection: store.binding(
        \.filter,
        send: { .setFilter($0) }
      )
    ) {
      ForEach(TodoFeature.State.Filter.allCases, id: \.self) { filter in
        Text(filter.rawValue).tag(filter)
      }
    }
    .pickerStyle(.segmented)
    .padding()
  }

  // MARK: - Todo List View

  private var todoListView: some View {
    List {
      ForEach(store.filteredTodos) { todo in
        TodoRowView(todo: todo) {
          store.send(.toggleTodo(todo.id))
        } onEdit: { newTitle in
          store.send(.editTodo(todo.id, newTitle))
        } onDelete: {
          store.send(.deleteTodo(todo.id))
        }
      }
    }
    .listStyle(.plain)
  }

  // MARK: - Empty State View

  private var emptyStateView: some View {
    VStack(spacing: 16) {
      Image(systemName: "checklist")
        .font(.system(size: 60))
        .foregroundColor(.secondary)

      Text(store.filter == .all ? "할 일이 없습니다" : "\(store.filter.rawValue) 항목이 없습니다")
        .font(.title2)
        .foregroundColor(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  // MARK: - Input View

  private var inputView: some View {
    HStack {
      TextField("새 할 일 추가", text: $newTodoTitle)
        .textFieldStyle(.roundedBorder)
        .focused($isTextFieldFocused)
        .onSubmit {
          addTodo()
        }

      Button(action: addTodo) {
        Image(systemName: "plus.circle.fill")
          .font(.title2)
          .foregroundColor(newTodoTitle.isEmpty ? .gray : .blue)
      }
      .disabled(newTodoTitle.isEmpty)
    }
    .padding()
    .background(Color(.systemBackground))
  }

  // MARK: - Actions

  private func addTodo() {
    guard !newTodoTitle.trimmingCharacters(in: .whitespaces).isEmpty else { return }
    store.send(.addTodo(newTodoTitle))
    newTodoTitle = ""
    isTextFieldFocused = false
  }
}
