// MARK: - Todo.swift
// Todo 모델

import Foundation

struct Todo: Identifiable, Equatable, Codable, Sendable {
  let id: UUID
  var title: String
  var isCompleted: Bool
  var createdAt: Date

  init(id: UUID = UUID(), title: String, isCompleted: Bool = false, createdAt: Date = Date()) {
    self.id = id
    self.title = title
    self.isCompleted = isCompleted
    self.createdAt = createdAt
  }
}
