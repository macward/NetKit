import Testing
import Foundation
@testable import NetKit

// MARK: - Test Helpers

/// Thread-safe counter for testing concurrent operations.
private actor Counter {
    var value: Int = 0

    func increment() {
        value += 1
    }
}

/// Thread-safe boolean flag for testing concurrent operations.
private actor Flag {
    var value: Bool = false

    func set(_ newValue: Bool) {
        value = newValue
    }
}

/// Thread-safe results collector for testing concurrent operations.
private actor ResultsCollector {
    var successes: Int = 0
    var failures: Int = 0

    func recordSuccess() {
        successes += 1
    }

    func recordFailure() {
        failures += 1
    }
}

/// Test error type for refresh failures.
private enum RefreshError: Error {
    case failed
}

// MARK: - TokenRefreshCoordinator Tests

@Suite("TokenRefreshCoordinator Tests")
struct TokenRefreshCoordinatorTests {

    @Test("Single refresh call executes handler once")
    func singleRefreshCallExecutesOnce() async throws {
        let refreshCount = Counter()
        let coordinator = TokenRefreshCoordinator {
            await refreshCount.increment()
        }

        try await coordinator.refreshIfNeeded()

        let count = await refreshCount.value
        #expect(count == 1)
    }

    @Test("Multiple concurrent refreshes trigger only one refresh operation")
    func concurrentRefreshesTriggerOnlyOne() async throws {
        let refreshCount = Counter()
        let coordinator = TokenRefreshCoordinator {
            await refreshCount.increment()
            // Simulate network delay
            try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
        }

        // Launch multiple concurrent refresh requests
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    try? await coordinator.refreshIfNeeded()
                }
            }
        }

        let count = await refreshCount.value
        #expect(count == 1, "Expected exactly 1 refresh, got \(count)")
    }

    @Test("Waiters receive success when refresh succeeds")
    func waitersReceiveSuccess() async throws {
        let refreshCount = Counter()
        let results = ResultsCollector()

        let coordinator = TokenRefreshCoordinator {
            await refreshCount.increment()
            try await Task.sleep(nanoseconds: 50_000_000) // 0.05 seconds
        }

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    do {
                        try await coordinator.refreshIfNeeded()
                        await results.recordSuccess()
                    } catch {
                        await results.recordFailure()
                    }
                }
            }
        }

        let count = await refreshCount.value
        let successes = await results.successes
        let failures = await results.failures

        #expect(count == 1)
        #expect(successes == 5, "All waiters should succeed")
        #expect(failures == 0)
    }

    @Test("Waiters receive error when refresh fails")
    func waitersReceiveError() async throws {
        let results = ResultsCollector()

        let coordinator = TokenRefreshCoordinator {
            try await Task.sleep(nanoseconds: 50_000_000)
            throw RefreshError.failed
        }

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    do {
                        try await coordinator.refreshIfNeeded()
                        await results.recordSuccess()
                    } catch {
                        await results.recordFailure()
                    }
                }
            }
        }

        let failures = await results.failures
        #expect(failures == 5, "All waiters should receive the error")
    }

    @Test("Sequential refreshes after first completes trigger new refresh")
    func sequentialRefreshesAfterCompletion() async throws {
        let refreshCount = Counter()
        let coordinator = TokenRefreshCoordinator {
            await refreshCount.increment()
        }

        try await coordinator.refreshIfNeeded()
        try await coordinator.refreshIfNeeded()
        try await coordinator.refreshIfNeeded()

        let count = await refreshCount.value
        #expect(count == 3, "Each sequential call should trigger a refresh")
    }

    @Test("Refresh after failure allows new refresh")
    func refreshAfterFailureAllowsNewRefresh() async throws {
        let shouldFail = Flag()
        await shouldFail.set(true)
        let refreshCount = Counter()

        let coordinator = TokenRefreshCoordinator {
            await refreshCount.increment()
            if await shouldFail.value {
                throw RefreshError.failed
            }
        }

        // First call fails
        do {
            try await coordinator.refreshIfNeeded()
            Issue.record("Expected first refresh to fail")
        } catch {
            // Expected
        }

        // Second call should be allowed after failure
        await shouldFail.set(false)
        try await coordinator.refreshIfNeeded()

        let count = await refreshCount.value
        #expect(count == 2)
    }

    @Test("Cancelled waiter receives CancellationError")
    func cancelledWaiterReceivesCancellationError() async throws {
        let refreshStarted = Flag()
        let results = ResultsCollector()

        let coordinator = TokenRefreshCoordinator {
            await refreshStarted.set(true)
            // Simulate a long-running refresh
            try await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
        }

        // Start a task group where we launch the refresh and a waiter that will be cancelled
        await withTaskGroup(of: Void.self) { group in
            // Task 1: Start the refresh (will hold the lock)
            group.addTask {
                try? await coordinator.refreshIfNeeded()
            }

            // Wait for refresh to start
            while await !refreshStarted.value {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }

            // Task 2: Another waiter that will be cancelled
            let waiterTask = Task {
                do {
                    try await coordinator.refreshIfNeeded()
                    await results.recordSuccess()
                } catch is CancellationError {
                    await results.recordFailure() // Use failure to track cancellation
                } catch {
                    // Other error
                }
            }

            // Give waiter time to register
            try? await Task.sleep(nanoseconds: 50_000_000)

            // Cancel the waiter
            waiterTask.cancel()

            // Wait for the waiter task to complete
            _ = await waiterTask.value
        }

        let failures = await results.failures
        #expect(failures == 1, "Cancelled waiter should receive CancellationError")
    }

    @Test("Cancellation does not affect other waiters")
    func cancellationDoesNotAffectOtherWaiters() async throws {
        let refreshStarted = Flag()
        let successes = Counter()
        let cancellations = Counter()

        let coordinator = TokenRefreshCoordinator {
            await refreshStarted.set(true)
            try await Task.sleep(nanoseconds: 200_000_000) // 0.2 seconds
        }

        await withTaskGroup(of: Void.self) { group in
            // Task 1: Start the refresh
            group.addTask {
                try? await coordinator.refreshIfNeeded()
                await successes.increment()
            }

            // Wait for refresh to start
            while await !refreshStarted.value {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }

            // Task 2: A waiter that will complete successfully
            group.addTask {
                do {
                    try await coordinator.refreshIfNeeded()
                    await successes.increment()
                } catch {
                    // Should not happen
                }
            }

            // Task 3: A waiter that will be cancelled
            let cancelledTask = Task {
                do {
                    try await coordinator.refreshIfNeeded()
                } catch is CancellationError {
                    await cancellations.increment()
                } catch {
                    // Other error
                }
            }

            // Give waiters time to register
            try? await Task.sleep(nanoseconds: 50_000_000)

            // Cancel only one waiter
            cancelledTask.cancel()
            _ = await cancelledTask.value
        }

        let successCount = await successes.value
        let cancelCount = await cancellations.value

        #expect(successCount == 2, "Two tasks should complete successfully")
        #expect(cancelCount == 1, "One task should be cancelled")
    }
}

