# Task 016: Add Token Refresh Coordination to AuthInterceptor

**Completed**: 2026-01-22
**Branch**: task/016-fix-auth-interceptor-race
**Status**: Done

## Summary
Added `TokenRefreshCoordinator` actor to prevent multiple concurrent 401 responses from triggering multiple simultaneous token refresh operations, which could cause auth state corruption and wasted API calls.

## Changes

### Added
- `TokenRefreshCoordinator` actor in `AuthInterceptor.swift` for coordinating concurrent token refreshes
- New `AuthInterceptor` initializer that accepts a `TokenRefreshCoordinator` for coordinated refresh behavior
- Comprehensive test suite in `AuthInterceptorTests.swift` covering:
  - Single and concurrent refresh scenarios
  - Success and failure propagation to waiters
  - Sequential refresh behavior after completion
  - Multiple interceptors sharing a coordinator
  - Legacy backward compatibility

### Modified
- `AuthInterceptor.swift` - Added coordinator-based refresh path alongside existing `onUnauthorized` handler

## Files Changed
- `Sources/NetKit/Interceptors/AuthInterceptor.swift` (modified)
- `Tests/NetKitTests/AuthInterceptorTests.swift` (created)

## Notes
- The implementation uses Swift actors for clean, race-condition-free coordination
- Uses `CheckedContinuation` to suspend concurrent requests waiting for refresh
- Backward compatible: existing `onUnauthorized` pattern still works
- No timeout added for refresh operations - the refresh handler itself should implement timeouts if needed
