import XCTest
@testable import SpleenCore

final class LiveAttentionTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 2_000_000_000)
    private let key = ConversationKey(provider: .codex, id: "thr_live_fixture")
    private func sample(_ source: String, time: Double, sequence: UInt64 = 1, epoch: String = "default",
                        activity: RuntimeActivity? = nil, unread: Bool? = nil, completion: LiveTurnCompletion? = nil,
                        lifetime: TimeInterval = 15) -> LiveSessionState {
        LiveSessionState(key: key, source: source, epoch: epoch, observedAt: start.addingTimeInterval(time),
            lifetime: lifetime, sequence: sequence, activity: activity, isUnread: unread, completion: completion)
    }
    @discardableResult private func accept(_ sample: LiveSessionState, into value: inout SessionAttention) -> Bool {
        value.accept(sample, now: sample.observedAt)
    }
    func testWorkingCompletedUnreadReadRemainSeparate() {
        var value = SessionAttention()
        XCTAssertTrue(accept(sample("runtime", time: 0, activity: .working), into: &value))
        XCTAssertEqual(value.liveState(for: key, at: start)?.activity, .working)
        XCTAssertNil(value.liveState(for: key, at: start)?.isUnread)
        let completion = LiveTurnCompletion(turnID: "turn-1")
        XCTAssertTrue(accept(sample("runtime", time: 1, sequence: 2, activity: .idle, completion: completion), into: &value))
        XCTAssertTrue(accept(sample("desktop-read", time: 1, unread: true), into: &value))
        let unread = value.liveState(for: key, at: start.addingTimeInterval(1))
        XCTAssertEqual(unread?.activity, .idle)
        XCTAssertEqual(unread?.isUnread, true)
        XCTAssertEqual(unread?.completion?.turnID, "turn-1")
        XCTAssertNil(unread?.completion?.completedAt, "Receipt time must not become a completion timestamp")
        XCTAssertTrue(accept(sample("desktop-read", time: 2, sequence: 2, unread: false), into: &value))
        XCTAssertEqual(value.liveState(for: key, at: start.addingTimeInterval(2))?.isUnread, false)
        XCTAssertEqual(value.liveState(for: key, at: start.addingTimeInterval(2))?.completion?.turnID, "turn-1")
    }
    func testRuntimeHeartbeatDoesNotEraseOrExtendUnreadEvidence() {
        var value = SessionAttention()
        accept(sample("desktop-read", time: 0, unread: true, lifetime: 10), into: &value)
        accept(sample("runtime", time: 8, activity: .working, lifetime: 15), into: &value)
        XCTAssertEqual(value.liveState(for: key, at: start.addingTimeInterval(9))?.isUnread, true)
        XCTAssertEqual(value.liveState(for: key, at: start.addingTimeInterval(9))?.unreadObservedAt, start)
        let after = value.liveState(for: key, at: start.addingTimeInterval(10))
        XCTAssertNil(after?.isUnread)
        XCTAssertEqual(after?.activity, .working)
        XCTAssertEqual(Set(value.liveExpirationDates), Set([start.addingTimeInterval(10), start.addingTimeInterval(23)]))
    }
    func testUnreadRefreshDoesNotKeepExpiredSpinner() {
        var value = SessionAttention()
        accept(sample("runtime", time: 0, activity: .working, lifetime: 5), into: &value)
        accept(sample("desktop-read", time: 4, unread: true), into: &value)
        let after = value.liveState(for: key, at: start.addingTimeInterval(5))
        XCTAssertNil(after?.activity)
        XCTAssertEqual(after?.isUnread, true)
        XCTAssertTrue(value.expireLive(at: start.addingTimeInterval(5)))
        XCTAssertNil(value.live[key]?.activity)
        XCTAssertEqual(value.live[key]?.isUnread, true)
    }
    func testUnknownSnapshotClearsOnlyItsOwnSource() {
        var value = SessionAttention()
        accept(sample("runtime", time: 0, activity: .working), into: &value)
        accept(sample("desktop-read", time: 0, unread: true), into: &value)
        accept(sample("runtime", time: 1, sequence: 2), into: &value)
        XCTAssertNil(value.liveState(for: key, at: start.addingTimeInterval(1))?.activity)
        XCTAssertEqual(value.liveState(for: key, at: start.addingTimeInterval(1))?.isUnread, true)
        XCTAssertFalse(accept(sample("runtime", time: 0, activity: .working), into: &value))
    }
    func testRestartEpochAcceptsResetSequenceAndRejectsRetiredProducer() {
        var value = SessionAttention()
        accept(sample("runtime", time: 0, sequence: 100, epoch: "old", activity: .working), into: &value)
        XCTAssertTrue(accept(sample("runtime", time: 1, sequence: 1, epoch: "new", activity: .idle), into: &value))
        XCTAssertFalse(accept(sample("runtime", time: 2, sequence: 101, epoch: "old", activity: .working), into: &value))
        XCTAssertEqual(value.liveState(for: key, at: start.addingTimeInterval(2))?.activity, .idle)
        XCTAssertFalse(value.disconnect(source: "runtime", epoch: "old", at: start.addingTimeInterval(2)))
        XCTAssertEqual(value.liveState(for: key, at: start.addingTimeInterval(2))?.activity, .idle)
    }
    func testDisconnectKeepsOtherSourcesAndExpiryNeverRehydrates() {
        var value = SessionAttention()
        accept(sample("runtime", time: 0, activity: .working), into: &value)
        accept(sample("desktop-read", time: 0, unread: true), into: &value)
        XCTAssertTrue(value.disconnect(source: "runtime", at: start.addingTimeInterval(1)))
        XCTAssertNil(value.liveState(for: key, at: start.addingTimeInterval(1))?.activity)
        XCTAssertEqual(value.liveState(for: key, at: start.addingTimeInterval(1))?.isUnread, true)
        XCTAssertFalse(accept(sample("runtime", time: 0.5, sequence: 2, activity: .working), into: &value),
                       "An in-flight observation from before disconnect cannot reconnect the feed")
        XCTAssertTrue(value.expireLive(at: start.addingTimeInterval(20)))
        XCTAssertNil(value.liveState(for: key, at: start.addingTimeInterval(20)))
        XCTAssertTrue(value.live.isEmpty)
        value.expireLive(at: start.addingTimeInterval(2))
        XCTAssertNil(value.liveState(for: key, at: start.addingTimeInterval(2)))
    }
    func testCompletionNotificationDoesNotStopIndependentRuntime() {
        var value = SessionAttention()
        accept(sample("runtime", time: 0, activity: .working), into: &value)
        accept(sample("notifications", time: 1, completion: LiveTurnCompletion(turnID: "earlier-turn")), into: &value)
        let current = value.liveState(for: key, at: start.addingTimeInterval(1))
        XCTAssertEqual(current?.activity, .working)
        XCTAssertEqual(current?.completion?.turnID, "earlier-turn")
        XCTAssertNil(current?.isUnread)
    }
    func testNewRuntimeCannotAuthorizeSuppressionUsingOlderReadObservation() {
        let item = Destination(title: "Test", threadID: key.id)
        var value = SessionAttention(); value.validatedForSuppression = true
        let window = SessionWindow(key: key, sourceUpdatedAt: start.addingTimeInterval(1), messages: [RecentMessage(id: "request", role: .user, text: "Implement the feature."), RecentMessage(id: "reply", role: .assistant, text: "Done")])
        value.windows[key] = window
        value.assessments[key] = AssessedSession(contentVersion: window.contentVersion, assessment: .appearsFinished)
        accept(sample("desktop-read", time: 0, unread: false), into: &value)
        accept(sample("runtime", time: 2, activity: .idle), into: &value)
        XCTAssertFalse(value.suppress(item, at: start.addingTimeInterval(2)))
        accept(sample("desktop-read", time: 3, sequence: 2, unread: false), into: &value)
        XCTAssertTrue(value.suppress(item, at: start.addingTimeInterval(3)))
    }
    func testFutureCompletionAndOutOfOrderSameSourceAreRejected() {
        var value = SessionAttention()
        XCTAssertFalse(accept(sample("runtime", time: 0, completion: LiveTurnCompletion(turnID: "future", completedAt: start.addingTimeInterval(1))), into: &value))
        accept(sample("runtime", time: 1, sequence: 5, activity: .working), into: &value)
        XCTAssertFalse(accept(sample("runtime", time: 2, sequence: 4, activity: .idle), into: &value))
        XCTAssertFalse(accept(sample("runtime", time: 0, sequence: 6, activity: .idle), into: &value))
    }
    func testLegacyDecodedSamplesAndExplicitClearRemainSupported() throws {
        let original = sample("runtime", time: 0, activity: .working)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        for key in ["epoch", "activityObservedAt", "unreadObservedAt", "completionObservedAt"] { object.removeValue(forKey: key) }
        let decoded = try JSONDecoder().decode(LiveSessionState.self, from: JSONSerialization.data(withJSONObject: object))
        var value = SessionAttention()
        XCTAssertTrue(accept(decoded, into: &value)); XCTAssertEqual(decoded.epoch, "default")
        value.live.removeAll()
        XCTAssertNil(value.liveState(for: key, at: start))
        value.expireLive(at: start)
        XCTAssertTrue(value.live.isEmpty)
    }
}
