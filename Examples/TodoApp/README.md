# TodoApp - iOS App

A modern iOS application using a **workspace + SPM package** architecture for clean separation between app shell and feature code.

## AI Assistant Rules Files

This template includes **opinionated rules files** for popular AI coding assistants. These files establish coding standards, architectural patterns, and best practices for modern iOS development using the latest APIs and Swift features.

### Included Rules Files
- **Claude Code**: `CLAUDE.md` - Claude Code rules
- **Cursor**: `.cursor/*.mdc` - Cursor-specific rules
- **GitHub Copilot**: `.github/copilot-instructions.md` - GitHub Copilot rules

### Customization Options
These rules files are **starting points** - feel free to:
- ✅ **Edit them** to match your team's coding standards
- ✅ **Delete them** if you prefer different approaches
- ✅ **Add your own** rules for other AI tools
- ✅ **Update them** as new iOS APIs become available

### What Makes These Rules Opinionated
- **No ViewModels**: Embraces pure SwiftUI state management patterns
- **Swift 6+ Concurrency**: Enforces modern async/await over legacy patterns
- **Latest APIs**: Recommends iOS 18+ features with optional iOS 26 guidelines
- **Testing First**: Promotes Swift Testing framework over XCTest
- **Performance Focus**: Emphasizes @Observable over @Published for better performance

## Example Focus

This sample now demonstrates `InnoFlow`'s recommended **phase-driven FSM** pattern for
domain state.

- `TodoFeature.State.phase` models the high-level lifecycle (`idle`, `loading`, `loaded`, `failed`).
- `TodoFeature.phaseGraph` documents the legal transitions.
- `TodoAppFeatureTests` verifies reducer actions against the graph with `TestStore`.

The sample intentionally keeps navigation and transport lifecycle concerns outside this phase
graph so `TodoFeature` remains a business-state example rather than a generic automata demo.

### Phase Graph

`TodoFeature` exposes a small, explicit graph for its business lifecycle:

```swift
static let phaseGraph: PhaseTransitionGraph<State.Phase> = [
    .idle: [.loading],
    .loading: [.loaded, .failed],
    .loaded: [.loading],
    .failed: [.idle, .loading],
]
```

This keeps the reducer contract unchanged while making legal transitions visible to readers and
tests.

### Test Pattern

The package test target validates reducer actions against the documented phase graph:

```swift
let store = TestStore(
    reducer: TodoFeature(todoService: MockTodoService(todos: [todo]))
)

await store.send(.loadTodos, tracking: \.phase, through: TodoFeature.phaseGraph) {
    $0.phase = .loading
    $0.errorMessage = nil
}

await store.receive(._todosLoaded([todo]), tracking: \.phase, through: TodoFeature.phaseGraph) {
    $0.phase = .loaded
    $0.todos = [todo]
}
```

If a reducer path introduces an illegal transition, the `TestStore` helper fails immediately with
the offending `from -> to` phase change.

**Note for AI assistants**: You MUST read the relevant rules files before making changes to ensure consistency with project standards.

## Project Architecture

```
TodoApp/
├── TodoApp.xcworkspace/              # Open this file in Xcode
├── TodoApp.xcodeproj/                # App shell project
├── TodoApp/                          # App target (minimal)
│   ├── Assets.xcassets/                # App-level assets (icons, colors)
│   ├── TodoAppApp.swift              # App entry point
│   └── TodoApp.xctestplan            # Test configuration
├── TodoAppPackage/                   # 🚀 Primary development area
│   ├── Package.swift                   # Package configuration
│   ├── Sources/TodoAppFeature/       # Your feature code
│   └── Tests/TodoAppFeatureTests/    # Unit tests
└── TodoAppUITests/                   # UI automation tests
```

## Key Architecture Points

### Workspace + SPM Structure
- **App Shell**: `TodoApp/` contains minimal app lifecycle code
- **Feature Code**: `TodoAppPackage/Sources/TodoAppFeature/` is where most development happens
- **Separation**: Business logic lives in the SPM package, app target just imports and displays it
- **Canonical Source**: The package target is the single source of truth for `TodoFeature` and `TodoListView`

### Buildable Folders (Xcode 16)
- Files added to the filesystem automatically appear in Xcode
- No need to manually add files to project targets
- Reduces project file conflicts in teams

## Development Notes

### Code Organization
Most development happens in `TodoAppPackage/Sources/TodoAppFeature/` - organize your code as you prefer.

### Public API Requirements
Types exposed to the app target need `public` access:
```swift
public struct NewView: View {
    public init() {}
    
    public var body: some View {
        // Your view code
    }
}
```

### Adding Dependencies
Edit `TodoAppPackage/Package.swift` to add SPM dependencies:
```swift
dependencies: [
    .package(url: "https://github.com/example/SomePackage", from: "1.0.0")
],
targets: [
    .target(
        name: "TodoAppFeature",
        dependencies: ["SomePackage"]
    ),
]
```

### Test Structure
- **Unit Tests**: `TodoAppPackage/Tests/TodoAppFeatureTests/` (Swift Testing framework)
- **UI Tests**: `TodoAppUITests/` (XCUITest framework)
- **Test Plan**: `TodoApp.xctestplan` coordinates all tests

## Configuration

### XCConfig Build Settings
Build settings are managed through **XCConfig files** in `Config/`:
- `Config/Shared.xcconfig` - Common settings (bundle ID, versions, deployment target)
- `Config/Debug.xcconfig` - Debug-specific settings  
- `Config/Release.xcconfig` - Release-specific settings
- `Config/Tests.xcconfig` - Test-specific settings

### Entitlements Management
App capabilities are managed through a **declarative entitlements file**:
- `Config/TodoApp.entitlements` - All app entitlements and capabilities
- AI agents can safely edit this XML file to add HealthKit, CloudKit, Push Notifications, etc.
- No need to modify complex Xcode project files

### Asset Management
- **App-Level Assets**: `TodoApp/Assets.xcassets/` (app icon, accent color)
- **Feature Assets**: Add `Resources/` folder to SPM package if needed

### SPM Package Resources
To include assets in your feature package:
```swift
.target(
    name: "TodoAppFeature",
    dependencies: [],
    resources: [.process("Resources")]
)
```

### Generated with XcodeBuildMCP
This project was scaffolded using [XcodeBuildMCP](https://github.com/cameroncooke/XcodeBuildMCP), which provides tools for AI-assisted iOS development workflows.
