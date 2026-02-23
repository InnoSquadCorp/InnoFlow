// MARK: - TodoService.swift
// Todo 데이터 영속성을 위한 서비스

import Foundation

/// Todo 데이터를 관리하는 프로토콜
protocol TodoServiceProtocol: Sendable {
  func loadTodos() async throws -> [Todo]
  func saveTodos(_ todos: [Todo]) async throws
}

/// UserDefaults를 사용한 Todo 서비스 구현
actor TodoService: TodoServiceProtocol {
  static let shared = TodoService()

  private let key = "saved_todos"

  func loadTodos() async throws -> [Todo] {
    guard let data = UserDefaults.standard.data(forKey: key) else {
      return []  // 초기 상태: 빈 배열
    }

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode([Todo].self, from: data)
  }

  func saveTodos(_ todos: [Todo]) async throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(todos)
    UserDefaults.standard.set(data, forKey: key)
  }
}
