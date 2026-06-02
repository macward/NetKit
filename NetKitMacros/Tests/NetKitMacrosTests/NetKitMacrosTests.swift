import Foundation
import Testing
import NetKit
@testable import NetKitMacros

// End-to-end behavior tests for the generated endpoints — these run on every platform.
// The `assertMacroExpansion` syntax-tree tests are a macOS-only host tool and live in
// MacroExpansionTests.swift.

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

// MARK: - Query & body fixtures

// The payload used to exercise `@Body` type-erasure. Encodable so it round-trips
// through `URLRequest`, Equatable so tests can compare the erased value.
private struct Article: Codable, Equatable, Sendable {
    let title: String
}

// A POST declared through the macro with both a `@Body` and a `@Query`. The macro
// generates `queryParameters` containing `draft` and `body` returning `article`.
@POST("/articles")
private struct CreateArticleEndpoint {
    typealias Response = EmptyResponse
    @Body var article: Article
    @Query var draft: Bool
}

// Hand-written equivalent of `CreateArticleEndpoint` — the parity tests assert the
// generated endpoint is observably indistinguishable from this manual struct.
private struct ManualCreateArticle: Endpoint {
    typealias Response = EmptyResponse
    let article: Article
    let draft: Bool

    var path: String { "/articles" }
    var method: HTTPMethod { .post }
    var queryParameters: [String: String] { ["draft": "\(draft)"] }
    var body: (any Encodable & Sendable)? { article }
}

// An optional `@Query`: a `nil` value is omitted from `queryParameters`.
@GET("/search")
private struct SearchEndpoint {
    typealias Response = EmptyResponse
    @Query var term: String?
}

// An array `@Query`: each element repeats the key (v1 default).
@GET("/items")
private struct ItemsEndpoint {
    typealias Response = EmptyResponse
    @Query var tags: [String]
}

// A custom-named `@Query`: the Swift property `pageSize` emits the key `page_size`.
@GET("/list")
private struct ListEndpoint {
    typealias Response = EmptyResponse
    @Query("page_size") var pageSize: Int
}

// A custom-named `@Path`: the property `id` resolves the `{user_id}` placeholder.
@GET("/users/{user_id}")
private struct CustomPathEndpoint {
    typealias Response = EmptyResponse
    @Path("user_id") var id: String
}

// A custom query key containing characters that must be escaped when emitted as the
// source text of a string literal (`"` and `\`) — exercises the key-escaping path.
@GET("/weird")
private struct EscapedQueryKeyEndpoint {
    typealias Response = EmptyResponse
    @Query("a\"b\\c") var value: Int
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

// MARK: - Query & body behavior

@Test("@POST with @Body and @Query exposes both in the generated members")
func postBodyAndQuery() throws {
    let article = Article(title: "Hello")
    let endpoint = CreateArticleEndpoint(article: article, draft: true)

    #expect(endpoint.method == .post)
    #expect(endpoint.queryParameters == ["draft": "true"])

    let body = try #require(endpoint.body)
    #expect(body as? Article == article)
}

@Test("Generated POST encodes body and query identically to a manual struct")
func generatedPostMatchesManualStruct() throws {
    let article = Article(title: "Indistinguishable")
    let generated = CreateArticleEndpoint(article: article, draft: true)
    let manual = ManualCreateArticle(article: article, draft: true)
    let environment = TestEnvironment()

    let generatedRequest = try URLRequest(endpoint: generated, environment: environment)
    let manualRequest = try URLRequest(endpoint: manual, environment: environment)

    #expect(generatedRequest.url == manualRequest.url)
    #expect(generatedRequest.httpMethod == manualRequest.httpMethod)
    #expect(generatedRequest.httpBody == manualRequest.httpBody)
}

@Test("Generated endpoint round-trips through MockNetworkClient like any Endpoint")
func generatedEndpointWorksWithMockClient() async throws {
    let client = MockNetworkClient()
    await client.stub(CreateArticleEndpoint.self) { _ in EmptyResponse() }

    let endpoint = CreateArticleEndpoint(article: Article(title: "Mock"), draft: false)
    let response = try await client.request(endpoint)

    #expect(response == EmptyResponse())
}

@Test("Optional @Query set to nil produces no entry in queryParameters")
func optionalQueryNilOmitted() {
    #expect(SearchEndpoint(term: nil).queryParameters.isEmpty)
    #expect(SearchEndpoint(term: "swift").queryParameters == ["term": "swift"])
}

@Test("Array @Query emits the key per element")
func arrayQueryRepeatsKey() {
    // `queryParameters` is `[String: String]`, so repeated keys collapse to the last
    // element at runtime — identical to a manual struct on the same signature. The
    // per-element repetition is verified structurally by the expansion test.
    let endpoint = ItemsEndpoint(tags: ["swift", "ios"])
    #expect(endpoint.queryParameters == ["tags": "ios"])
}

@Test("@Query with a custom name emits the custom key")
func customNameQueryEmitsCustomKey() {
    #expect(ListEndpoint(pageSize: 20).queryParameters == ["page_size": "20"])
}

@Test("A custom query key with escapable characters survives into queryParameters")
func customQueryKeyEscapingRoundTrips() {
    #expect(EscapedQueryKeyEndpoint(value: 7).queryParameters == ["a\"b\\c": "7"])
}

@Test("No @Body means body inherits the protocol default nil")
func noBodyInheritsDefaultNil() {
    let endpoint = GetUserEndpoint(id: "1")
    #expect(endpoint.body == nil)
    #expect(endpoint.queryParameters.isEmpty)
}

@Test("@Path custom name resolves the placeholder to the property value")
func customPathNameResolves() {
    #expect(CustomPathEndpoint(id: "42").path == "/users/42")
}
