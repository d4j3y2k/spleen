import XCTest
@testable import SpleenCore

final class ClaudeDesktopWorkControlsTests: XCTestCase {
    private final class Node {
        let role: String, label: String
        let enabled: Bool
        let children: [Node]
        init(_ role: String = "AXGroup", _ label: String = "", enabled: Bool = true, _ children: [Node] = []) {
            self.role = role; self.label = label; self.enabled = enabled; self.children = children
        }
    }
    private func read(_ root: Node, visited: inout [String]) -> ClaudeDesktopWorkControls {
        ClaudeDesktopWorkControls.read(in: root, metadata: { .init(role: $0.role, label: $0.label) },
            children: { visited.append($0.label); return $0.children }, enabled: { $0.enabled })
    }
    func testMainTurnStopSurvivesDeepAnonymousLayout() {
        var root = Node("AXGroup", "", [Node("AXButton", "Stop")])
        for _ in 0..<18 { root = Node("AXGroup", "", [root]) }
        var visited: [String] = []
        XCTAssertEqual(read(root, visited: &visited).responseStops, 1)
    }
    func testBackgroundWorkRemainsWorkingAfterMainReplyFinishes() {
        let root = Node("AXGroup", "", [Node("AXGroup", "Session details", [Node("AXGroup", "", [Node("AXGroup", "Background tasks", [
            Node("AXGroup", "", [Node("AXButton", "Stop this task"), Node("AXButton", "Stop this task")]),
            Node("AXButton", "10 finished")])])])])
        var visited: [String] = []
        let result = read(root, visited: &visited)
        XCTAssertEqual(result.responseStops, 0)
        XCTAssertEqual(result.backgroundTaskStops, 2)
        XCTAssertTrue(result.isWorking)
    }
    func testMessageAndOtherNamedContentAreNeverEntered() {
        let root = Node("AXGroup", "", [
            Node("AXGroup", "Chat messages", [Node("AXButton", "Stop")]),
            Node("AXGroup", "Artifact", [Node("AXButton", "Stop")]),
            Node("AXTextArea", "Prompt", [Node("AXButton", "Stop")]),
            Node("AXButton", "Stop this task"),
            Node("AXGroup", "Session details", [Node("AXButton", "Stop")]),
            Node("AXGroup", "Background tasks", [Node("AXButton", "Stop")])])
        var visited: [String] = []
        XCTAssertFalse(read(root, visited: &visited).isWorking)
        XCTAssertFalse(visited.contains("Chat messages"))
        XCTAssertFalse(visited.contains("Artifact"))
        XCTAssertFalse(visited.contains("Prompt"))
    }
    func testDisabledAndFinishedTaskControlsAreNotWorking() {
        let root = Node("AXGroup", "", [Node("AXButton", "Stop", enabled: false),
            Node("AXGroup", "Background tasks", [Node("AXButton", "Stop this task", enabled: false), Node("AXButton", "10 finished")])])
        var visited: [String] = []
        XCTAssertFalse(read(root, visited: &visited).isWorking)
    }
    func testWorkingDoesNotRequireSidebarOrInventUnreadAndExpiresWithoutFreshControls() throws {
        let observation = ClaudeDesktopObservation(url: "claude.ai/epitaxy/local_11111111-1111-4111-8111-111111111111", title: "Work - Claude Code")!
        let root = Node("AXGroup", "", [Node("AXGroup", "Background tasks", [Node("AXButton", "Stop this task")])])
        var visited: [String] = []
        let work = read(root, visited: &visited)
        let value = try XCTUnwrap(ClaudeDesktopStatus(observation: observation, matchingSidebarRows: ["Work"],
            sidebarComplete: true, currentRowConfirmed: false, workControls: work))
        XCTAssertEqual(value.activity, .working)
        XCTAssertNil(value.isUnread)
        var attention = SessionAttention()
        let start = Date()
        // A long silent task stays working only through repeated real control reads.
        for sequence in 1...100 {
            let now = start.addingTimeInterval(Double(sequence * 2))
            XCTAssertTrue(attention.accept(value.sample(at: now, sequence: UInt64(sequence), epoch: "fixture"), now: now))
            XCTAssertEqual(attention.liveState(for: observation.key, at: now)?.activity, .working)
        }
        XCTAssertNil(attention.liveState(for: observation.key, at: start.addingTimeInterval(209)))
        XCTAssertNil(ClaudeDesktopStatus(observation: observation, matchingSidebarRows: [],
            sidebarComplete: false, currentRowConfirmed: false, workControls: .init()))
    }
}
