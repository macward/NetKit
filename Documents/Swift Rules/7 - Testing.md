```
## Testing Guidelines

### Framework

- Use Swift Testing (@Test), not XCTest

### Naming

- Function names: `subjectAction` or `subjectActionCondition`
- ALWAYS add descriptive string to @Test macro

@Test("User login fails when password is empty")
func userLoginFailsEmptyPassword() async throws { 
    // this is a nice way to check how it works
}

### Mocks

- Use protocols for dependencies
- Create manual mock implementations for tests
- Do NOT use mocking libraries

### Coverage

**For Apps:**

- ALWAYS test ViewModels
- ALWAYS test Repositories
- Services: test only if they contain logic
- Do NOT write unit tests for Views

**For Packages:**

- ALWAYS test public API thoroughly
- Test internal logic only if complex
- Do NOT test private implementation details

## Build & Run Commands

**ALWAYS use xcodebuild for building, testing, and all project operations. Never use `swift build`, `swift test`, or other alternatives.**

- `xcodebuild -scheme <SchemeName> -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build` - Build project
- `xcodebuild -scheme <SchemeName> -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test` - Run tests
- `swiftlint` - Run linter
```