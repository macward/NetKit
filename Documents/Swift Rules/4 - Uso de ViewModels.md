```
## ViewModel Usage in SwiftUI

Use `@State` directly in the view when:
- Logic is simple and affects only that view
- No external dependencies are required
- State changes are local (toggles, form fields, UI state)

Use a ViewModel with `@Observable` when ANY of these apply:
- Complex business logic that benefits from testing
- External dependencies need to be injected (services, repositories)
- Async operations (network calls, database queries)
- State is shared or needs coordination across multiple concerns

### Examples

// ✅ @State - Simple, local, no dependencies
struct ExpandableCard: View {
    @State private var isExpanded = false
    // ...
}

// ✅ ViewModel - Has external dependency
@Observable
final class ProductDetailViewModel {
    private let cartService: CartServiceProtocol
    // ...
}

// ✅ ViewModel - Complex logic / async
@Observable
final class CheckoutViewModel {
    func processPayment() async throws { ... }
}

### Decision Flow
1. Does it need an external dependency? → ViewModel
2. Is the logic complex or async? → ViewModel  
3. Otherwise → @State

```