import Foundation
import Testing
import NetKit
import NetKitMacros

// Task 007 — behavioral parity tests.
//
// The `assertMacroExpansion` suites (MacroExpansionTests / MacroValidationTests) prove the
// generated *syntax*. These tests prove the generated *runtime behavior*: a macro-generated
// endpoint, driven through the real `MockNetworkClient`, is observably indistinguishable from
// a hand-written struct on the same signature — same resolved path, method, query, body, and
// decoded `Response`. They run on every platform (no host-tool dependency).
//
// Fixtures are prefixed `Parity…` and scoped `private` so they stay unique within the test
// target and never shadow the end-to-end fixtures in NetKitMacrosTests.swift.

// MARK: - Parity fixtures

// A response payload with content, so "decodes the same Response" is a meaningful value
// comparison rather than a trivial `EmptyResponse()` equality.
private struct ParityUser: Codable, Equatable, Sendable {
    let id: String
    let name: String
}

// The body payload for the POST parity subject.
private struct ParityArticle: Codable, Equatable, Sendable {
    let title: String
}

// MARK: GET (path parameter + query)

// Generated GET: a `@Path` placeholder plus a `@Query`. The macro synthesizes `path`,
// `method` and `queryParameters`; the developer writes only the stored properties.
@GET("/users/{id}")
private struct ParityGeneratedGetUser {
    typealias Response = ParityUser
    @Path var id: String
    @Query var verbose: Bool
}

// Hand-written equivalent of `ParityGeneratedGetUser`. The parity tests assert the generated
// endpoint behaves identically to this struct.
private struct ParityManualGetUser: Endpoint {
    typealias Response = ParityUser
    let id: String
    let verbose: Bool

    var path: String { "/users/\(id)" }
    var method: HTTPMethod { .get }
    var queryParameters: [String: String] { ["verbose": "\(verbose)"] }
}

// MARK: POST (body + query)

// Generated POST: a `@Body` plus a `@Query`. The macro synthesizes `body` and
// `queryParameters` alongside `path`/`method`.
@POST("/articles")
private struct ParityGeneratedCreateArticle {
    typealias Response = ParityUser
    @Body var article: ParityArticle
    @Query var draft: Bool
}

// Hand-written equivalent of `ParityGeneratedCreateArticle`.
private struct ParityManualCreateArticle: Endpoint {
    typealias Response = ParityUser
    let article: ParityArticle
    let draft: Bool

    var path: String { "/articles" }
    var method: HTTPMethod { .post }
    var queryParameters: [String: String] { ["draft": "\(draft)"] }
    var body: (any Encodable & Sendable)? { article }
}

// MARK: - Test environment

private struct ParityTestEnvironment: NetworkEnvironment {
    let baseURL: URL = URL(string: "https://api.example.com")!
}

// MARK: - Parity through MockNetworkClient

@Test("Generated GET is indistinguishable from a manual struct through MockNetworkClient")
func generatedGetMatchesManualThroughMockClient() async throws {
    let client = MockNetworkClient()
    let expected = ParityUser(id: "42", name: "Ada")
    await client.stub(ParityGeneratedGetUser.self) { _ in expected }
    await client.stub(ParityManualGetUser.self) { _ in expected }

    let generatedResponse = try await client.request(ParityGeneratedGetUser(id: "42", verbose: true))
    let manualResponse = try await client.request(ParityManualGetUser(id: "42", verbose: true))

    // Decoded Response parity.
    #expect(generatedResponse == manualResponse)
    #expect(generatedResponse == expected)

    // Each endpoint was served exactly once — guards `first` below against picking the wrong
    // instance if the mock ever over-records.
    #expect(await client.callCount(for: ParityGeneratedGetUser.self) == 1)
    #expect(await client.callCount(for: ParityManualGetUser.self) == 1)

    // The mock records each endpoint instance it serves — compare what it actually saw so the
    // seam under test is MockNetworkClient, not just the local instances.
    let recordedGenerated = try #require(await client.calledEndpoints(of: ParityGeneratedGetUser.self).first)
    let recordedManual = try #require(await client.calledEndpoints(of: ParityManualGetUser.self).first)

    #expect(recordedGenerated.path == recordedManual.path)
    #expect(recordedGenerated.method == recordedManual.method)
    #expect(recordedGenerated.queryParameters == recordedManual.queryParameters)
    #expect(recordedGenerated.path == "/users/42")

    // Resolved-request parity: the generated path/query flow through the URL builder identically.
    let environment = ParityTestEnvironment()
    let generatedRequest = try URLRequest(endpoint: recordedGenerated, environment: environment)
    let manualRequest = try URLRequest(endpoint: recordedManual, environment: environment)
    #expect(generatedRequest.url == manualRequest.url)
    #expect(generatedRequest.url?.absoluteString == "https://api.example.com/users/42?verbose=true")
    #expect(generatedRequest.httpMethod == manualRequest.httpMethod)
    #expect(generatedRequest.httpMethod == "GET")
}

@Test("Generated POST is indistinguishable from a manual struct through MockNetworkClient")
func generatedPostMatchesManualThroughMockClient() async throws {
    let client = MockNetworkClient()
    let expected = ParityUser(id: "7", name: "Created")
    let article = ParityArticle(title: "Parity")
    await client.stub(ParityGeneratedCreateArticle.self) { _ in expected }
    await client.stub(ParityManualCreateArticle.self) { _ in expected }

    let generatedResponse = try await client.request(ParityGeneratedCreateArticle(article: article, draft: true))
    let manualResponse = try await client.request(ParityManualCreateArticle(article: article, draft: true))

    // Decoded Response parity.
    #expect(generatedResponse == manualResponse)

    #expect(await client.callCount(for: ParityGeneratedCreateArticle.self) == 1)
    #expect(await client.callCount(for: ParityManualCreateArticle.self) == 1)

    let recordedGenerated = try #require(await client.calledEndpoints(of: ParityGeneratedCreateArticle.self).first)
    let recordedManual = try #require(await client.calledEndpoints(of: ParityManualCreateArticle.self).first)

    #expect(recordedGenerated.method == recordedManual.method)
    #expect(recordedGenerated.queryParameters == recordedManual.queryParameters)
    #expect(recordedGenerated.queryParameters == ["draft": "true"])

    // Body is type-erased (`any Encodable & Sendable`), so compare its encoded form: build a
    // URLRequest from each recorded endpoint and assert the bytes (and URL) match.
    let environment = ParityTestEnvironment()
    let generatedRequest = try URLRequest(endpoint: recordedGenerated, environment: environment)
    let manualRequest = try URLRequest(endpoint: recordedManual, environment: environment)
    #expect(generatedRequest.httpBody == manualRequest.httpBody)
    #expect(generatedRequest.httpBody != nil)
    #expect(generatedRequest.url == manualRequest.url)
    #expect(generatedRequest.httpMethod == manualRequest.httpMethod)
}
