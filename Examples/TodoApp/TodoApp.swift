// MARK: - TodoApp.swift
// Compatibility launcher that mirrors the package-backed sample app shell.

import SwiftUI
import TodoAppFeature

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
