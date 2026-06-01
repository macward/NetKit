import Foundation
import Testing
import NetKit
@testable import NetKitMacros

// `assertMacroExpansion` exercises the macro plugin directly, which is a host
// (macOS) tool — see Package.swift. The import and the expansion test are macOS-only.
#if os(macOS)
import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
@testable import NetKitMacrosImpl
#endif

// MARK: - Generated endpoint fixtures

// A GET endpoint declared entirely through the macro. The macro generates the
// `path` (interpolating `@Path id`), the `method`, and the `: Endpoint`
// conformance; the developer only declares the stored property and `Response`.
@GET("/users/{id}")
private struct GetUserEndpoint {
    typealias Response = EmptyResponse
    @Path var id: String
}

// A bodiless GET with no placeholders — confirms a static path round-trips.
@GET("/health")
private struct HealthEndpoint {
    typealias Response = EmptyResponse
}

// Exercises the literal-escaping branch of the template parser: the path contains
// characters (`"` and `\`) that must be escaped when emitted as a string literal.
@GET("/say/{word}/\"q\"\\x")
private struct EscapedPathEndpoint {
    typealias Response = EmptyResponse
    @Path var word: String
}

// MARK: - Test environment

private struct TestEnvironment: NetworkEnvironment {
    let baseURL: URL = URL(string: "https://api.example.com")!
}

// MARK: - End-to-end behavior

@Test("Generated GET resolves runtime @Path values into the URL path")
func generatedPathResolvesRuntimeValue() throws {
    let endpoint = GetUserEndpoint(id: "123")

    #expect(endpoint.path == "/users/123")

    let request = try URLRequest(endpoint: endpoint, environment: TestEnvironment())
    #expect(request.url?.path == "/users/123")
    #expect(request.httpMethod == "GET")
}

@Test("Generated path reflects updated instance values on each read")
func generatedPathIsComputedPerRead() {
    var endpoint = GetUserEndpoint(id: "1")
    #expect(endpoint.path == "/users/1")

    endpoint.id = "999"
    #expect(endpoint.path == "/users/999")
}

@Test("Generated method returns .get for @GET")
func generatedMethodIsGet() {
    let endpoint = GetUserEndpoint(id: "1")
    #expect(endpoint.method == .get)
}

@Test("Generated endpoint conforms to Endpoint via the synthesized extension")
func generatedEndpointConformsToEndpoint() {
    func requireEndpoint<E: Endpoint>(_ value: E) -> E { value }
    let endpoint = requireEndpoint(GetUserEndpoint(id: "1"))
    #expect(endpoint.path == "/users/1")
}

@Test("Static path with no placeholders round-trips unchanged")
func staticPathRoundTrips() throws {
    let endpoint = HealthEndpoint()
    #expect(endpoint.path == "/health")

    let request = try URLRequest(endpoint: endpoint, environment: TestEnvironment())
    #expect(request.url?.path == "/health")
    #expect(request.httpMethod == "GET")
}

@Test("Template characters that need escaping survive into the resolved path")
func escapedCharactersResolveInPath() {
    let endpoint = EscapedPathEndpoint(word: "hi")
    #expect(endpoint.path == "/say/hi/\"q\"\\x")
}

// MARK: - Macro expansion

#if os(macOS)
private let testMacros: [String: any Macro.Type] = [
    "GET": GETMacro.self,
    "Path": PathMacro.self
]

@Test("@GET expands to computed path, method and Endpoint extension")
func getMacroExpansion() {
    assertMacroExpansion(
        """
        @GET("/users/{id}")
        struct GetUser {
            typealias Response = EmptyResponse
            @Path var id: String
        }
        """,
        expandedSource: """
        struct GetUser {
            typealias Response = EmptyResponse
            var id: String

            var path: String {
                "/users/\\(id)"
            }

            var method: HTTPMethod {
                .get
            }
        }

        extension GetUser: Endpoint {
        }
        """,
        macros: testMacros
    )
}
#endif
