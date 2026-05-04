// List + detail + pagination without PhaseMap.
//
// This sample is intentionally phase-light: the list loads in pages, each row
// has its own child reducer, and the detail view reads the parent store
// directly. PhaseMap would add declarative noise here — see
// `AuthenticationFlowDemo.swift` for the phase-heavy counterpart.
//
// The key pieces:
//   * `ForEachReducer(state:action:reducer:)` so row reducers see their own
//     element and parent sees aggregate updates.
//   * `store.scope(collection:id:action:)` for detail views that project a
//     single row by id.
//   * Queue-based `.send(.loadNextPage)` for "load next page" chaining so
//     pagination is driven by the store FIFO rather than reducer re-entry.

import Foundation
import InnoFlow
import SwiftUI

// MARK: - Service

struct SampleArticle: Identifiable, Equatable, Sendable {
  let id: UUID
  let title: String
  let summary: String
  @BindableField var isFavorite = false

  init(id: UUID = UUID(), title: String, summary: String, isFavorite: Bool = false) {
    self.id = id
    self.title = title
    self.summary = summary
    self._isFavorite = BindableField(wrappedValue: isFavorite)
  }
}

protocol ArticlesServiceProtocol: Sendable {
  func loadPage(_ page: Int, pageSize: Int) async throws -> [SampleArticle]
  var pageCount: Int { get }
}

struct ArticlesServiceError: LocalizedError, Equatable, Sendable {
  let errorDescription: String?
}

actor SampleArticlesService: ArticlesServiceProtocol {
  let pageCount: Int = 3

  func loadPage(_ page: Int, pageSize: Int) async throws -> [SampleArticle] {
    guard page >= 0, page < pageCount else { return [] }
    let base = page * pageSize
    return (0..<pageSize).map { offset in
      let index = base + offset
      return SampleArticle(
        id: UUID(),
        title: "Article #\(index + 1)",
        summary: "Paginated summary for item \(index + 1)"
      )
    }
  }
}

// MARK: - Row feature

@InnoFlow
struct SampleArticleRowFeature {
  typealias State = SampleArticle

  enum Action: Equatable, Sendable {
    case toggleFavorite
    case setFavorite(Bool)
  }

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .toggleFavorite:
        state.isFavorite.toggle()
        return .none
      case .setFavorite(let value):
        state.isFavorite = value
        return .none
      }
    }
  }
}

// MARK: - Parent feature

@InnoFlow
struct ListDetailPaginationFeature {
  struct Dependencies: Sendable {
    let articlesService: any ArticlesServiceProtocol
  }

  struct State: Equatable, Sendable, DefaultInitializable {
    var articles: [SampleArticle] = []
    var currentPage: Int = -1
    var isLoading: Bool = false
    var hasReachedEnd: Bool = false
    var errorMessage: String?
  }

  struct LoadedPage: Equatable, Sendable {
    let articles: [SampleArticle]
    let page: Int
  }

  enum Action: Equatable, Sendable {
    case loadFirstPage
    case loadNextPage
    case retryAfterError
    case article(id: UUID, action: SampleArticleRowFeature.Action)
    case _loaded(LoadedPage)
    case _failed(String)
  }

  let dependencies: Dependencies

  init(
    dependencies: Dependencies = .init(articlesService: SampleArticlesService())
  ) {
    self.dependencies = dependencies
  }

  init(articlesService: any ArticlesServiceProtocol) {
    self.init(dependencies: .init(articlesService: articlesService))
  }

  var body: some Reducer<State, Action> {
    CombineReducers {
      Reduce { state, action in
        switch action {
        case .loadFirstPage:
          state.articles = []
          state.currentPage = -1
          state.isLoading = false
          state.hasReachedEnd = false
          state.errorMessage = nil
          return .concatenate(
            .cancel("list-pagination"),
            .send(.loadNextPage)
          )

        case .loadNextPage:
          guard !state.isLoading, !state.hasReachedEnd else { return .none }
          let nextPage = state.currentPage + 1
          state.isLoading = true
          state.errorMessage = nil
          let service = dependencies.articlesService
          return .run { send, _ in
            do {
              let page = try await service.loadPage(nextPage, pageSize: 4)
              await send(._loaded(.init(articles: page, page: nextPage)))
            } catch {
              await send(._failed(error.localizedDescription))
            }
          }
          .cancellable("list-pagination", cancelInFlight: true)

        case .retryAfterError:
          state.errorMessage = nil
          return .send(.loadNextPage)

        case ._loaded(let loadedPage):
          state.isLoading = false
          state.currentPage = loadedPage.page
          if loadedPage.articles.isEmpty {
            state.hasReachedEnd = true
          } else {
            state.articles.append(contentsOf: loadedPage.articles)
          }
          return .none

        case ._failed(let message):
          state.isLoading = false
          state.errorMessage = message
          return .none

        case .article:
          return .none
        }
      }

      ForEachReducer(
        state: \.articles,
        action: Action.articleActionPath,
        reducer: SampleArticleRowFeature()
      )
    }
  }
}

