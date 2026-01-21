# Task 003: Sensitive Data Sanitization in Logs

**Completed**: 2026-01-21
**Branch**: task/003-logging-data-sanitization
**Status**: Done

## Summary

Implemented comprehensive sensitive data sanitization in `LoggingInterceptor` to prevent accidental exposure of tokens, passwords, and API keys in logs. Created a reusable `SanitizationConfig` module that sanitizes headers, URL query parameters, and JSON body fields.

## Changes

### Added
- `Sources/NetKit/Core/SanitizationConfig.swift` - New sanitization configuration struct with:
  - Configurable sets of sensitive headers, query params, and body fields
  - `sanitizeHeaders()` - Redacts sensitive header values
  - `sanitizeURL()` - Redacts sensitive query parameter values
  - `sanitizeBody()` - Redacts sensitive fields in JSON bodies (recursive)
  - Presets: `.default`, `.none`, `.strict`
  - Performance limit: body sanitization only for JSON < 10KB

### Modified
- `Sources/NetKit/Interceptors/LoggingInterceptor.swift`:
  - Added `sanitization` parameter to init (default: `.default`)
  - All logged data now passes through sanitization
  - Headers, URLs, and bodies are sanitized in verbose mode

- `Sources/NetKit/Models/NetworkError.swift`:
  - Removed local `sensitiveHeaders` and `sanitizeHeaders()` (moved to shared module)
  - Uses `sanitizeHeadersWithDefaultConfig()` for backward compatibility

- `Tests/NetKitTests/NetKitTests.swift`:
  - Added 30+ tests for sanitization functionality
  - Tests cover headers, URLs, bodies, nested JSON, arrays, and edge cases

## Files Changed
- `Sources/NetKit/Core/SanitizationConfig.swift` (created)
- `Sources/NetKit/Interceptors/LoggingInterceptor.swift` (modified)
- `Sources/NetKit/Models/NetworkError.swift` (modified)
- `Tests/NetKitTests/NetKitTests.swift` (modified)
- `tasks/003-logging-data-sanitization.task` (modified)

## API Usage

```swift
// Default sanitization (recommended)
let interceptor = LoggingInterceptor(level: .verbose)

// Custom sanitization
let customConfig = SanitizationConfig(
    sensitiveHeaders: ["X-Custom-Auth"],
    sensitiveQueryParams: ["custom_token"],
    sensitiveBodyFields: ["customSecret"]
)
let interceptor = LoggingInterceptor(level: .verbose, sanitization: customConfig)

// Disable sanitization (debugging only)
let interceptor = LoggingInterceptor(level: .verbose, sanitization: .none)
```

## Default Sensitive Fields

**Headers**: authorization, x-api-key, api-key, x-auth-token, cookie, set-cookie, x-csrf-token, x-xsrf-token, proxy-authorization, x-access-token

**Query Params**: token, api_key, apikey, password, secret, access_token, refresh_token, auth, key, credential

**Body Fields**: password, secret, token, api_key, apiKey, access_token, accessToken, refresh_token, refreshToken, credential, credentials, private_key, privateKey

## Notes

- Sanitization is applied recursively to nested JSON objects and arrays
- Body sanitization is skipped for non-JSON content types
- Body sanitization is skipped for bodies larger than `maxBodySizeForSanitization` (default 10KB)
- Backward compatibility maintained: `RequestSnapshot` and `ResponseSnapshot` continue to work unchanged
