# Task 014: Add Maximum Delay Cap to RetryPolicy

**Completed**: 2026-01-22
**Branch**: task/014-retry-policy-max-delay
**Status**: Done

## Summary

Added a configurable maximum delay cap to prevent exponential backoff from producing unreasonably long delays. Previously, attempt 30 would produce ~34 years of delay due to unbounded exponential growth.

## Changes

### Modified

- `Sources/NetKit/Retry/RetryPolicy.swift`
  - Added `maxDelay: TimeInterval = 60` parameter to `RetryDelay.exponential` case
  - Apply `min(calculatedDelay, maxDelay)` in delay calculation
  - Jitter applied after capping to guarantee delay never exceeds max
  - Updated default delay in both `RetryPolicy` initializers

- `Tests/NetKitTests/NetKitTests.swift`
  - Added test for exponential delay capping behavior
  - Added test for large attempt numbers (overflow prevention)
  - Added test for default maxDelay value
  - Added test for jitter not exceeding maxDelay (100 iterations)

## Files Changed

- `Sources/NetKit/Retry/RetryPolicy.swift` (modified)
- `Tests/NetKitTests/NetKitTests.swift` (modified)

## Commits

- `f4e4d5c` fix: add maximum delay cap to RetryPolicy exponential backoff

## Notes

- Default maxDelay is 60 seconds, which is reasonable for most use cases
- Jitter is applied after capping, creating asymmetric behavior when capped (negative jitter applies, positive is clamped). This is intentional to guarantee the delay never exceeds maxDelay.
- API is fully backward compatible - existing code continues to work without modification