// MARK: - AuthInterceptor Coordinated Refresh Tests

@Suite("AuthInterceptor Coordinated Refresh Tests")
struct AuthInterceptorCoordinatedRefreshTests {

    @Test("Interceptor with coordinator handles 401")
    func interceptorWithCoordinatorHandles401() async throws {
        let refreshCalled = Flag()
        let coordinator = TokenRefreshCoordinator {
            await refreshCalled.set(true)
        }

        let interceptor = AuthInterceptor(
            tokenProvider: { "test-token" },
            refreshCoordinator: coordinator
        )

        let response = HTTPURLResponse(
            url: URL(string: "https://api.example.com")!,
            statusCode: 401,
            httpVersion: nil,
            headerFields: nil
        )!

        _ = try await interceptor.intercept(response: response, data: Data())

        let called = await refreshCalled.value
        #expect(called == true)
    }

    @Test("Interceptor with coordinator does not call refresh on non-401")
    func interceptorWithCoordinatorDoesNotCallOnNon401() async throws {
        let refreshCalled = Flag()
        let coordinator = TokenRefreshCoordinator {
            await refreshCalled.set(true)
        }

        let interceptor = AuthInterceptor(
            tokenProvider: { "test-token" },
            refreshCoordinator: coordinator
        )

        let response = HTTPURLResponse(
            url: URL(string: "https://api.example.com")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!

        _ = try await interceptor.intercept(response: response, data: Data())

        let called = await refreshCalled.value
        #expect(called == false)
    }

    @Test("Concurrent 401s with same coordinator trigger single refresh")
    func concurrent401sWithCoordinatorTriggerSingleRefresh() async throws {
        let refreshCount = Counter()
        let coordinator = TokenRefreshCoordinator {
            await refreshCount.increment()
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        let interceptor = AuthInterceptor(
            tokenProvider: { "test-token" },
            refreshCoordinator: coordinator
        )

        let response = HTTPURLResponse(
            url: URL(string: "https://api.example.com")!,
            statusCode: 401,
            httpVersion: nil,
            headerFields: nil
        )!

        // Simulate multiple concurrent 401 responses
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    _ = try? await interceptor.intercept(response: response, data: Data())
                }
            }
        }

