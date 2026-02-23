// MARK: - TodoRowView.swift
// 개별 Todo 항목 뷰

import SwiftUI

struct TodoRowView: View {
  let todo: Todo
  let onToggle: () -> Void
  let onEdit: (String) -> Void
  let onDelete: () -> Void

  @State private var isEditing = false
  @State private var editedTitle: String = ""
  @FocusState private var isTextFieldFocused: Bool

  var body: some View {
    HStack(spacing: 12) {
      // 완료 체크박스
      Button(action: onToggle) {
        Image(systemName: todo.isCompleted ? "checkmark.circle.fill" : "circle")
          .font(.title2)
          .foregroundColor(todo.isCompleted ? .green : .gray)
      }
      .buttonStyle(.plain)

      // Todo 제목
      if isEditing {
        TextField("", text: $editedTitle)
          .textFieldStyle(.plain)
          .focused($isTextFieldFocused)
          .onSubmit {
            saveEdit()
          }
          .onAppear {
            editedTitle = todo.title
            isTextFieldFocused = true
          }
      } else {
        Text(todo.title)
          .strikethrough(todo.isCompleted)
          .foregroundColor(todo.isCompleted ? .secondary : .primary)
          .onTapGesture(count: 2) {
            startEditing()
          }
      }

      Spacer()

      // 편집/삭제 버튼
      if !isEditing {
        Menu {
          Button("편집") {
            startEditing()
          }

          Button(role: .destructive, action: onDelete) {
            Label("삭제", systemImage: "trash")
          }
        } label: {
          Image(systemName: "ellipsis")
            .foregroundColor(.secondary)
        }
      }
    }
    .padding(.vertical, 8)
    .contentShape(Rectangle())
  }

  private func startEditing() {
    isEditing = true
    editedTitle = todo.title
  }

  private func saveEdit() {
    if !editedTitle.trimmingCharacters(in: .whitespaces).isEmpty {
      onEdit(editedTitle)
    }
    isEditing = false
  }
}
