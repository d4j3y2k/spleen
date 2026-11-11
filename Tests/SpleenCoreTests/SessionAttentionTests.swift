import XCTest
@testable import SpleenCore

final class SessionAttentionTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let item = Destination(title: "Finished project", threadID: "thr_attention_fixture")
    func window(_ text: String = "Delivered and tested.", incomplete: Bool = false) -> SessionWindow {
        SessionWindow(key: item.conversationKey, sourceUpdatedAt: now.addingTimeInterval(-1), messages: [
            RecentMessage(id: "u1", role: .user, text: "Please implement the requested feature."),
            RecentMessage(id: "a1", role: .assistant, text: text)
        ], incomplete: incomplete)
    }
    func attention(_ window: SessionWindow) -> SessionAttention {
        var value = SessionAttention(); value.validatedForSuppression = true
        value.windows[item.conversationKey] = window
        value.assessments[item.conversationKey] = AssessedSession(contentVersion: window.contentVersion, assessment: .appearsFinished)
        return value
    }
    func sample(activity: RuntimeActivity? = .idle, unread: Bool? = false, sequence: UInt64 = 1, at date: Date? = nil, host: String = "local") -> LiveSessionState {
        LiveSessionState(key: item.conversationKey, host: host, source: "fixture-owning-runtime", observedAt: date ?? now,
            sequence: sequence, activity: activity, isUnread: unread)
    }
    func response(_ state: TaskAssessment) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["answers": [["type": "choice", "name": "task_state", "choice": state.rawValue, "confidence": 0.9,
            "probabilities": TaskAssessment.allCases.map { ["value": $0.rawValue, "probability": $0 == state ? 0.85 : 0.05] as [String: Any] }]]])
    }
    func testUnknownUnreadOrRuntimeCannotExcludeFinishedTask() {
        for (activity, unread) in [(nil, false), (RuntimeActivity.idle, nil), (nil, nil)] {
            var value = attention(window()); _ = value.accept(sample(activity: activity, unread: unread), now: now)
            XCTAssertFalse(value.suppress(item, at: now))
        }
    }
    func testUnreadRunningAndBlockersProtectFinishedTask() {
        for sample in [sample(unread: true), sample(activity: .working), sample(activity: .waitingForApproval), sample(activity: .waitingForInput)] {
            var value = attention(window()); XCTAssertTrue(value.accept(sample, now: now))
            XCTAssertFalse(value.suppress(item, at: now)); XCTAssertEqual(value.priority(item, at: now), 2)
        }
    }
    func testReadIdleValidatedTaskSuppressedButSearchableAndPinsProtected() {
        var value = attention(window()); _ = value.accept(sample(), now: now)
        XCTAssertTrue(value.suppress(item, at: now))
        var state = SavedState(); state.destinations = [item]
        let snapshot = RelevanceSnapshot(state: state, catalog: CatalogCache(), now: now, attention: value)
        XCTAssertTrue(snapshot.ordered.isEmpty)
        XCTAssertEqual(snapshot.results(query: "Finished"), [item])
        var pinned = item; pinned.pinned = true
        XCTAssertFalse(value.suppress(pinned, at: now))
        value.validatedForSuppression = false
        XCTAssertFalse(value.suppress(item, at: now))
    }
    func testStaleDisconnectedFutureAndRemoteSamplesAreUnknown() {
        var value = attention(window()); _ = value.accept(sample(), now: now)
        XCTAssertNil(value.liveState(for: item.conversationKey, at: now.addingTimeInterval(31)))
        XCTAssertFalse(value.suppress(item, at: now.addingTimeInterval(31)))
        XCTAssertFalse(value.accept(sample(at: now.addingTimeInterval(1)), now: now))
        XCTAssertFalse(value.accept(sample(host: "remote"), now: now))
        value.live.removeAll()
        XCTAssertFalse(value.suppress(item, at: now))
    }
    func testOutOfOrderEventsCannotEraseWorkingOrUnread() {
        var value = attention(window())
        XCTAssertTrue(value.accept(sample(activity: .working, unread: true, sequence: 2), now: now))
        XCTAssertFalse(value.accept(sample(sequence: 1), now: now))
        XCTAssertEqual(value.live[item.conversationKey]?.activity, .working)
        XCTAssertEqual(value.live[item.conversationKey]?.isUnread, true)
    }
    func testNewRequestReopensAndRejectsOldAssessment() {
        let old = window(); var value = attention(old)
        let new = SessionWindow(key: item.conversationKey, sourceUpdatedAt: now, messages: old.messages + [RecentMessage(id: "u2", role: .user, text: "Also fix the keyboard shortcut.")])
        value.windows[item.conversationKey] = new
        XCTAssertEqual(value.assessment(for: item.conversationKey), .ongoing)
        XCTAssertFalse(value.apply(AssessedSession(contentVersion: old.contentVersion, assessment: .appearsFinished), for: old))
        XCTAssertFalse(value.suppress(item, at: now))
    }
    func testContentIdentitySeparatesProviderHostOrderAndTextButNotMetadataTime() {
        let original = window()
        let timestampOnly = SessionWindow(key: original.key, sourceUpdatedAt: now, messages: original.messages)
        XCTAssertEqual(original.contentVersion, timestampOnly.contentVersion)
        for changed in [SessionWindow(key: original.key, host: "remote", sourceUpdatedAt: now, messages: original.messages),
            SessionWindow(key: ConversationKey(provider: .claude, id: original.key.id), sourceUpdatedAt: now, messages: original.messages),
            SessionWindow(key: original.key, sourceUpdatedAt: now, messages: original.messages.reversed()), window("Still need to test.")] {
            XCTAssertNotEqual(original.contentVersion, changed.contentVersion)
        }
    }
    func testIncompleteEvidenceCannotFinishEvenWithModelChoice() throws {
        let input = SessionAssessmentInput(window: window(incomplete: true))
        XCTAssertEqual(try input.result(response(.appearsFinished)).assessment, .unclear)
    }
    func testEscapedUnicodePayloadCompactionIsBoundedAndCannotFinish() throws {
        let messages = (0..<6).map { RecentMessage(id: "\($0)", role: $0 % 2 == 0 ? .user : .assistant, text: String(repeating: "🧑🏽‍💻\"\\", count: 300)) }
        let input = SessionAssessmentInput(window: SessionWindow(key: item.conversationKey, sourceUpdatedAt: now, messages: messages))
        XCTAssertLessThanOrEqual(try input.body().count, SessionAssessmentInput.maximumRequestBytes)
        XCTAssertEqual(try input.body(), try input.body())
        XCTAssertEqual(try input.result(response(.appearsFinished)).assessment, .unclear)
    }
    func testALongMessageKeepsItsBeginningAndEndingAndStaysAssessable() throws {
        let long = "Opening summary. " + String(repeating: "detail ", count: 900) + "All checks pass and nothing remains."
        let message = RecentMessage(id: "a1", role: .assistant, text: long)
        XCTAssertTrue(message.truncated)
        XCTAssertEqual(message.middleOmitted, true)
        XCTAssertEqual(message.text.unicodeScalars.count, RecentMessage.maximumScalars)
        XCTAssertTrue(message.text.hasPrefix("Opening summary. "))
        XCTAssertTrue(message.text.hasSuffix("All checks pass and nothing remains."))
        XCTAssertTrue(message.text.contains(RecentMessage.omissionMarker))
        let window = SessionWindow(key: item.conversationKey, sourceUpdatedAt: now, messages: [
            RecentMessage(id: "u1", role: .user, text: "Please implement the requested feature."), message])
        XCTAssertFalse(window.incomplete)
        XCTAssertFalse(window.needsRefetch)
        let input = SessionAssessmentInput(window: window)
        let payload = try JSONSerialization.jsonObject(with: input.body()) as! [String: Any]
        let content = ((payload["input"] as! [[String: Any]])[0]["content"] as! [[String: Any]])[0]["data"] as! [String: Any]
        XCTAssertEqual(content["incomplete"] as? Bool, false)
        XCTAssertEqual((content["messages"] as! [[String: Any]])[1]["truncated"] as? Bool, true)
        XCTAssertEqual(try input.result(response(.appearsFinished)).assessment, .appearsFinished)
        XCTAssertEqual(AutomaticAttention.nextWindow(windows: [window], cachedVersions: [], attemptedVersions: [])?.key, window.key)
        // The stored form round-trips, and an untruncated message encodes as it always did.
        XCTAssertEqual(try JSONDecoder().decode(SessionWindow.self, from: JSONEncoder().encode(window)), window)
        let short = try JSONSerialization.jsonObject(with: JSONEncoder().encode(RecentMessage(id: "s", role: .user, text: "Short."))) as! [String: Any]
        XCTAssertEqual(Set(short.keys), ["id", "role", "text", "truncated"])
    }
    func testSixFullLengthMessagesFitWithoutCompaction() throws {
        let messages = (0..<6).map { RecentMessage(id: "\($0)", role: $0 % 2 == 0 ? .user : .assistant, text: String(repeating: "word ", count: 600)) }
        let window = SessionWindow(key: item.conversationKey, sourceUpdatedAt: now, messages: messages)
        XCTAssertFalse(window.incomplete)
        let input = SessionAssessmentInput(window: window)
        XCTAssertLessThanOrEqual(try input.body().count, SessionAssessmentInput.maximumRequestBytes)
        XCTAssertEqual(try input.result(response(.appearsFinished)).assessment, .appearsFinished)
    }
    func testALongMessageHoldingASecretKeepsOnlyItsBeginningAndIsNeverSent() {
        // The key sits where the ending would start, so a cut there would send its tail unrecognized.
        let secret = "sk-proj-" + String(repeating: "k", count: 60)
        let padding = String(repeating: "x ", count: 400)
        let long = String(repeating: "detail ", count: 400) + padding + secret + String(repeating: " tail", count: 300)
        let message = RecentMessage(id: "a1", role: .assistant, text: long)
        XCTAssertTrue(message.truncated)
        XCTAssertEqual(message.middleOmitted, false)
        XCTAssertFalse(message.text.contains(RecentMessage.omissionMarker))
        XCTAssertFalse(message.text.contains("kkkk"))
        let window = SessionWindow(key: item.conversationKey, sourceUpdatedAt: now, messages: [
            RecentMessage(id: "u1", role: .user, text: "Please implement the requested feature."), message])
        XCTAssertTrue(window.incomplete)
        XCTAssertFalse(window.needsRefetch) // Reading it again would give the same result.
        XCTAssertNil(AutomaticAttention.nextWindow(windows: [window], cachedVersions: [], attemptedVersions: []))
    }
    func testWindowsCachedWithOnlyABeginningStayIncompleteUntilReadAgain() throws {
        let legacy = Data(#"{"key":{"provider":"codex","id":"thr_attention_fixture"},"host":"local","sourceUpdatedAt":0,"incomplete":true,"messages":[{"id":"u1","role":"user","text":"Please implement it.","truncated":false},{"id":"a1","role":"assistant","text":"A beginning without its ending","truncated":true}]}"#.utf8)
        let window = try JSONDecoder().decode(SessionWindow.self, from: legacy)
        XCTAssertNil(window.messages[1].middleOmitted)
        XCTAssertTrue(window.incomplete)
        XCTAssertTrue(window.needsRefetch)
        XCTAssertNil(AutomaticAttention.nextWindow(windows: [window], cachedVersions: [], attemptedVersions: []))
        XCTAssertEqual(try SessionAssessmentInput(window: window).result(response(.appearsFinished)).assessment, .unclear)
        // A caller that declares its own truncation is not trusted to have kept the ending.
        XCTAssertTrue(RecentMessage(id: "c", role: .assistant, text: "Cut by the caller", truncated: true).losesEnding)
    }
    func testValidChoicesAndMalformedResponses() throws {
        let input = SessionAssessmentInput(window: window())
        for choice in TaskAssessment.allCases { XCTAssertEqual(try input.result(response(choice)).assessment, choice) }
        XCTAssertThrowsError(try input.result(Data("{\"answers\":[]}".utf8)))
        XCTAssertThrowsError(try input.result(Data("{\"answers\":[{\"type\":\"refusal\"}]}".utf8)))
    }
    func testMissingRequestCannotBeClassifiedFinishedIncludingDecodedWindows() throws {
        for messages in [[], [RecentMessage(id: "a", role: .assistant, text: "All done.")],
                         [RecentMessage(id: "u", role: .user, text: "  "), RecentMessage(id: "a", role: .assistant, text: "Done")]] {
            let missing = SessionWindow(key: item.conversationKey, sourceUpdatedAt: now, messages: messages)
            XCTAssertTrue(missing.incomplete)
            XCTAssertEqual(try SessionAssessmentInput(window: missing).result(response(.appearsFinished)).assessment, .unclear)
            // Older stored windows may claim completeness, so validate at use too.
            var stored = try JSONSerialization.jsonObject(with: JSONEncoder().encode(missing)) as! [String: Any]
            stored["incomplete"] = false
            let decoded = try JSONDecoder().decode(SessionWindow.self, from: JSONSerialization.data(withJSONObject: stored))
            XCTAssertEqual(attention(decoded).assessment(for: item.conversationKey), .unclear)
            XCTAssertEqual(try SessionAssessmentInput(window: decoded).result(response(.appearsFinished)).assessment, .unclear)
        }
    }
    func testUnansweredInputOverridesAllModelChoices() throws {
        let pending = SessionWindow(key: item.conversationKey, sourceUpdatedAt: now, messages: [
            RecentMessage(id: "u", role: .user, text: "Please fix the remaining bug.")])
        for state in TaskAssessment.allCases {
            XCTAssertEqual(try SessionAssessmentInput(window: pending).result(response(state)).assessment, .ongoing)
        }
    }
    func testOngoingWaitingAndFinishedHaveDistinctPriorityAndPreserveLiveEvidence() throws {
        let cases: [(String, TaskAssessment, Int)] = [
            ("Implementation is ready but required tests still fail.", .ongoing, 1),
            ("Which of these two deployment targets should I use?", .waitingForUser, 1),
            ("Implemented, required tests passed. I can also add a theme later if you like.", .appearsFinished, -1)]
        for (text, state, priority) in cases {
            let w = window(text); var value = SessionAttention(); value.windows[item.conversationKey] = w
            XCTAssertTrue(value.apply(try SessionAssessmentInput(window: w).result(response(state)), for: w))
            XCTAssertEqual(value.assessment(for: item.conversationKey), state)
            XCTAssertEqual(value.priority(item, at: now), priority)
            XCTAssertFalse(value.suppress(item, at: now)) // No classifier-driven hiding by default.
            _ = value.accept(sample(activity: .waitingForApproval), now: now)
            XCTAssertEqual(value.priority(item, at: now), 2)
        }
    }
    func testTiedOrDisagreeingProbabilitiesRemainUnclear() throws {
        for probabilities in [[0.4, 0.1, 0.4, 0.1], [0.6, 0.1, 0.2, 0.1]] {
            let data = try JSONSerialization.data(withJSONObject: ["answers": [["type": "choice", "name": "task_state",
                "choice": "appears_finished", "confidence": 0.9,
                "probabilities": zip(TaskAssessment.allCases, probabilities).map { ["value": $0.0.rawValue, "probability": $0.1] as [String: Any] }]]])
            XCTAssertEqual(try SessionAssessmentInput(window: window()).result(data).assessment, .unclear)
        }
    }
    func testFinishedNeedsMinimumProbabilityButOtherChoicesDoNot() throws {
        // Probability order: ongoing, waiting_for_user, appears_finished, unclear.
        func data(_ choice: TaskAssessment, _ probabilities: [Double]) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["answers": [["type": "choice", "name": "task_state",
                "choice": choice.rawValue, "confidence": 0.5,
                "probabilities": zip(TaskAssessment.allCases, probabilities).map { ["value": $0.0.rawValue, "probability": $0.1] as [String: Any] }]]])
        }
        let w = window(), input = SessionAssessmentInput(window: w)
        let weak = try input.result(data(.appearsFinished, [0.2, 0.1, 0.69, 0.01]))
        XCTAssertEqual(weak.assessment, .unclear)
        var value = SessionAttention(); value.windows[item.conversationKey] = w
        XCTAssertTrue(value.apply(weak, for: w))
        XCTAssertEqual(value.priority(item, at: now), 0) // No demotion.
        XCTAssertEqual(try input.result(data(.appearsFinished, [0.2, 0.05, 0.7, 0.05])).assessment, .appearsFinished)
        XCTAssertEqual(try input.result(data(.ongoing, [0.4, 0.3, 0.2, 0.1])).assessment, .ongoing)
        XCTAssertEqual(try input.result(data(.waitingForUser, [0.3, 0.4, 0.2, 0.1])).assessment, .waitingForUser)
    }
    func testNewerCodexActivityMakesRetainedMessagesStale() {
        // Codex reports the update in whole seconds, after the turn's own activity.
        let updated = now.addingTimeInterval(-600)
        let w = SessionWindow(key: item.conversationKey, sourceUpdatedAt: updated, messages: [
            RecentMessage(id: "u1", role: .user, text: "Please implement the requested feature."),
            RecentMessage(id: "a1", role: .assistant, text: "Delivered and tested.")])
        var value = SessionAttention(); value.windows[item.conversationKey] = w
        value.assessments[item.conversationKey] = AssessedSession(contentVersion: w.contentVersion, assessment: .appearsFinished)
        value.rememberActivity([item.conversationKey: updated.addingTimeInterval(0.6)], at: now)
        XCTAssertFalse(value.hasNewerActivity(item.conversationKey, at: now), "same-second activity belongs to the retained turn")
        XCTAssertEqual(value.assessment(for: item.conversationKey, at: now), .appearsFinished)
        // A new message after the turn finished: the saved label is stale until the next turn's messages arrive.
        value.rememberActivity([item.conversationKey: updated.addingTimeInterval(120)], at: now)
        XCTAssertTrue(value.hasNewerActivity(item.conversationKey, at: now))
        XCTAssertEqual(value.assessment(for: item.conversationKey, at: now), .ongoing)
        XCTAssertEqual(value.priority(item, at: now), 1)
        let later = updated.addingTimeInterval(120 + ContextMemory.hintLifetime)
        XCTAssertFalse(value.hasNewerActivity(item.conversationKey, at: later), "expired activity is not evidence")
        // The next turn's messages are newer than that activity.
        let next = SessionWindow(key: item.conversationKey, sourceUpdatedAt: updated.addingTimeInterval(200), messages: w.messages + [
            RecentMessage(id: "u2", role: .user, text: "One more fix."), RecentMessage(id: "a2", role: .assistant, text: "Fixed.")])
        value.windows[item.conversationKey] = next
        XCTAssertFalse(value.hasNewerActivity(item.conversationKey, at: now))
    }
    func testDuplicateUnknownAndInvalidProbabilitiesAreRejected() throws {
        for mutation in ["duplicate", "unknown", "negative", "sum", "confidence"] {
            var object = try JSONSerialization.jsonObject(with: response(.appearsFinished)) as! [String: Any]
            var answers = object["answers"] as! [[String: Any]]
            var probabilities = answers[0]["probabilities"] as! [[String: Any]]
            switch mutation {
            case "duplicate": probabilities[0]["value"] = probabilities[1]["value"]
            case "unknown": probabilities[0]["value"] = "done"
            case "negative": probabilities[0]["probability"] = -0.1
            case "sum": probabilities[0]["probability"] = 0.9
            default: answers[0]["confidence"] = 2
            }
            answers[0]["probabilities"] = probabilities; object["answers"] = answers
            XCTAssertThrowsError(try SessionAssessmentInput(window: window()).result(JSONSerialization.data(withJSONObject: object)), mutation)
        }
    }
    func testDecoderPreservesChronologicalRolesEndingAndUnansweredRequest() throws {
        let entry = CatalogEntry(id: item.threadID, title: item.title, folder: "/fixture", updatedAt: now)
        let json: [String: Any] = ["data": [
            ["id": "t2", "items": [["id": "u2", "type": "userMessage", "content": [["type": "text", "text": "One more fix please."]]]]],
            ["id": "t1", "items": [["id": "u1", "type": "userMessage", "content": [["type": "text", "text": "Implement this."]]],
                ["id": "c1", "type": "agentMessage", "phase": "commentary", "text": "Working"],
                ["id": "a1", "type": "agentMessage", "text": "Implemented. Tests still failing."]]]
        ]]
        let note = try InsightDecoder.page(JSONSerialization.data(withJSONObject: json), entry: entry)
        XCTAssertEqual(note.window?.messages.map(\.id), ["u1", "a1", "u2"])
        XCTAssertEqual(note.window?.messages.map(\.role), [.user, .assistant, .user])
        XCTAssertEqual(note.window?.messages[1].text, "Implemented. Tests still failing.")
        XCTAssertEqual(note.window?.unansweredUser, true)
    }
}

