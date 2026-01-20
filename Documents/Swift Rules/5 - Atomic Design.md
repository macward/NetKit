```
## Component Hierarchy in SwiftUI

### Levels

**Controls**
- Smallest indivisible UI elements
- Single responsibility
- No external dependencies
- No ViewModel
- Configured entirely through parameters

**Composites**
- Combine controls into a functional unit
- No external dependencies
- No ViewModel
- Receive data and emit events through callbacks
- Should remain reusable across different contexts

**Components**
- Combine composites and controls into complete sections
- Can have a ViewModel
- Can have external dependencies injected
- Coordinate child elements and connect them to business logic

### Decision Rules

1. If indivisible → Control
2. If it combines controls but has no business logic → Composite
3. If it needs a ViewModel or external dependencies → Component

### Key Principle

Controls and composites stay pure and reusable. Components own the intelligence and coordination.
```