        let count = await refreshCount.value
        #expect(count == 1, "Expected exactly 1 refresh, got \(count)")
    }

    @Test("Multiple interceptors sharing coordinator coordinate refreshes")
    func multipleInterceptorsSharingCoordinator() async throws {
        let refreshCount = Counter()
        let coordinator = TokenRefreshCoordinator {
            await refreshCount.increment()
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        let interceptor1 = AuthInterceptor(
            tokenProvider: { "token1" },
            refreshCoordinator: coordinator
        )

        let interceptor2 = AuthInterceptor(
            tokenProvider: { "token2" },
            refreshCoordinator: coordinator
        )

        let response = HTTPURLResponse(
            url: URL(string: "https://api.example.com")!,
            statusCode: 401,
            httpVersion: nil,
            headerFields: nil
        )!

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    _ = try? await interceptor1.intercept(response: response, data: Data())
                }
                group.addTask {
                    _ = try? await interceptor2.intercept(response: response, data: Data())
                }
            }
        }

        let count = await refreshCount.value
        #expect(count == 1, "Multiple interceptors with shared coordinator should trigger only 1 refresh")
    }

    @Test("Interceptor with coordinator propagates refresh errors")
    func interceptorWithCoordinatorPropagatesErrors() async throws {
        let coordinator = TokenRefreshCoordinator {
            throw RefreshError.failed
        }

        let interceptor = AuthInterceptor(
            tokenProvider: { "test-token" },
            refreshCoordinator: coordinator
        )

        let response = HTTPURLResponse(
            url: URL(string: "https://api.example.com")!,
            statusCode: 401,
            httpVersion: nil,
            headerFields: nil
        )!

        do {
            _ = try await interceptor.intercept(response: response, data: Data())
            Issue.record("Expected error to be thrown")
        } catch is RefreshError {
            // Expected
        }
    }
}

// MARK: - Legacy AuthInterceptor Tests (Backward Compatibility)

@Suite("AuthInterceptor Legacy Tests")
struct AuthInterceptorLegacyTests {

    @Test("Legacy onUnauthorized handler is called on 401")
    func legacyOnUnauthorizedCalledOn401() async throws {
        let handlerCalled = Flag()
        let interceptor = AuthInterceptor(
            tokenProvider: { "test-token" },
            onUnauthorized: { await handlerCalled.set(true) }
        )

        let response = HTTPURLResponse(
            url: URL(string: "https://api.example.com")!,
            statusCode: 401,
            httpVersion: nil,
            headerFields: nil
        )!

        _ = try await interceptor.intercept(response: response, data: Data())

        let called = await handlerCalled.value
        #expect(called == true)
    }

    @Test("Legacy onUnauthorized not called on non-401")
    func legacyOnUnauthorizedNotCalledOnNon401() async throws {
        let handlerCalled = Flag()
        let interceptor = AuthInterceptor(
            tokenProvider: { "test-token" },
            onUnauthorized: { await handlerCalled.set(true) }
        )

        let response = HTTPURLResponse(
            url: URL(string: "https://api.example.com")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!

        _ = try await interceptor.intercept(response: response, data: Data())

        let called = await handlerCalled.value
        #expect(called == false)
    }

    @Test("Interceptor without handler does not crash on 401")
    func interceptorWithoutHandlerDoesNotCrash() async throws {
        let interceptor = AuthInterceptor(
            tokenProvider: { "test-token" }
        )

        let response = HTTPURLResponse(
            url: URL(string: "https://api.example.com")!,
            statusCode: 401,
            httpVersion: nil,
            headerFields: nil
        )!

        let data = "error".data(using: .utf8)!
        let result = try await interceptor.intercept(response: response, data: data)

        #expect(result == data)
    }
}
