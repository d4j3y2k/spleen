import XCTest
@testable import SpleenCore

final class ClaudeReplyTimeTests: XCTestCase {
    private let instant = Date(timeIntervalSince1970: 1_800_000_000)
    private let key = ConversationKey(provider: .claude, id: "desktop-code:local_11111111-1111-4111-8111-111111111111")
    private final class Node {
        let role: String, label: String, value: String?
        let children: [Node]
        init(_ role: String = "AXGroup", _ label: String = "", value: String? = nil, _ children: [Node] = []) {
            self.role = role; self.label = label; self.value = value; self.children = children
        }
    }
    private func footer(_ age: String = "12 minutes ago", assistant: Bool = true) -> Node {
        Node("AXToolbar", "Message actions", [Node("AXButton", assistant ? "Read aloud" : "Read by Claude"), Node("AXStaticText", value: age)])
    }
    private func read(_ rows: [Node], visits: inout [String]) -> ClaudeReplyTime? {
        let root = Node("AXGroup", "Chat messages", [Node("AXStaticText"), Node("AXGroup", "", rows)])
        return ClaudeDesktopReplyMetadata.read(in: root, at: instant,
            metadata: { .init(role: $0.role, label: $0.label) },
            children: { visits.append($0.label); return $0.children }, text: { $0.value })
    }
    func testOnlyLatestAssistantFooterIsRead() {
        let old = Node("AXGroup", "Message 1", [footer("53 minutes ago", assistant: false)])
        let latest = Node("AXGroup", "Message 6", [Node("AXStaticText", value: "private reply body")])
        var visits: [String] = []
        let reply = read([old, latest, Node("AXStaticText", value: "private final text"), footer()], visits: &visits)
        XCTAssertEqual(reply?.date, instant.addingTimeInterval(-720))
        XCTAssertEqual(visits, ["Chat messages", "", "Message actions"])
    }
    func testOldSelectedToolbarAndUserFooterDoNotBecomeLatestReply() {
        var visits: [String] = []
        XCTAssertNil(read([Node("AXGroup", "Message 2", [footer()])], visits: &visits))
        XCTAssertNil(read([Node("AXGroup", "Message 3"), footer(assistant: false)], visits: &visits))
        XCTAssertNil(read([Node("AXGroup", "Message 2"), footer(), Node("AXGroup", "Message 3")], visits: &visits))
        XCTAssertNil(read([footer()], visits: &visits))
    }
    func testNativeAnonymousWrappersAndInstructionRegion() {
        let hiddenOld = Node("AXGroup", "Message 1", [footer("53 minutes ago", assistant: false)])
        let wrappedFooter = Node("AXGroup", "", [Node(), Node("AXGroup", "", [footer()]), Node()])
        var list = Node("AXGroup", "", [Node("AXGroup", "", [hiddenOld]), Node("AXStaticText", value: "body"), wrappedFooter])
        for _ in 0..<8 { list = Node("AXGroup", "", [list]) }
        let root = Node("AXGroup", "Chat messages", [Node("AXGroup", "", [Node("AXStaticText", value: "navigation hint")]), list])
        var readText: [String] = []
        let result = ClaudeDesktopReplyMetadata.read(in: root, at: instant, metadata: { .init(role: $0.role, label: $0.label) },
            children: { $0.children }, text: { readText.append($0.value ?? ""); return $0.value })
        XCTAssertEqual(result?.date, instant.addingTimeInterval(-720))
        XCTAssertEqual(readText, ["12 minutes ago"])
    }
    func testAmbiguousOrOverBudgetFooterIsRejected() {
        var visits: [String] = []
        XCTAssertNil(read([Node("AXGroup", "Message 1"), Node("AXGroup", "", [footer(), footer()])], visits: &visits))
        var deep = footer()
        for _ in 0..<20 { deep = Node("AXGroup", "", [deep]) }
        XCTAssertNil(read([Node("AXGroup", "Message 1"), deep], visits: &visits))
        XCTAssertNil(read([Node("AXGroup", "Message 1"), Node("AXGroup", "", Array(repeating: Node(), count: 65) + [footer()])], visits: &visits))
    }
    func testUnknownAndAmbiguousTimestampFailClosed() {
        var visits: [String] = []
        XCTAssertNil(read([Node("AXGroup", "Message 2"), footer("12m")], visits: &visits))
        let ambiguous = Node("AXToolbar", "Message actions", [Node("AXButton", "Read aloud"),
            Node("AXStaticText", value: "12 minutes ago"), Node("AXStaticText", value: "1 hour ago")])
        XCTAssertNil(read([Node("AXGroup", "Message 2"), ambiguous], visits: &visits))
        for text in ["-1 minutes ago", "0 minutes ago", "1e3 minutes ago", "tomorrow", "31 days ago", "12 minutes ago trailing"] {
            XCTAssertNil(ClaudeReplyTime(label: text, observedAt: instant), text)
        }
    }
    func testApproximateLabelAndFallback() throws {
        let reply = try XCTUnwrap(ClaudeReplyTime(label: "12 minutes ago", observedAt: instant))
        let preview = ConversationPreview(lastSelectedAt: instant, observedReplyAt: reply.date)
        XCTAssertEqual(preview.timestamp(at: instant)?.label(at: instant), "Last reply ≈12m ago")
        XCTAssertTrue(preview.timestamp(at: instant)?.help.contains("Approximate") == true)
        XCTAssertEqual(ConversationPreview(lastSelectedAt: instant).timestamp(at: instant)?.label(at: instant), "Last selected just now")
        XCTAssertEqual(ConversationPreview(timing: TurnTiming(lastCompletedAt: reply.date, checkedAt: instant)).timestamp(at: instant)?.label(at: instant), "Last reply 12m ago")
    }
    func testRepeatedPollingDoesNotSlideTimestampAndNewReplyAdvances() throws {
        var history = ClaudeReplyTimes()
        let first = try XCTUnwrap(ClaudeReplyTime(label: "12 minutes ago", observedAt: instant))
        XCTAssertTrue(history.record(first, for: key, now: instant))
        for offset in stride(from: 2, through: 58, by: 2) {
            let time = instant.addingTimeInterval(Double(offset))
            XCTAssertFalse(history.record(ClaudeReplyTime(label: "12 minutes ago", observedAt: time)!, for: key, now: time))
        }
        XCTAssertEqual(history.time(for: key, at: instant.addingTimeInterval(58)), first)
        let staleLabelAt = instant.addingTimeInterval(300)
        XCTAssertFalse(history.record(ClaudeReplyTime(label: "12 minutes ago", observedAt: staleLabelAt)!, for: key, now: staleLabelAt), "A suspended relative label must not refresh the reply time")
        let later = instant.addingTimeInterval(60)
        XCTAssertFalse(history.record(ClaudeReplyTime(label: "13 minutes ago", observedAt: later)!, for: key, now: later))
        XCTAssertFalse(history.record(ClaudeReplyTime(label: "53 minutes ago", observedAt: later)!, for: key, now: later))
        XCTAssertTrue(history.record(ClaudeReplyTime(label: "just now", observedAt: later)!, for: key, now: later))
        XCTAssertEqual(history.time(for: key, at: later)?.date, later)
        XCTAssertNil(history.time(for: key, at: later.addingTimeInterval(30 * 86400)))
    }
    func testHistoryPersistsAndRejectsWrongIdentityOrStaleSample() throws {
        var history = ClaudeReplyTimes()
        let reply = ClaudeReplyTime(label: "1 hour ago", observedAt: instant)!
        XCTAssertFalse(history.record(reply, for: .init(provider: .codex, id: key.id), now: instant))
        XCTAssertFalse(history.record(reply, for: key, now: instant.addingTimeInterval(8)))
        XCTAssertFalse(history.record(reply, for: key, now: instant.addingTimeInterval(-1)))
        XCTAssertTrue(history.record(reply, for: key, now: instant))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("reply-times-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try history.save(to: file)
        XCTAssertEqual(try ClaudeReplyTimes.load(from: file), history)
    }
    func testReplyMetadataDoesNotDeclareCompletionAndAllowsBackgroundWork() throws {
        let observation = try XCTUnwrap(ClaudeDesktopObservation(url: "claude.ai/epitaxy/local_11111111-1111-4111-8111-111111111111", title: "Fixture - Claude Code"))
        let reply = ClaudeReplyTime(label: "12 minutes ago", observedAt: instant)!
        var work = ClaudeDesktopWorkControls(); work.backgroundTaskStops = 1
        let status = try XCTUnwrap(ClaudeDesktopStatus(observation: observation, matchingSidebarRows: [], sidebarComplete: false,
            currentRowConfirmed: false, workControls: work, lastReply: reply))
        XCTAssertEqual(status.lastReply, reply)
        XCTAssertEqual(status.activity, .working)
        XCTAssertNil(status.sample(at: instant, sequence: 1, epoch: "fixture").completion)
        work.responseStops = 1
        XCTAssertNil(ClaudeDesktopStatus(observation: observation, matchingSidebarRows: [], sidebarComplete: false,
            currentRowConfirmed: false, workControls: work, lastReply: reply)?.lastReply)
    }
}
