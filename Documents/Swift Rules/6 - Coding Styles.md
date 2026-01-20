```
## Code Style

### Formatting

- Use guard for early exit
- Explicit type annotations: `let value: String = "text"`
- Use trailing closure only for single closure, not multiple
- Use self only when required (closures, ambiguity)
- Use optional shorthand: `if let value { }` not `if let value = value { }`
- ALWAYS mark access control explicitly on all types and members (public, internal, private)

### File Organization

- Use `// MARK: -` to separate sections (Properties, Lifecycle, Public Methods, Private Methods)
- Separate protocol conformances into extensions

### Tooling

- Use SwiftLint with default rules
```