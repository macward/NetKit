import Foundation
import Testing
import NetKit

// Verb-matrix, default-member override, and diagnostic expansion tests. These exercise
// the macro plugin directly (a macOS host tool — see Package.swift), so the whole suite is
// macOS-only, like the happy-path expansion tests in MacroExpansionTests.swift.
#if os(macOS)
import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
@testable import NetKitMacrosImpl

private let testMacros: [String: any Macro.Type] = [
    "GET": GETMacro.self,
    "POST": POSTMacro.self,
    "PUT": PUTMacro.self,
    "PATCH": PATCHMacro.self,
    "DELETE": DELETEMacro.self,
    "Path": PathMacro.self,
    "Query": QueryMacro.self,
    "Body": BodyMacro.self
]

// MARK: - Verb matrix

@Test("@PUT generates the .put method and shares path/body generation")
func putMacroExpansion() {
    assertMacroExpansion(
        """
        @PUT("/articles/{id}")
        struct UpdateArticle {
            typealias Response = EmptyResponse
            @Path var id: String
            @Body var article: Article
        }
        """,
        expandedSource: """
        struct UpdateArticle {
            typealias Response = EmptyResponse
            var id: String
            var article: Article

            var path: String {
                "/articles/\\(id)"
            }

            var method: HTTPMethod {
                .put
            }

            var body: (any Encodable & Sendable)? {
                article
            }
        }

        extension UpdateArticle: Endpoint {
        }
        """,
        macros: testMacros
    )
}

@Test("@PATCH generates the .patch method")
func patchMacroExpansion() {
    assertMacroExpansion(
        """
        @PATCH("/articles/{id}")
        struct PatchArticle {
            typealias Response = EmptyResponse
            @Path var id: String
        }
        """,
        expandedSource: """
        struct PatchArticle {
            typealias Response = EmptyResponse
            var id: String

            var path: String {
                "/articles/\\(id)"
            }

            var method: HTTPMethod {
                .patch
            }
        }

        extension PatchArticle: Endpoint {
        }
        """,
        macros: testMacros
    )
}

@Test("@DELETE generates the .delete method")
func deleteMacroExpansion() {
    assertMacroExpansion(
        """
        @DELETE("/articles/{id}")
        struct DeleteArticle {
            typealias Response = EmptyResponse
            @Path var id: String
        }
        """,
        expandedSource: """
        struct DeleteArticle {
            typealias Response = EmptyResponse
            var id: String

            var path: String {
                "/articles/\\(id)"
            }

            var method: HTTPMethod {
                .delete
            }
        }

        extension DeleteArticle: Endpoint {
        }
        """,
        macros: testMacros
    )
}

// MARK: - Default-member override

@Test("Manual cachePolicy/headers under a verb macro are respected, not redeclared")
func defaultMemberOverrideExpansion() {
    assertMacroExpansion(
        """
        @GET("/reports")
        struct Reports {
            typealias Response = EmptyResponse
            var headers: [String: String] {
                ["X-Trace": "1"]
            }
            var cachePolicy: EndpointCachePolicy {
                .noCache
            }
        }
        """,
        expandedSource: """
        struct Reports {
            typealias Response = EmptyResponse
            var headers: [String: String] {
                ["X-Trace": "1"]
            }
            var cachePolicy: EndpointCachePolicy {
                .noCache
            }

            var path: String {
                "/reports"
            }

            var method: HTTPMethod {
                .get
            }
        }

        extension Reports: Endpoint {
        }
        """,
        macros: testMacros
    )
}

@Test("A manually declared generated member (method) is skipped, not redeclared")
func generatedMemberOverrideExpansion() {
    assertMacroExpansion(
        """
        @GET("/ping")
        struct Ping {
            typealias Response = EmptyResponse
            var method: HTTPMethod {
                .post
            }
        }
        """,
        expandedSource: """
        struct Ping {
            typealias Response = EmptyResponse
            var method: HTTPMethod {
                .post
            }

            var path: String {
                "/ping"
            }
        }

        extension Ping: Endpoint {
        }
        """,
        macros: testMacros
    )
}

// MARK: - Diagnostics

@Test("A route placeholder with no @Path property fails, anchored to the route annotation")
func uncoveredPlaceholderDiagnostic() {
    assertMacroExpansion(
        """
        @GET("/users/{id}/posts/{postId}")
        struct GetUserPosts {
            typealias Response = EmptyResponse
            @Path var id: String
        }
        """,
        expandedSource: """
        struct GetUserPosts {
            typealias Response = EmptyResponse
            var id: String

            var path: String {
                "/users/\\(id)/posts/\\(postId)"
            }

            var method: HTTPMethod {
                .get
            }
        }

        extension GetUserPosts: Endpoint {
        }
        """,
        diagnostics: [
            DiagnosticSpec(
                message: "Route placeholder '{postId}' has no matching '@Path' property",
                line: 1,
                column: 1
            )
        ],
        macros: testMacros
    )
}

@Test("An orphan @Path property fails with a FixIt, anchored to the property")
func orphanPathDiagnostic() {
    assertMacroExpansion(
        """
        @GET("/users/{id}")
        struct GetUser {
            typealias Response = EmptyResponse
            @Path var id: String
            @Path var slug: String
        }
        """,
        expandedSource: """
        struct GetUser {
            typealias Response = EmptyResponse
            var id: String
            var slug: String

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
        diagnostics: [
            DiagnosticSpec(
                message: "'@Path' property 'slug' has no matching '{slug}' placeholder in the route template",
                line: 5,
                column: 5,
                fixIts: [FixItSpec(message: "Remove '@Path' from 'slug'")]
            )
        ],
        macros: testMacros
    )
}

@Test("@Body on a GET fails with a FixIt, anchored to the verb annotation")
func bodyOnBodilessVerbDiagnostic() {
    assertMacroExpansion(
        """
        @GET("/users")
        struct ListUsers {
            typealias Response = EmptyResponse
            @Body var filter: Filter
        }
        """,
        expandedSource: """
        struct ListUsers {
            typealias Response = EmptyResponse
            var filter: Filter

            var path: String {
                "/users"
            }

            var method: HTTPMethod {
                .get
            }
        }

        extension ListUsers: Endpoint {
        }
        """,
        diagnostics: [
            DiagnosticSpec(
                message: "GET requests take no body; remove '@Body' or use POST, PUT, or PATCH",
                line: 1,
                column: 1,
                fixIts: [FixItSpec(message: "Remove '@Body' from 'filter'")]
            )
        ],
        macros: testMacros
    )
}

@Test("Two verb macros on one type produce a single diagnostic and no generation")
func multipleVerbsDiagnostic() {
    assertMacroExpansion(
        """
        @GET("/a")
        @POST("/b")
        struct Thing {
            typealias Response = EmptyResponse
        }
        """,
        expandedSource: """
        struct Thing {
            typealias Response = EmptyResponse
        }
        """,
        diagnostics: [
            DiagnosticSpec(
                message: "A type may declare only one HTTP verb macro; remove the extra verb annotation",
                line: 1,
                column: 1
            )
        ],
        macros: testMacros
    )
}
#endif
