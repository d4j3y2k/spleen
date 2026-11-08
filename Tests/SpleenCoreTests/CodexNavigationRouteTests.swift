import XCTest
@testable import SpleenCore

final class CodexNavigationRouteTests: XCTestCase {
    let id = "11111111-2222-4333-8444-555555555555"
    func testVerifiedPackagedLocalRoutes() {
        for route in ["local", "hotkey-window/thread"] {
            XCTAssertEqual(CodexNavigationRoute.parse(url: URL(string: "app://-/\(route)/\(id)?hostId=local")!),
                           ConversationKey(provider: .codex, id: id))
            XCTAssertNotNil(CodexNavigationRoute.parse(url: URL(string: "app://-/\(route)/\(id)")!, defaultHostIsVerifiedLocal: true))
        }
    }
    func testAbsentHostUsesVerifiedRendererDefaultUnlessDisabled() {
        XCTAssertNotNil(CodexNavigationRoute.parse(url: URL(string: "app://-/local/\(id)")!))
        XCTAssertNil(CodexNavigationRoute.parse(url: URL(string: "app://-/local/\(id)")!, defaultHostIsVerifiedLocal: false))
    }
    func testUntrustedOriginsHostsBootstrapAndNonConversationRoutesRejected() {
        for string in ["https://example.com/local/\(id)?hostId=local", "app://other/local/\(id)?hostId=local",
                       "app://-/remote/\(id)?hostId=local", "app://-/local/\(id)?hostId=ssh:server",
                       "app://-/local/\(id)?hostId=local&hostId=local", "app://-/local/\(id)?hostId=",
                       "app://-/local/\(id)/settings?hostId=local", "app://-/local/not-a-thread?hostId=local",
                       "app://-/index.html?initialRoute=/local/\(id)&hostId=local",
                       "app://-/local/\(id)?hostId=local&initialRoute=/local/\(id)",
                       "app://-/local/\(id)?hostId=local#other", "app://-/local/\(id)%2Fother?hostId=local"] {
            XCTAssertNil(CodexNavigationRoute.parse(url: URL(string: string)!, defaultHostIsVerifiedLocal: true), string)
        }
    }
}
