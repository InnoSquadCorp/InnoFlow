// MARK: - TodoApp.swift
// InnoFlow 샘플 앱 - Todo 관리 애플리케이션
// Copyright © 2025 InnoSquad. All rights reserved.

import InnoFlow
import SwiftUI

@main
struct TodoApp: App {
  var body: some Scene {
    WindowGroup {
      ContentView()
    }
  }
}

struct ContentView: View {
  var body: some View {
    NavigationStack {
      TodoListView()
    }
  }
}
