# Logging

## LoggingInterceptor

Log requests and responses with automatic sensitive data sanitization:

```swift
let loggingInterceptor = LoggingInterceptor(level: .verbose)
// Levels: .none, .minimal, .verbose

let client = NetworkClient(
    environment: APIEnvironment(),
    interceptors: [loggingInterceptor]
)
```

## Sensitive Data Sanitization

By default, `LoggingInterceptor` automatically redacts sensitive data:

- **Headers**: Authorization, X-API-Key, Cookie, etc.
- **Query Parameters**: token, api_key, password, secret, etc.
- **JSON Body Fields**: password, secret, token, credentials, etc.

### Default Sanitization (Recommended)

```swift
let interceptor = LoggingInterceptor(level: .verbose)
```

### Custom Sanitization Rules

```swift
let customConfig = SanitizationConfig(
    sensitiveHeaders: ["X-Custom-Auth", "X-Secret"],
    sensitiveQueryParams: ["custom_token"],
    sensitiveBodyFields: ["customPassword", "apiSecret"]
)
let interceptor = LoggingInterceptor(level: .verbose, sanitization: customConfig)
```

### Disable Sanitization (Debugging Only)

```swift
// NOT for production
let interceptor = LoggingInterceptor(level: .verbose, sanitization: .none)
```

### Strict Mode (PCI Compliance)

```swift
let interceptor = LoggingInterceptor(level: .verbose, sanitization: .strict)
```

## Example Output

With sanitization enabled:

```
➡️ POST https://api.example.com/login?token=[REDACTED]
   Headers: ["Authorization": "[REDACTED]", "Content-Type": "application/json"]
   Body: {"username":"john","password":"[REDACTED]"}
```
