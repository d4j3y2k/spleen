import XCTest
@testable import SpleenCore

final class AutomaticAttentionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private func window(_ id: String = "fixture", offset: TimeInterval = 0,
                        text: String = "Completed the requested feature.", host: String = "local",
                        provider: ContextProvider = .codex, incomplete: Bool = false,
                        unanswered: Bool = false) -> SessionWindow {
        var messages = [RecentMessage(id: "user", role: .user, text: "Please implement this feature."),
                        RecentMessage(id: "assistant", role: .assistant, text: text)]
        if unanswered { messages.append(RecentMessage(id: "new", role: .user, text: "One more change.")) }
        return SessionWindow(key: ConversationKey(provider: provider, id: id), host: host,
                             sourceUpdatedAt: now.addingTimeInterval(offset), messages: messages, incomplete: incomplete)
    }
    func testChoosesNewestEligibleWithoutSixteenWindowLimit() {
        let windows = (0..<24).map { window("thread-\($0)", offset: Double($0)) }
        let cached = Set(windows.suffix(23).map(\.contentVersion))
        XCTAssertEqual(AutomaticAttention.nextWindow(windows: windows, cachedVersions: cached, attemptedVersions: [])?.key, windows[0].key)
        XCTAssertEqual(AutomaticAttention.nextWindow(windows: windows, cachedVersions: [], attemptedVersions: [])?.key, windows[23].key)
    }
    func testCachedFinishedWindowOnlyReopensOnContentChange() {
        let finished = window()
        let metadataChange = window(offset: 100)
        XCTAssertEqual(finished.contentVersion, metadataChange.contentVersion)
        XCTAssertNil(AutomaticAttention.nextWindow(windows: [metadataChange], cachedVersions: [finished.contentVersion], attemptedVersions: []))
        let changed = window(offset: 100, text: "The new requested change is now delivered.")
        XCTAssertNotNil(AutomaticAttention.nextWindow(windows: [changed], cachedVersions: [finished.contentVersion], attemptedVersions: []))
    }
    func testAttemptedVersionsPreventRepeatedFailures() {
        let current = window()
        XCTAssertNil(AutomaticAttention.nextWindow(windows: [current], cachedVersions: [], attemptedVersions: [current.contentVersion]))
    }
    func testSkipsUnsupportedHostProviderAndIncompleteOrUnansweredEvidence() {
        let candidates = [window("remote", host: "remote"), window("claude", provider: .claude),
                          window("incomplete", incomplete: true), window("unanswered", unanswered: true),
                          SessionWindow(key: ConversationKey(provider: .codex, id: "empty"), sourceUpdatedAt: now, messages: [])]
        XCTAssertNil(AutomaticAttention.nextWindow(windows: candidates, cachedVersions: [], attemptedVersions: []))
    }
    func testTieOrderDoesNotDependOnInputOrder() {
        let a = window("a"), b = window("b")
        XCTAssertEqual(AutomaticAttention.nextWindow(windows: [a,b], cachedVersions: [], attemptedVersions: []),
                       AutomaticAttention.nextWindow(windows: [b,a], cachedVersions: [], attemptedVersions: []))
    }
    func testRecognizableSecretsStayLocal() {
        let secrets = ["sk-proj-" + String(repeating: "a", count: 30), "-----BEGIN PRIVATE KEY-----",
                       "password=hunter22", "\"client_secret\": \"made-up-secret-value\"",
                       "OPENAI_API_KEY='example-key-value'", "Authorization: Bearer abcdefghijklmnop",
                       "ghp_" + String(repeating: "a", count: 30), "AKIA" + String(repeating: "A", count: 16),
                       "refresh_token: example-refresh-token", "eyJabcdefghi.abcdefghijk.abcdefghijk",
                       // .env lines with a prefixed name, which `\b` used to miss.
                       "DB_PASSWORD=hunter2hunter2", "AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMIK7MDENGbPxRfiCYEXAMPLEKEY",
                       "GOOGLE_CLIENT_SECRET=made-up-secret", "export GITHUB_TOKEN=made-up-token-value",
                       "SLACK_BOT_TOKEN=xoxb-made-up", "DATABASE_PASS: made-up-pass",
                       "sk_live_" + String(repeating: "a", count: 24), "rk_test_" + String(repeating: "b", count: 24),
                       "npm_" + String(repeating: "c", count: 36), "postgres://admin:made-up-pass@db.internal:5432/app",
                       "-----BEGIN PGP PRIVATE KEY BLOCK-----", "-----BEGIN OPENSSH PRIVATE KEY-----"]
        for secret in secrets {
            let w = window(text: "Example text: \(secret)")
            XCTAssertTrue(AutomaticAttention.containsLikelySecret(w), secret)
            XCTAssertNil(AutomaticAttention.nextWindow(windows: [w], cachedVersions: [], attemptedVersions: []))
        }
    }
    func testFullSSNShapedNumbersStayLocal() {
        for text in ["Example SSN 123-45-6789", "Identifier 123 45 6789", "Number 123456789"] {
            let w = window(text: text)
            XCTAssertTrue(AutomaticAttention.containsLikelySecret(w), text)
            XCTAssertNil(AutomaticAttention.nextWindow(windows: [w], cachedVersions: [], attemptedVersions: []))
        }
        XCTAssertFalse(AutomaticAttention.containsLikelySecret(window(text: "SSN ending in 6789")))
    }
    func testLuhnValidFullCardNumbersStayLocalButNotLastFour() {
        // Publicly documented non-production payment test numbers only.
        for card in ["4242424242424242", "4242 4242 4242 4242", "4242-4242-4242-4242",
                     "378282246310005", "4222222222222", "4000000000000000006"] {
            let w = window(text: "Test card: \(card)")
            XCTAssertTrue(AutomaticAttention.containsLikelySecret(w), card)
            XCTAssertNil(AutomaticAttention.nextWindow(windows: [w], cachedVersions: [], attemptedVersions: []))
        }
        XCTAssertFalse(AutomaticAttention.containsLikelySecret(window(text: "Card ending in 4242")))
        XCTAssertFalse(AutomaticAttention.containsLikelySecret(window(text: "Reference 4242424242424241")))
    }
    func testOrdinaryCredentialDiscussionDoesNotRequireASecret() {
        for text in ["The API key is configured securely.", "Please reset your password in settings.",
                     "Completed and verified the implementation.", "Waiting for your choice of theme.",
                     "Set max_tokens: 4096 and read input_tokens from usage.", "The compass: true, bypass: none.",
                     "Open http://localhost:8080/path and ssh://git@github.com/org/repo.",
                     "Use pk_live_ keys only in the browser."] {
            XCTAssertFalse(AutomaticAttention.containsLikelySecret(window(text: text)), text)
        }
    }
}
