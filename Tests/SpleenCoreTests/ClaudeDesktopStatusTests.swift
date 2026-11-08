import XCTest
@testable import SpleenCore

final class ClaudeDesktopStatusTests: XCTestCase {
    private let route = "claude.ai/epitaxy/local_11111111-1111-4111-8111-111111111111"
    private func status(_ rows: [String], complete: Bool = true, title: String = "Work") -> ClaudeDesktopStatus? {
        ClaudeDesktopStatus(observation: ClaudeDesktopObservation(url: route, title: title + " - Claude Code")!,
                            matchingSidebarRows: rows, sidebarComplete: complete, currentRowConfirmed: true)
    }
    func testNativeWorkingAndUnreadAreIndependent() {
        let working = status(["Work Running"])
        XCTAssertEqual(working?.activity, .working)
        XCTAssertEqual(working?.isUnread, false)
        let both = status(["Work Running Unread response"])
        XCTAssertEqual(both?.activity, .working)
        XCTAssertEqual(both?.isUnread, true)
        let finished = status(["Work Unread response"])
        XCTAssertNil(finished?.activity)
        XCTAssertEqual(finished?.isUnread, true)
        XCTAssertEqual(status(["Work"])?.isUnread, false)
    }
    func testMissingRowNeverInventsReadStateOrCompletion() {
        let value = status([])
        XCTAssertNil(value?.activity)
        XCTAssertNil(value?.isUnread)
        XCTAssertNil(value?.sample(at: Date(), sequence: 1, epoch: "fixture").completion)
        XCTAssertNil(status([]))
    }
    func testAmbiguousMissingOrUnknownSidebarCannotClearUnread() {
        for rows in [["Work", "Work Unread response"], ["Work Succeeded"], ["Different Unread response"], []] {
            XCTAssertNil(status(rows)?.isUnread)
        }
        XCTAssertNil(status(["Work"], complete: false)?.isUnread)
        XCTAssertNil(status([""], title: "")?.isUnread)
    }
    func testStatusWordsInTitleAreNotIndicators() {
        let value = status(["Work Running"], title: "Work Running")
        XCTAssertNil(value?.activity)
        XCTAssertEqual(value?.isUnread, false)
        XCTAssertNil(status(["Work", "Work"]))
    }
    func testMatchingTitleWithoutCurrentPageMarkerIsNotIdentityProof() {
        let observation = ClaudeDesktopObservation(url: route, title: "Work - Claude Code")!
        XCTAssertNil(ClaudeDesktopStatus(observation: observation, matchingSidebarRows: ["Work Unread response"],
                                        sidebarComplete: true, currentRowConfirmed: false))
    }
    func testOnlyExactDesktopCodeIdentityAndShortLivedSamples() throws {
        let instant = Date()
        let value = try XCTUnwrap(status(["Work Running"]))
        let sample = value.sample(at: instant, sequence: 2, epoch: "fixture")
        XCTAssertEqual(sample.key.id, "desktop-code:local_11111111-1111-4111-8111-111111111111")
        XCTAssertEqual(sample.key.provider, .claude)
        XCTAssertEqual(sample.source, ClaudeDesktopStatus.source)
        XCTAssertEqual(sample.expiresAt, instant.addingTimeInterval(8))
        let chat = ClaudeDesktopObservation(url: "claude.ai/chat/11111111-1111-4111-8111-111111111111", title: "Work")!
        XCTAssertNil(ClaudeDesktopStatus(observation: chat, matchingSidebarRows: ["Work Running"], sidebarComplete: true, currentRowConfirmed: true))
        var attention = SessionAttention()
        XCTAssertTrue(attention.accept(sample, now: instant))
        XCTAssertEqual(attention.liveState(for: sample.key, at: instant)?.activity, .working)
        XCTAssertNil(attention.liveState(for: sample.key, at: instant.addingTimeInterval(9)))
    }
}
