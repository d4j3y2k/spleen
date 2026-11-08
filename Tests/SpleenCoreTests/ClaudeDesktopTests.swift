import XCTest
@testable import SpleenCore

final class ClaudeDesktopTests: XCTestCase {
    private let id = "01234567-89ab-cdef-0123-456789abcdef"

    func testAcceptsDesktopAndWebChatLinksWithOneCanonicalIdentity() throws {
        let desktop = try ClaudeChatTarget("claude://claude.ai/chat/\(id)")
        let web = try ClaudeChatTarget("https://claude.ai/chat/\(id.uppercased())")
        XCTAssertEqual(desktop.id, id)
        XCTAssertEqual(desktop, web)
        XCTAssertEqual(Set([desktop, web]).count, 1)
        XCTAssertEqual(web.url.absoluteString, "claude://claude.ai/chat/\(id)")
        XCTAssertEqual(try ClaudeChatTarget(web.url.absoluteString), web)
    }

    func testAllowsSurroundingPasteWhitespace() throws {
        XCTAssertEqual(try ClaudeChatTarget(" \nhttps://claude.ai/chat/\(id)\t").id, id)
    }

    func testRejectsOtherRoutesAndAmbiguousAuthorities() {
        let inputs = [
            "", id, "claude.ai/chat/\(id)", "claude://claude.ai/new",
            "claude://claude.ai/project/\(id)", "claude://code/new",
            "claude://code/\(id)", "claude://cowork/new", "claude://cowork/\(id)",
            "https://claude.ai/share/\(id)", "http://claude.ai/chat/\(id)",
            "codex://threads/\(id)", "https://example.com/chat/\(id)",
            "https://claude.ai.example.com/chat/\(id)", "https://www.claude.ai/chat/\(id)",
            "https://claude.ai./chat/\(id)", "https://user@claude.ai/chat/\(id)",
            "https://user:pass@claude.ai/chat/\(id)", "https://claude.ai:443/chat/\(id)",
            "claude://claude.ai:1/chat/\(id)", "CLAUDE://claude.ai/chat/\(id)",
            "https://CLAUDE.AI/chat/\(id)", "https://claude.ai/Chat/\(id)"
        ]
        assertInvalid(inputs)
    }

    func testRejectsParametersEncodingAndPathNormalization() {
        for scheme in ["claude", "https"] {
            let base = "\(scheme)://claude.ai/chat/"
            assertInvalid([
                base + id + "?q=hello", base + id + "?", base + id + "#section", base + id + "#",
                base + id + "/", base + id + "/more", base + "../chat/" + id,
                base + "./" + id, base + "/" + id, base + "%30" + id.dropFirst(),
                base + id + "%2F", base + id + ";params", base + id + "\u{0000}",
                base + id.prefix(8) + "\n" + id.dropFirst(8),
                "\(scheme)://claude.ai/%63hat/\(id)", "\(scheme)://claude.ai\\chat\\\(id)"
            ])
        }
    }

    func testRequiresCanonicalUUIDShapeButDoesNotClaimExistence() throws {
        let base = "claude://claude.ai/chat/"
        assertInvalid([
            base, base + "new", base + "thr_example123", base + "{" + id + "}",
            base + id.replacingOccurrences(of: "-", with: ""), base + id.dropLast(),
            base + id + "0", base + "g" + id.dropFirst(),
            base + id.replacingOccurrences(of: "-", with: "_"),
            base + id.replacingOccurrences(of: "0", with: "０")
        ])
        // UUID validation cannot tell whether a chat is present in the user's account.
        XCTAssertEqual(try ClaudeChatTarget(base + "00000000-0000-0000-0000-000000000000").id,
                       "00000000-0000-0000-0000-000000000000")
    }

    private func assertInvalid(_ inputs: [String], file: StaticString = #filePath, line: UInt = #line) {
        for input in inputs {
            XCTAssertThrowsError(try ClaudeChatTarget(input), input, file: file, line: line) { error in
                XCTAssertEqual(error as? ClaudeChatTargetError, .invalidChatLink, file: file, line: line)
            }
        }
    }
}