// MARK: - View

struct ListDetailPaginationDemoView: View {
  @State private var store = Store(reducer: ListDetailPaginationFeature())
  @State private var selectedArticleID: UUID?

  var body: some View {
    NavigationStack {
      List {
        Section {
          DemoCard(
            title: "What this demonstrates",
            summary:
              "Queue-driven pagination. Each row is a `ForEachReducer` child, and the detail view uses `scope(collection:id:action:)` to project a single article by id."
          )
        }

        Section("Articles") {
          let articleStores = store.scope(
            collection: \.articles,
            action: ListDetailPaginationFeature.Action.articleActionPath
          )
          if articleStores.isEmpty, !store.isLoading {
            Text("No articles yet. Tap Load.")
              .font(.footnote)
              .foregroundStyle(.secondary)
          }

          ForEach(articleStores) { rowStore in
            NavigationLink(value: rowStore.id) {
              SampleArticleRowView(store: rowStore)
            }
          }

          if store.isLoading {
            HStack {
              ProgressView()
              Text("Loading...")
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("list.loading")
          } else if store.hasReachedEnd {
            Text("End of feed")
              .font(.footnote)
              .foregroundStyle(.secondary)
              .accessibilityIdentifier("list.end-of-feed")
          } else if store.currentPage < 0 {
            Button("Load First Page") {
              store.send(.loadFirstPage)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("list.load-first-page")
          } else {
            Button("Load Next Page") {
              store.send(.loadNextPage)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("list.load-next-page")
          }

          if let errorMessage = store.errorMessage {
            VStack(alignment: .leading, spacing: 6) {
              Text(errorMessage)
                .font(.footnote)
                .foregroundStyle(.red)
                .accessibilityIdentifier("list.error-message")
              Button("Retry") {
                store.send(.retryAfterError)
              }
              .buttonStyle(.bordered)
              .accessibilityIdentifier("list.retry")
            }
          }
        }
      }
      .navigationTitle("List + Detail")
      .navigationDestination(for: UUID.self) { id in
        ListDetailPaginationDetailView(parentStore: store, articleID: id)
      }
    }
  }
}

struct SampleArticleRowView: View {
  let store:
    ScopedStore<
      ListDetailPaginationFeature,
      SampleArticle,
      SampleArticleRowFeature.Action
    >

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      VStack(alignment: .leading, spacing: 4) {
        Text(store.title)
          .font(.headline)
          .accessibilityIdentifier("list.row.\(store.id)")
        Text(store.summary)
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
      Spacer()
      Button {
        store.send(.toggleFavorite)
      } label: {
        Image(systemName: store.isFavorite ? "heart.fill" : "heart")
      }
      .buttonStyle(.borderless)
      .accessibilityLabel(store.isFavorite ? "Unfavorite" : "Favorite")
      .accessibilityIdentifier("list.favorite.\(store.id)")
    }
  }
}

struct ListDetailPaginationDetailView: View {
  let parentStore: Store<ListDetailPaginationFeature>
  let articleID: UUID

  var body: some View {
    // Per-id collection scope is exposed on `TestStore` only. At runtime we
    // fetch the full scoped list and filter by id — `ScopedStore` identity is
    // preserved per element so observers for unrelated rows are undisturbed.
    let articleStores = parentStore.scope(
      collection: \.articles,
      action: ListDetailPaginationFeature.Action.articleActionPath
    )
    if let scoped = articleStores.first(where: { $0.id == articleID }) {
      DetailContent(store: scoped)
    } else {
      Text("Article removed.")
        .foregroundStyle(.secondary)
    }
  }

  private struct DetailContent: View {
    let store:
      ScopedStore<
        ListDetailPaginationFeature,
        SampleArticle,
        SampleArticleRowFeature.Action
      >

    var body: some View {
      VStack(alignment: .leading, spacing: 12) {
        Text(store.title)
          .font(.largeTitle.bold())
        Text(store.summary)
          .font(.body)
        Toggle(
          "Favorite",
          isOn: store.binding(\.$isFavorite, to: SampleArticleRowFeature.Action.setFavorite)
        )
        .accessibilityIdentifier("list.detail.favorite-toggle")
        Spacer()
      }
      .padding()
      .navigationTitle("Article")
    }
  }
}

#Preview("List + Detail") {
  ListDetailPaginationDemoView()
}
