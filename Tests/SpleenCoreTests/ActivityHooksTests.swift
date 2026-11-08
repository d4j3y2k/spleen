import XCTest
import Foundation
import Darwin
@testable import SpleenCore

final class ActivityHooksTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let key = ConversationKey(provider: .codex, id: "thr_activity_fixture")
    func event(_ kind: ActivityHookKind, turn: String? = "turn_1", agent: String? = nil, tool: String? = nil, offset: Double = 0) -> ActivityHookEvent {
        ActivityHookEvent(key: key, project: "/fixture", kind: kind, turnID: turn, agentID: agent, toolUseID: tool, receivedAt: now.addingTimeInterval(offset))
    }
    func record(_ event: ActivityHookEvent, into snapshot: inout ActivityHookSnapshot) {
        XCTAssertTrue(snapshot.record(event, now: event.receivedAt))
    }
    func testDecodeKeepsOnlyMetadataAndRequiresExactEventIdentity() throws {
        let data = try JSONSerialization.data(withJSONObject: ["session_id": key.id, "cwd": "/fixture", "hook_event_name": "PreToolUse",
            "turn_id": "turn_1", "tool_use_id": "call_1", "prompt": "PRIVATE", "tool_input": ["command": "PRIVATE"],
            "last_assistant_message": "PRIVATE", "transcript_path": "/PRIVATE"])
        let decoded = try XCTUnwrap(ActivityHookDecoder.codexEvent(data: data, now: now))
        XCTAssertEqual(decoded.kind, .preToolUse); XCTAssertEqual(decoded.key, key); XCTAssertEqual(decoded.receivedAt, now)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self).contains("PRIVATE"))
        XCTAssertNil(ActivityHookDecoder.codexEvent(data: Data(repeating: 32, count: 65537), now: now))
        for overrides in [["turn_id": ""], ["cwd": "relative"], ["session_id": "new"], ["hook_event_name": "agent-turn-complete"], ["tool_use_id": "../bad"]] {
            var object = ["session_id": key.id, "cwd": "/fixture", "hook_event_name": "PreToolUse", "turn_id": "turn_1", "tool_use_id": "call_1"]
            for (key, value) in overrides { object[key] = value }
            XCTAssertNil(ActivityHookDecoder.codexEvent(data: try JSONSerialization.data(withJSONObject: object), now: now))
        }
    }
    func testDisabledByDefaultAndEnableEpochReset() {
        var snapshot = ActivityHookSnapshot()
        XCTAssertFalse(snapshot.record(event(.preModelRequest), now: now))
        let firstEpoch = snapshot.epoch; snapshot.setEnabled(true)
        XCTAssertNotEqual(snapshot.epoch, firstEpoch)
        record(event(.preModelRequest), into: &snapshot)
        snapshot.setEnabled(false)
        XCTAssertTrue(snapshot.samples(at: now).isEmpty); XCTAssertTrue(snapshot.events.isEmpty)
        let disabledEpoch = snapshot.epoch; snapshot.setEnabled(true)
        XCTAssertNotEqual(snapshot.epoch, disabledEpoch); XCTAssertEqual(snapshot.sequence, 0)
    }
    func testWorkingPulseExpiresWithoutPollingRenewal() {
        var snapshot = ActivityHookSnapshot(); snapshot.setEnabled(true)
        record(event(.preModelRequest), into: &snapshot)
        let initial = snapshot.samples(at: now).first
        XCTAssertEqual(initial?.activity, .working); XCTAssertNil(initial?.isUnread)
        XCTAssertEqual(snapshot.samples(at: now.addingTimeInterval(14)).first?.expiresAt, initial?.expiresAt)
        XCTAssertTrue(snapshot.samples(at: now.addingTimeInterval(15)).isEmpty)
        XCTAssertTrue(snapshot.samples(at: now.addingTimeInterval(-1)).isEmpty)
    }
    func testActivityHistoryOutlivesSpinnerWithoutBeingRefreshedByPolling() {
        var snapshot = ActivityHookSnapshot(); snapshot.setEnabled(true)
        record(event(.preModelRequest), into: &snapshot)
        let quiet = now.addingTimeInterval(20)
        XCTAssertTrue(snapshot.samples(at: quiet).isEmpty)
        XCTAssertEqual(snapshot.recentActivity(at: quiet)[key], now)
        var attention = SessionAttention()
        XCTAssertTrue(attention.rememberActivity(snapshot.recentActivity(at: quiet), at: quiet))
        XCTAssertFalse(attention.rememberActivity(snapshot.recentActivity(at: now.addingTimeInterval(100)), at: now.addingTimeInterval(100)))
        XCTAssertEqual(attention.recentActivityAt(for: key, at: quiet), now)
        XCTAssertNil(attention.liveState(for: key, at: quiet), "History never creates a live activity sample")
        XCTAssertNil(attention.recentActivityAt(for: key, at: now.addingTimeInterval(1800)))
        XCTAssertNil(attention.recentActivityAt(for: key, at: now.addingTimeInterval(-1)))
        XCTAssertTrue(attention.clearRecentActivity())
        XCTAssertNil(attention.recentActivityAt(for: key, at: quiet))
        snapshot.setEnabled(false)
        XCTAssertTrue(snapshot.recentActivity(at: quiet).isEmpty)
    }
    func testStopPermissionAndPostModelAreNotCompletionOrIdle() {
        for kind in [ActivityHookKind.stopAttempted, .permissionRequested, .postModelRequest, .interrupted] {
            var snapshot = ActivityHookSnapshot(); snapshot.setEnabled(true)
            record(event(.preModelRequest), into: &snapshot)
            record(event(kind, offset: 1), into: &snapshot)
            let sample = snapshot.samples(at: now.addingTimeInterval(1)).first
            XCTAssertNotNil(sample); XCTAssertNil(sample?.activity); XCTAssertNil(sample?.completion); XCTAssertNil(sample?.isUnread)
        }
    }
    func testPromptAndSessionStartDoNotFabricateWorking() {
        var snapshot = ActivityHookSnapshot(); snapshot.setEnabled(true)
        record(event(.sessionStarted, turn: nil), into: &snapshot)
        record(event(.promptSubmitted, offset: 1), into: &snapshot)
        XCTAssertNil(snapshot.samples(at: now.addingTimeInterval(1)).first?.activity)
    }
    func testConcurrentToolCompletionPreservesOtherLeaseWithoutExtendingIt() {
        var snapshot = ActivityHookSnapshot(); snapshot.setEnabled(true)
        record(event(.preToolUse, tool: "call_1"), into: &snapshot)
        record(event(.preToolUse, tool: "call_2", offset: 2), into: &snapshot)
        record(event(.postToolUse, tool: "call_2", offset: 3), into: &snapshot)
        let sample = snapshot.samples(at: now.addingTimeInterval(4)).first
        XCTAssertEqual(sample?.activity, .working)
        XCTAssertEqual(sample?.expiresAt, now.addingTimeInterval(15), "Completing another tool cannot renew the older tool's lease")
        XCTAssertNil(snapshot.samples(at: now.addingTimeInterval(16)).first?.activity)
    }
    func testParentStopDoesNotClearChildPulse() {
        var snapshot = ActivityHookSnapshot(); snapshot.setEnabled(true)
        record(event(.preModelRequest), into: &snapshot)
        record(event(.subagentStarted, agent: "child_1", offset: 1), into: &snapshot)
        record(event(.stopAttempted, offset: 2), into: &snapshot)
        XCTAssertEqual(snapshot.samples(at: now.addingTimeInterval(2)).first?.activity, .working)
        record(event(.subagentStopAttempted, agent: "child_1", offset: 3), into: &snapshot)
        XCTAssertNil(snapshot.samples(at: now.addingTimeInterval(3)).first?.activity)
    }
    func testLateOldTurnStopAndNotifyCannotClearNewTurn() {
        var snapshot = ActivityHookSnapshot(); snapshot.setEnabled(true)
        record(event(.preModelRequest), into: &snapshot)
        record(event(.promptSubmitted, turn: "turn_2", offset: 1), into: &snapshot)
        record(event(.preModelRequest, turn: "turn_2", offset: 2), into: &snapshot)
        record(event(.stopAttempted, offset: 3), into: &snapshot)
        record(event(.turnCompleted, offset: 4), into: &snapshot)
        let sample = snapshot.samples(at: now.addingTimeInterval(4)).first
        XCTAssertEqual(sample?.activity, .working); XCTAssertNil(sample?.completion)
        XCTAssertEqual(sample?.expiresAt, now.addingTimeInterval(17))
    }
    func testNotifyProvidesExactTurnCompletionWithoutReadStateOrInventedTimestamp() throws {
        let data = try JSONSerialization.data(withJSONObject: ["type": "agent-turn-complete", "thread-id": key.id,
            "turn-id": "turn_1", "cwd": "/fixture", "input-messages": ["PRIVATE"], "last-assistant-message": "PRIVATE"])
        let decoded = try XCTUnwrap(ActivityHookDecoder.codexNotification(data: data, now: now))
        XCTAssertEqual(decoded.kind, .turnCompleted)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self).contains("PRIVATE"))
        var snapshot = ActivityHookSnapshot(); snapshot.setEnabled(true); record(decoded, into: &snapshot)
        let sample = snapshot.samples(at: now).first
        XCTAssertEqual(sample?.completion?.turnID, "turn_1"); XCTAssertNil(sample?.completion?.completedAt)
        XCTAssertNil(sample?.isUnread); XCTAssertNil(sample?.activity)
    }
    func testNewActivityClearsPriorCompletionAndIndependentSessionsCanArriveOutOfOrder() {
        var snapshot = ActivityHookSnapshot(); snapshot.setEnabled(true)
        record(event(.turnCompleted), into: &snapshot)
        record(event(.preModelRequest, offset: 2), into: &snapshot)
        let other = ActivityHookEvent(key: ConversationKey(provider: .codex, id: "thr_other_fixture"), project: "/fixture",
            kind: .preModelRequest, turnID: "other_turn", receivedAt: now.addingTimeInterval(1))
        XCTAssertTrue(snapshot.record(other, now: now.addingTimeInterval(2)))
        let sample = snapshot.samples(at: now.addingTimeInterval(2)).first { $0.key == key }
        XCTAssertEqual(sample?.activity, .working); XCTAssertNil(sample?.completion)
        XCTAssertNoThrow(try snapshot.validate())
    }
    func testReceiptOrderingDuplicatesBoundsAndWrongHost() {
        var snapshot = ActivityHookSnapshot(); snapshot.setEnabled(true)
        let first = event(.preModelRequest); record(first, into: &snapshot)
        XCTAssertFalse(snapshot.record(first, now: now))
        XCTAssertFalse(snapshot.record(event(.preModelRequest, offset: -1), now: now))
        XCTAssertFalse(snapshot.record(event(.preModelRequest, offset: 1), now: now))
        let remote = ActivityHookEvent(key: key, host: "remote", project: "/fixture", kind: .preModelRequest, turnID: "turn", receivedAt: now)
        XCTAssertFalse(snapshot.record(remote, now: now))
        for index in 1..<140 { record(event(.preModelRequest, offset: Double(index)), into: &snapshot) }
        XCTAssertEqual(snapshot.events.count, ActivityHookSnapshot.maximumEvents)
        snapshot.prune(now: now.addingTimeInterval(4000)); XCTAssertTrue(snapshot.events.isEmpty)
    }
    func withRepository(_ action: (ActivityHookRepository) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try action(ActivityHookRepository(url: directory.appendingPathComponent("activity-hooks.json")))
    }
    func testRepositoryRoundTripConcurrentWritersAndPrivatePermissions() throws {
        try withRepository { repository in
            XCTAssertFalse(try repository.load(now: now).enabled)
            try repository.setEnabled(true, now: now)
            let lock = NSLock(); var errors: [Error] = []
            DispatchQueue.concurrentPerform(iterations: 24) { index in
                do {
                    let event = ActivityHookEvent(key: ConversationKey(provider: .codex, id: "thr_fixture_\(index)"), project: "/fixture",
                        kind: .preModelRequest, turnID: "turn_1", receivedAt: now)
                    if try !ActivityHookRepository(url: repository.url).record(event, now: now) { throw ActivityHookRepositoryError.invalidFile }
                } catch { lock.lock(); errors.append(error); lock.unlock() }
            }
            XCTAssertTrue(errors.isEmpty)
            let snapshot = try repository.load(now: now)
            XCTAssertEqual(snapshot.events.count, 24); XCTAssertEqual(snapshot.sequence, 24)
            XCTAssertEqual(Set(snapshot.samples(at: now).map(\.key)).count, 24)
            let attributes = try FileManager.default.attributesOfItem(atPath: repository.url.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            try repository.setEnabled(false, now: now)
            XCTAssertFalse(try repository.record(event(.preModelRequest), now: now))
        }
    }
    func testCorruptOversizeSymlinkAndUnknownVersionArePreserved() throws {
        try withRepository { repository in
            try repository.setEnabled(true, now: now)
            for data in [Data("broken".utf8), Data(repeating: 32, count: ActivityHookRepository.maximumFileBytes + 1),
                         Data("{\"version\":2,\"enabled\":false,\"epoch\":\"\(UUID())\",\"sequence\":0,\"records\":[]}".utf8)] {
                try data.write(to: repository.url)
                XCTAssertThrowsError(try repository.load(now: now))
                XCTAssertThrowsError(try repository.record(event(.preModelRequest), now: now))
                XCTAssertThrowsError(try repository.setEnabled(false, now: now))
                XCTAssertEqual(try Data(contentsOf: repository.url), data)
            }
            try FileManager.default.removeItem(at: repository.url)
            let target = repository.url.deletingLastPathComponent().appendingPathComponent("target")
            try Data("preserve".utf8).write(to: target)
            try FileManager.default.createSymbolicLink(at: repository.url, withDestinationURL: target)
            XCTAssertThrowsError(try repository.record(event(.preModelRequest), now: now))
            XCTAssertEqual(try Data(contentsOf: target), Data("preserve".utf8))
        }
    }
}
