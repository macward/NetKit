```
## Architecture & Patterns

### Layers

View → ViewModel (when needed) → Repository → Service/Database

### ViewModels

- Use ViewModel when the view has complex logic, multiple states, or needs unit testing
- Simple views can use @State + @Environment directly without ViewModel
- One ViewModel per root screen
- ALWAYS use final class
- Do NOT import SwiftUI unless strictly necessary for navigation types
- NEVER put business logic directly in Views

### Dependency Injection

- ALWAYS use @Environment for sharing services and state across views
- NEVER use singletons or shared instances
- Inject dependencies at the App root level
- ViewModels receive dependencies via init injection

### Async/Await

- ALWAYS use async/await, NEVER completion handlers
- ALWAYS mark ViewModels with @MainActor
- Use .task modifier for async work in Views
- Use AsyncStream for continuous data streams (WebSockets, listeners, delegate conversions)
- NEVER use DispatchQueue.main.async — use MainActor instead
- NEVER use try! in async code

### Error Handling

- ViewModels catch errors and expose state (error property)
- Do NOT propagate errors to Views with throws
- Views react to error state, they don't handle errors directly

### Task Cancellation

- .task modifier handles cancellation automatically when View disappears
- For long loops or operations, check Task.isCancelled or use try Task.checkCancellation()
- AsyncStream MUST handle cleanup in onTermination

### Navigation

- Navigation approach is not yet defined
- When implementing navigation, prefer solutions that:
  - Use NavigationStack with path binding
  - Support deep linking
  - Keep navigation state centralized
  - Are compatible with @Observable

### Naming Conventions

- ALWAYS use full names, never abbreviations
- Views: `HomeView`, `LoginView`
- ViewModels: `HomeViewModel`, `LoginViewModel`
- Repositories: `UserRepository`, `AuthRepository`
- Services: `APIService`, `StorageService`

### Patterns to Avoid

- Completion handlers
- `DispatchQueue.main.async`
- `Task { @MainActor in }` when already on MainActor
- `.task` with nested `Task { }` inside
- Force try (`try!`) in async code
- Singletons or shared instances

```