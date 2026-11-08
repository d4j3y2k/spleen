import XCTest
@testable import SpleenCore

final class CodexDesktopObservationTests: XCTestCase {
    let id = "11111111-2222-4333-8444-555555555555"
    func observation(_ title: String = "Task - ChatGPT") -> CodexDesktopObservation {
        CodexDesktopObservation(url: "app://-/local/\(id)", title: title)!
    }
    func testExactIdentityAndBoundedTitle() {
        XCTAssertEqual(observation().id, id)
        XCTAssertEqual(observation().title, "Task")
        XCTAssertEqual(observation().key.provider, .codex)
        XCTAssertEqual(observation("Task\nName - Codex").title, "Task Name")
        XCTAssertLessThanOrEqual(observation(String(repeating: "a", count: 3000)).title.count, 180)
        XCTAssertLessThanOrEqual(observation(String(repeating: "e\u{301}", count: 3000)).title.utf8.count, 720)
        XCTAssertNil(CodexDesktopObservation(url: "https://example.com/local/\(id)", title: "Task"))
        XCTAssertNil(CodexDesktopObservation(url: "app://-/local/\(id)?hostId=remote", title: "Task"))
    }
    func testBurstCoalescingTitleChangeAndReturnVisit() {
        let gate = CodexDesktopObservationGate()
        let ticket = gate.requestRead()!
        XCTAssertNil(gate.requestRead())
        XCTAssertTrue(gate.beginRead(ticket))
        XCTAssertTrue(gate.acceptDelivery(observation(), for: ticket))
        let again = gate.requestRead()!; XCTAssertTrue(gate.beginRead(again))
        XCTAssertFalse(gate.acceptDelivery(observation("Renamed"), for: again))
        gate.invalidate()
        let returned = gate.requestRead()!; XCTAssertTrue(gate.beginRead(returned))
        XCTAssertTrue(gate.acceptDelivery(observation(), for: returned))
    }
    func testStaleActivationAndOvertakenReadCannotDeliver() {
        let gate = CodexDesktopObservationGate()
        let old = gate.requestRead()!; XCTAssertTrue(gate.beginRead(old))
        let newer = gate.requestRead()!; XCTAssertTrue(gate.beginRead(newer))
        XCTAssertFalse(gate.acceptDelivery(observation(), for: old))
        XCTAssertTrue(gate.acceptDelivery(observation(), for: newer))
        gate.invalidate()
        XCTAssertFalse(gate.isCurrent(newer))
        XCTAssertFalse(gate.beginRead(newer))
        XCTAssertFalse(gate.acceptDelivery(observation(), for: newer))
    }
}