final class AttentionRankingRegressionTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    func testPreparedAndFreshAgreeAcrossEachWorkingSetExpiry() {
        var state = SavedState()
        state.destinations = [Destination(title: "SQLite WAL", threadID: "thr_current_fixture"),
            Destination(title: "Piano", threadID: "thr_old_fixture"), Destination(title: "SQLite transaction", threadID: "thr_related_fixture")]
        var memory = ContextMemory()
        memory.record(ContextEvent(key: state.destinations[1].conversationKey, kind: .spleenDispatch, observedAt: now.addingTimeInterval(-1790), source: "spleen", evidence: .spleenInteraction), now: now)
        memory.record(ContextEvent(key: state.destinations[0].conversationKey, kind: .spleenDispatch, observedAt: now, source: "spleen", evidence: .spleenInteraction), now: now)
        let prepared = PreparedContext(state: state, catalog: CatalogCache(), context: memory, now: now, uptime: 100)
        for offset in [0.0, 9, 10, 11, 1799, 1800, 1801] {
            let time = now.addingTimeInterval(offset)
            let fresh = RelevanceSnapshot(state: state, catalog: CatalogCache(), context: memory, now: time)
            XCTAssertEqual(prepared.snapshot(now: time, uptime: 100 + offset).ordered, fresh.ordered, "offset \(offset)")
        }
        XCTAssertFalse(prepared.isFresh(now: now.addingTimeInterval(10), uptime: 110))
    }
    func testLiveSampleLifetimeDoesNotExpirePreparedContext() {
        var state = SavedState()
        state.destinations = [Destination(title: "Working", threadID: "thr_working_fixture"), Destination(title: "Other", threadID: "thr_other_fixture")]
        var attention = SessionAttention()
        attention.accept(LiveSessionState(key: state.destinations[0].conversationKey, source: "fixture", observedAt: now,
            lifetime: 8, sequence: 1, activity: .working, isUnread: nil), now: now)
        let prepared = PreparedContext(state: state, catalog: CatalogCache(), now: now, uptime: 100, attention: attention)
        // A producer that keeps reporting would otherwise force a full rebuild every few seconds.
        XCTAssertTrue(prepared.isFresh(now: now.addingTimeInterval(9), uptime: 109),
                      "the heartbeat rebuilds when a sample actually lapses")
    }
    func testExpiredSavedSelectionDoesNotResurrectCurrentTopic() {
        var state = SavedState(); state.destinations = [
            Destination(title: "SQLite WAL", threadID: "thr_current_fixture", lastOpenedAt: now.addingTimeInterval(-1801)),
            Destination(title: "SQLite transaction", threadID: "thr_related_fixture")]
        let snapshot = RelevanceSnapshot(state: state, catalog: CatalogCache(), now: now)
        XCTAssertFalse(snapshot.subtitles.values.contains { $0.contains("Last selected") })
    }
    func testSavedGenericLabelKeepsFreshObservedTopic() {
        let current = Destination(title: "Main", threadID: "thr_current_fixture")
        let related = Destination(title: "SQLite WAL locking transaction contention", threadID: "thr_related_fixture")
        let other = Destination(title: "Painting", threadID: "thr_other_fixture")
        var state = SavedState(); state.destinations = [current, other, related]
        var memory = ContextMemory()
        memory.record(ContextEvent(key: current.conversationKey, topic: related.title, kind: .selectedConversation,
            observedAt: now, source: "fixture", evidence: .observedSelection), now: now)
        XCTAssertEqual(RelevanceSnapshot(state: state, catalog: CatalogCache(), context: memory, now: now).ordered.first, related)
    }
    func testRemoteCannotPromoteCurrentConversation() {
        let current = Destination(title: "Current", threadID: "thr_current_fixture", lastOpenedAt: now)
        let other = Destination(title: "Other", threadID: "thr_other_fixture")
        XCTAssertEqual(RankingInput(baseline: [other, current], now: now, excludingCurrent: current.conversationKey).candidates.map(\.id), [other.threadID])
    }
}

final class ReviewedAttentionTrialTests: XCTestCase {
    func testOnlyExactReviewedPayloadCanReachTransport() throws {
        final class Transport: DecisionsTransport {
            var calls = 0
            func send(body: Data, completion: @escaping (Result<Data, Error>) -> Void) -> (() -> Void) {
                calls += 1; return {}
            }
        }
        let body = Data("reviewed".utf8)
        let config = try DecisionsTrialConfiguration(id: "fixture", maximumRequests: 1, expiresAt: Date().addingTimeInterval(60))
        let manifest = AttentionTrialManifest(configuration: config, bodies: [body])
        let underlying = Transport(), transport = ReviewedAttentionTransport(manifest: manifest, underlying: underlying)
        var rejected = false
        _ = transport.send(body: Data("new private message".utf8)) { if case .failure = $0 { rejected = true } }
        XCTAssertTrue(rejected); XCTAssertEqual(underlying.calls, 0)
        _ = transport.send(body: body) { _ in }
        XCTAssertEqual(underlying.calls, 1)
    }
}
