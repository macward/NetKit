import Foundation
import Testing
import NetKit

// `assertMacroExpansion` exercises the macro plugin directly, which is a host
// (macOS) tool — see Package.swift. The whole expansion suite is therefore macOS-only;
// the end-to-end behavior tests live in NetKitMacrosTests.swift and run everywhere.
#if os(macOS)
import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
@testable import NetKitMacrosImpl

private let testMacros: [String: any Macro.Type] = [
    "GET": GETMacro.self,
    "POST": POSTMacro.self,
    "Path": PathMacro.self,
    "Query": QueryMacro.self,
    "Body": BodyMacro.self
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

@Test("@POST with @Body and @Query expands queryParameters and body")
func postBodyAndQueryExpansion() {
    assertMacroExpansion(
        """
        @POST("/articles")
        struct CreateArticle {
            typealias Response = EmptyResponse
            @Body var article: Article
            @Query var draft: Bool
        }
        """,
        expandedSource: """
        struct CreateArticle {
            typealias Response = EmptyResponse
            var article: Article
            var draft: Bool

            var path: String {
                "/articles"
            }

            var method: HTTPMethod {
                .post
            }

            var queryParameters: [String: String] {
                var parameters: [String: String] = [:]
                parameters["draft"] = "\\(draft)"
                return parameters
            }

            var body: (any Encodable & Sendable)? {
                article
            }
        }

        extension CreateArticle: Endpoint {
        }
        """,
        macros: testMacros
    )
}

@Test("Optional @Query expands to a nil-guarded assignment")
func optionalQueryExpansion() {
    assertMacroExpansion(
        """
        @GET("/search")
        struct Search {
            typealias Response = EmptyResponse
            @Query var term: String?
        }
        """,
        expandedSource: """
        struct Search {
            typealias Response = EmptyResponse
            var term: String?

            var path: String {
                "/search"
            }

            var method: HTTPMethod {
                .get
            }

            var queryParameters: [String: String] {
                var parameters: [String: String] = [:]
                if let term {
                    parameters["term"] = "\\(term)"
                }
                return parameters
            }
        }

        extension Search: Endpoint {
        }
        """,
        macros: testMacros
    )
}

@Test("Array @Query expands to a per-element key repetition loop")
func arrayQueryExpansion() {
    assertMacroExpansion(
        """
        @GET("/items")
        struct Items {
            typealias Response = EmptyResponse
            @Query var tags: [String]
        }
        """,
        expandedSource: """
        struct Items {
            typealias Response = EmptyResponse
            var tags: [String]

            var path: String {
                "/items"
            }

            var method: HTTPMethod {
                .get
            }

            var queryParameters: [String: String] {
                var parameters: [String: String] = [:]
                for value in tags {
                    parameters["tags"] = "\\(value)"
                }
                return parameters
            }
        }

        extension Items: Endpoint {
        }
        """,
        macros: testMacros
    )
}

@Test("Custom-named @Query expands with the custom key")
func customNameQueryExpansion() {
    assertMacroExpansion(
        """
        @GET("/list")
        struct List {
            typealias Response = EmptyResponse
            @Query("page_size") var pageSize: Int
        }
        """,
        expandedSource: """
        struct List {
            typealias Response = EmptyResponse
            var pageSize: Int

            var path: String {
                "/list"
            }

            var method: HTTPMethod {
                .get
            }

            var queryParameters: [String: String] {
                var parameters: [String: String] = [:]
                parameters["page_size"] = "\\(pageSize)"
                return parameters
            }
        }

        extension List: Endpoint {
        }
        """,
        macros: testMacros
    )
}
#endif
