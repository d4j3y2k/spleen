import XCTest
@testable import SpleenCore

final class DiscoveryRankingTests: XCTestCase {
    func destinations(_ count: Int = 5) -> [Destination] {
        (0..<count).map { Destination(title: "Chat \($0)", threadID: "thr_fixture_\($0)") }
    }
    func response(_ probabilities: [Double], choice: String = "c3") -> Data {
        let rows = probabilities.enumerated().map { ["value": $0.offset == probabilities.count - 1 ? "none" : "c\($0.offset)", "probability": $0.element] as [String: Any] }
        return try! JSONSerialization.data(withJSONObject: ["answers": [["type": "choice", "name": "next_chat", "choice": choice, "confidence": 0.8, "probabilities": rows]]])
    }
    func testCatalogDiscardsPreviewAndOutOfScopeRows() throws {
        let data = Data(#"{"data":[{"id":"thr_allowed_1","name":null,"cwd":"/personal","updatedAt":100,"preview":"SECRET"},{"id":"thr_excluded_1","name":"Employer","cwd":"/work","updatedAt":100}],"nextCursor":"next"}"#.utf8)
        let page = try CatalogDecoder.page(data, allowedFolders: ["/personal"])
        XCTAssertEqual(page.entries.count, 1); XCTAssertEqual(page.nextCursor, "next")
        XCTAssertTrue(page.entries[0].title.hasPrefix("Untitled chat"))
        XCTAssertFalse(String(data: try JSONEncoder().encode(page.entries), encoding: .utf8)!.contains("SECRET"))
        XCTAssertEqual(page.entries[0].destination.id, page.entries[0].destination.id)
    }
    func testManualLabelsPinsAndRecentSelectionsWinMerge() throws {
        var cache = CatalogCache(); cache.folders = ["/personal"]
        cache.entries = [CatalogEntry(id: "thr_allowed_1", title: "Provider title", folder: "/personal", updatedAt: Date()), CatalogEntry(id: "thr_allowed_2", title: "Second", folder: "/personal", updatedAt: Date())]
        var saved = SavedState(); try saved.upsert(id: nil, title: "My title", link: "thr_allowed_1", pinned: true)
        let merged = cache.merged(with: saved)
        XCTAssertEqual(merged.destinations.count, 2); XCTAssertEqual(merged.destinations[0].title, "My title")
        XCTAssertTrue(merged.destinations[0].pinned)
        cache.hiddenIDs = ["thr_allowed_2"]; XCTAssertEqual(cache.merged(with: saved).destinations.count, 1)
        cache.folders = []; XCTAssertEqual(cache.merged(with: saved), saved)
    }
    func testMinimalPayloadAndGenerationChanges() throws {
        let input = RankingInput(baseline: destinations())
        let text = String(data: try input.body(now: Date()), encoding: .utf8)!
        XCTAssertTrue(text.contains("gpt-6-luna")); XCTAssertTrue(text.contains("input_json")); XCTAssertTrue(text.contains("none"))
        XCTAssertFalse(text.contains("thr_fixture")); XCTAssertFalse(text.contains("lastOpenedAt"))
        var renamed = destinations(); renamed[0].title = "Changed"
        XCTAssertNotEqual(input.key, RankingInput(baseline: renamed).key)
        renamed = destinations(); renamed[0].lastOpenedAt = Date()
        XCTAssertNotEqual(input.key, RankingInput(baseline: renamed).key)
    }
    func rankingPayload(_ input: RankingInput, now: Date) throws -> [String: Any] {
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: input.body(now: now)) as? [String: Any])
        let messages = try XCTUnwrap(body["input"] as? [[String: Any]])
        let content = try XCTUnwrap(messages.first?["content"] as? [[String: Any]])
        return try XCTUnwrap(content.first?["data"] as? [String: Any])
    }
    func testContextChangesKeyWithoutClockOrCompletionChurn() throws {
        let now = Date(timeIntervalSince1970: 1_000_000), baseline = destinations(2)
        var context = ContextMemory()
        let empty = RankingInput(baseline: baseline, now: now)
        context.record(ContextEvent(key: baseline[0].conversationKey, project: "/private/project", kind: .spleenDispatch,
            observedAt: now.addingTimeInterval(-10), source: "spleen", evidence: .spleenInteraction), now: now)
        let selected = RankingInput(baseline: baseline, context: context, now: now)
        XCTAssertNotEqual(selected.key, empty.key)
        XCTAssertEqual(selected.key, RankingInput(baseline: baseline, context: context, now: now.addingTimeInterval(1)).key)
        context.record(ContextEvent(key: baseline[1].conversationKey, kind: .turnCompleted,
            observedAt: now, source: "hook", evidence: .lifecycle), now: now)
        let completed = RankingInput(baseline: baseline, context: context, now: now)
        XCTAssertEqual(completed.key, selected.key)
        let payload = try rankingPayload(completed, now: now)
        let hint = try XCTUnwrap(payload["last_known_interaction"] as? [String: Any])
        XCTAssertEqual(hint["candidate"] as? String, "c0")
        XCTAssertEqual(hint["evidence"] as? String, "spleenInteraction")
        XCTAssertTrue(payload["last_observed_selection"] is NSNull)
    }
    func testApprovedPayloadIsShortAndOmitsPathsAndTechnicalIDs() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let baseline = [Destination(title: "Review /private/person/repo thr_secret_123", threadID: "thr_secret_123"),
                        Destination(title: "Other", threadID: "thr_other_123")]
        var catalog = CatalogCache(); catalog.folders = ["/private/person/repo"]
        catalog.entries = [CatalogEntry(id: "thr_secret_123", title: "Review", folder: "/private/person/repo", updatedAt: now)]
        let note = ThreadInsight(id: "thr_secret_123", folder: "/private/person/repo", updatedAt: now,
            topic: "Approved note /private/person/secret thr_secret_123 " + String(repeating: "detail ", count: 40))
        let input = RankingInput(baseline: baseline, catalog: catalog, insights: [note], now: now)
        let text = String(data: try input.body(now: now), encoding: .utf8)!
        XCTAssertFalse(text.contains("thr_secret_123")); XCTAssertFalse(text.contains("thr_other_123"))
        XCTAssertFalse(text.contains("private")); XCTAssertFalse(text.contains("person"))
        let payload = try rankingPayload(input, now: now)
        let rows = try XCTUnwrap(payload["candidates"] as? [[String: Any]])
        XCTAssertEqual(rows[0]["project"] as? String, "repo")
        XCTAssertLessThanOrEqual(try XCTUnwrap(rows[0]["label"] as? String).count, 80)
        XCTAssertLessThanOrEqual(try XCTUnwrap(rows[0]["approved_short_note"] as? String).count, 180)
        XCTAssertNotEqual(input.key, RankingInput(baseline: baseline, catalog: catalog, now: now).key)
        catalog.entries[0].updatedAt = now.addingTimeInterval(1)
        let outdated = RankingInput(baseline: baseline, catalog: catalog, insights: [note], now: now)
        XCTAssertNil(outdated.candidates[0].summary, "notes must match current catalog freshness")
    }
    func testExternalTitleTopicIsShortScrubbedAndInvalidatesEvidenceKey() throws {
        let now = Date(timeIntervalSince1970: 1_000_000), baseline = destinations(2)
        let key = ConversationKey(provider: .claude, id: "desktop-code:local_fixture")
        var context = ContextMemory()
        context.record(ContextEvent(key: key,
            topic: "SQLite /private/person/database desktop-code:local_fixture " + String(repeating: "transaction ", count: 20),
            kind: .selectedConversation, observedAt: now, source: "claude-accessibility", evidence: .observedSelection), now: now)
        let input = RankingInput(baseline: baseline, context: context, now: now)
        let payload = try rankingPayload(input, now: now)
        let hint = try XCTUnwrap(payload["last_known_interaction"] as? [String: Any])
        let topic = try XCTUnwrap(hint["approved_topic"] as? String)
        XCTAssertTrue(topic.hasPrefix("SQLite")); XCTAssertLessThanOrEqual(topic.count, 180)
        XCTAssertFalse(topic.contains("private")); XCTAssertFalse(topic.contains("local_fixture"))
        XCTAssertTrue(hint["candidate"] is NSNull)
        XCTAssertEqual(hint["provider"] as? String, "claude")
        context.record(ContextEvent(key: key, topic: "Piano melody", kind: .selectedConversation,
            observedAt: now, source: "claude-accessibility", evidence: .observedSelection), now: now)
        XCTAssertNotEqual(input.key, RankingInput(baseline: baseline, context: context, now: now).key)
    }
    func testCrossProviderIDsRemainSeparateThroughRemoteAliasesAndSnapshot() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let baseline = [Destination(title: "Codex task", threadID: "shared_fixture_id"),
                        Destination(title: "Claude task", threadID: "shared_fixture_id", provider: .claude)]
        var catalog = CatalogCache(); catalog.folders = ["/project"]
        catalog.entries = [CatalogEntry(id: "shared_fixture_id", title: "Codex", folder: "/project", updatedAt: now)]
        let note = ThreadInsight(id: "shared_fixture_id", folder: "/project", updatedAt: now, topic: "Codex approved note")
        var context = ContextMemory()
        context.record(ContextEvent(key: baseline[0].conversationKey, kind: .spleenDispatch,
            observedAt: now.addingTimeInterval(-1), source: "spleen", evidence: .spleenInteraction), now: now)
        context.record(ContextEvent(key: baseline[1].conversationKey, kind: .spleenDispatch,
            observedAt: now, source: "spleen", evidence: .spleenInteraction), now: now)
        let input = RankingInput(baseline: baseline, context: context, catalog: catalog, insights: [note], now: now)
        XCTAssertEqual(input.candidates.count, 2)
        XCTAssertNotEqual(input.candidates[0].localKey, input.candidates[1].localKey)
        XCTAssertNotNil(input.candidates[0].summary); XCTAssertNil(input.candidates[1].summary)
        XCTAssertNil(input.candidates[1].project)
        let result = response([0.2, 0.7, 0.1], choice: "c1")
        XCTAssertEqual(try input.order(response: result), ["claude:shared_fixture_id", "codex:shared_fixture_id"])
        let payload = try rankingPayload(input, now: now)
        let transitions = try XCTUnwrap(payload["recent_transitions"] as? [[String: Any]])
        XCTAssertEqual(transitions.count, 1)
        XCTAssertEqual(transitions[0]["from"] as? String, "c0")
        XCTAssertEqual(transitions[0]["to"] as? String, "c1")
        var pipeline = RankingPipeline()
        let job = try XCTUnwrap(pipeline.begin(input, now: 0))
        pipeline.finish(job, response: .success(result), now: 0.1)
        XCTAssertEqual(pipeline.snapshot(baseline: baseline, input: input, now: 0.2).map(\.provider), [.claude, .codex])
        var changed = baseline; changed[0].title = "Changed after build"
        XCTAssertEqual(pipeline.snapshot(baseline: changed, input: input, now: 0.3), changed)
    }
    func testRankingPreservesPinsAndFallsBackOnExpiryOrChangedCandidates() throws {
        var baseline = destinations(); baseline.insert(Destination(title: "Pin", threadID: "thr_pin_123", pinned: true), at: 0)
        var pipeline = RankingPipeline()
        let job = try XCTUnwrap(pipeline.begin(RankingInput(baseline: baseline), now: 10))
        XCTAssertEqual(pipeline.snapshot(baseline: baseline, now: 10.1), baseline)
        pipeline.finish(job, response: .success(response([0.05, 0.05, 0.1, 0.7, 0.05, 0.05])), now: 10.2)
        let ready = pipeline.snapshot(baseline: baseline, now: 11)
        XCTAssertEqual(ready.first?.threadID, "thr_fixture_3"); XCTAssertEqual(ready[1].threadID, "thr_pin_123")
        XCTAssertEqual(pipeline.snapshot(baseline: baseline, now: 131), baseline)
        baseline[2].title = "New name"
        XCTAssertEqual(pipeline.snapshot(baseline: baseline, now: 12), baseline)
        XCTAssertEqual(pipeline.metrics.calls, 1); XCTAssertEqual(pipeline.metrics.ready, 1)
    }
    func testLateSupersededFailedAndMissingResultsCountTowardCap() throws {
        var pipeline = RankingPipeline(requestCap: 3)
        let baseline = destinations(), input = RankingInput(baseline: destinations())
        let first = try XCTUnwrap(pipeline.begin(input, now: 0))
        XCTAssertNil(pipeline.begin(input, now: 0.2))
        pipeline.finish(first, response: .success(response([0.1,0.1,0.1,0.5,0.1,0.1])), now: 1)
        XCTAssertEqual(pipeline.snapshot(baseline: baseline, now: 1), baseline)
        var changed = baseline; changed[0].title = "Changed"
        let second = try XCTUnwrap(pipeline.begin(RankingInput(baseline: changed), now: 2))
        changed[0].title = "Changed again"
        let third = try XCTUnwrap(pipeline.begin(RankingInput(baseline: changed), now: 2.1))
        pipeline.finish(second, response: .failure(RankingError.httpError), now: 2.2)
        pipeline.finish(third, response: .success(Data("{}".utf8)), now: 2.3)
        XCTAssertNil(pipeline.begin(input, now: 3))
        XCTAssertEqual(pipeline.metrics.calls, 3); XCTAssertEqual(pipeline.metrics.late, 2)
        XCTAssertEqual(pipeline.metrics.failed, 1); XCTAssertEqual(pipeline.metrics.superseded, 1)
    }
    func testNoneAndMalformedAnswers() throws {
        let input = RankingInput(baseline: destinations())
        XCTAssertNil(try input.order(response: response([0.1,0.1,0.1,0.1,0.1,0.5], choice: "none")))
        for data in [Data(#"{"answers":[{"type":"refusal","name":"next_chat"}]}"#.utf8), response([0.5, 0.5]), response([0.1,0.1,0.1,0.5,0.1,0.1], choice: "invented"), response([1,1,1,1,1,1])] {
            XCTAssertThrowsError(try input.order(response: data))
        }
    }
    func testEvaluationIncludesMissingTargetsAndFallbackInvocations() {
        var evaluation = RankingEvaluation()
        evaluation.record(target: "d", candidates: ["a","b","c","d"], local: ["a","b","c","d"], deployed: ["d","a","b","c"], remoteReady: true)
        evaluation.record(target: "d", candidates: ["a","b","c","d"], local: ["a","b","c","d"], deployed: ["a","b","c","d"], remoteReady: false)
        evaluation.record(target: "missing", candidates: ["a"], local: ["a"], deployed: ["a"], remoteReady: false)
        evaluation.record(target: nil, candidates: [], local: [], deployed: [], remoteReady: false)
        XCTAssertEqual(evaluation.labeled, 3); XCTAssertEqual(evaluation.covered, 2)
        XCTAssertEqual(evaluation.deployedTop3, 1); XCTAssertEqual(evaluation.readyTop3, 1); XCTAssertEqual(evaluation.readyLabeled, 1)
        print("Synthetic evaluation (NOT user quality): coverage 2/3; local top3 0/3; deployed top3 1/3; ready-only top3 1/1.")
    }
    func testInjectedTransportAndNoAutomaticRetry() throws {
        final class MockTransport: DecisionsTransport {
            var bodies: [Data] = []
            var completion: ((Result<Data, Error>) -> Void)?
            var cancelled = false
            func send(body: Data, completion: @escaping (Result<Data, Error>) -> Void) -> (() -> Void) {
                bodies.append(body); self.completion = completion
                return { self.cancelled = true }
            }
        }
        let transport = MockTransport(), input = RankingInput(baseline: destinations())
        var pipeline = RankingPipeline()
        let job = try XCTUnwrap(pipeline.begin(input, now: 0))
        let cancel = transport.send(body: try input.body(now: Date())) { result in
            pipeline.finish(job, response: result, now: 0.8)
        }
        cancel()
        // Even a transport that completes after cancellation cannot install a late result.
        transport.completion?(.success(response([0.1,0.1,0.1,0.5,0.1,0.1])))
        XCTAssertTrue(transport.cancelled); XCTAssertEqual(transport.bodies.count, 1)
        XCTAssertEqual(pipeline.snapshot(baseline: destinations(), now: 1).map(\.threadID), destinations().map(\.threadID))
        XCTAssertNil(pipeline.begin(input, now: 10), "uncertain/failed requests are not automatically retried")
        XCTAssertEqual(pipeline.metrics.calls, 1); XCTAssertEqual(pipeline.metrics.late, 1)
    }
    func testLocalSearchBenchmark() {
        var state = SavedState(); state.destinations = destinations(1000)
        var samples: [Double] = []
        for _ in 0..<100 {
            let start = ProcessInfo.processInfo.systemUptime
            _ = state.results(query: "Chat 99")
            samples.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
        }
        samples.sort()
        print(String(format: "Local search 1000 candidates / 100 samples (debug): median %.3f ms, p95 %.3f ms, max %.3f ms", samples[50], samples[94], samples[99]))
        XCTAssertEqual(state.results(query: "Chat 99").count, 11)
    }
}
