import Foundation
import Testing
@testable import SiliconRuntime

/// The bug these exist for: the daemon was started with no bearer token, and it strict-gates
/// every workspace mutation behind auth being *configured* — so the Web Shell's "add a
/// workspace" answered `{"error":"...requires the daemon to be configured with a bearer
/// token...","code":"token_required"}` no matter what the user did.
@Suite("Qwen Code bearer token")
struct QwenCodeTokenTests {

    @Test func everyLaunchMintsItsOwnToken() {
        let first = QwenCodeRuntime.freshToken()
        let second = QwenCodeRuntime.freshToken()
        #expect(first != second)
        #expect(first.count >= 32)
        // Hex only: it travels in a URL fragment, so anything needing escaping is a bug.
        let isHexOnly = first.allSatisfy { $0.isHexDigit }
        #expect(isHexOnly)
    }

    /// The Web Shell reads `token` from the fragment or the query and then sends it as
    /// `Authorization: Bearer` on every call.
    @Test func theWebShellURLCarriesTheTokenInTheFragment() throws {
        let url = QwenCodeRuntime.webShellURL(port: 64973, token: "abc123")
        let parts = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))

        #expect(parts.scheme == "http")
        #expect(parts.host == "127.0.0.1")
        #expect(parts.port == 64973)
        #expect(parts.fragment == "token=abc123")
    }

    /// A fragment is never sent to the server. The query would be, and the daemon logs every
    /// route it serves — which would write the token to disk on every request.
    @Test func theTokenStaysOutOfTheQuery() throws {
        let url = QwenCodeRuntime.webShellURL(port: 4170, token: "secret-value")
        let parts = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))

        #expect(parts.query == nil)
        #expect(url.absoluteString.contains("#token=secret-value"))
        #expect(url.absoluteString.contains("?") == false)
    }
}
