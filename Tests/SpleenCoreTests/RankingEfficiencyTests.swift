import XCTest
@testable import SpleenCore

final class RankingEfficiencyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private func payload(_ body: Data) throws -> [String: Any] {
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try XCTUnwrap(root["input"] as? [[String: Any]])
        let content = try XCTUnwrap(messages.first?["content"] as? [[String: Any]])
        return try XCTUnwrap(content.first?["data"] as? [String: Any])
    }
    private func response(_ values: [Double], choice: String) throws -> Data {
        let probabilities = values.enumerated().map { ["value": $0.offset == values.count - 1 ? "none" : "c\($0.offset)", "probability": $0.element] as [String: Any] }
        return try JSONSerialization.data(withJSONObject: ["answers": [["type": "choice", "name": "next_chat", "choice": choice, "confidence": 0.8, "probabilities": probabilities]]])
    }
    private func fixture(label: String) -> ([Destination], CatalogCache, [ThreadInsight]) {
        let folder = "/fixture/" + String(repeating: "👨‍👩‍👧‍👦", count: 80)
        let baseline = (0..<8).map { Destination(title: label + " \($0)", threadID: "thr_fixture_\($0)", lastOpenedAt: now) }
        var catalog = CatalogCache(); catalog.folders = [folder]
        catalog.entries = baseline.map { CatalogEntry(id: $0.threadID, title: $0.title, folder: folder, updatedAt: now) }
        let notes = catalog.entries.map { ThreadInsight(id: $0.id, folder: $0.folder, updatedAt: now, topic: String(repeating: "👨‍👩‍👧‍👦", count: 180)) }
        return (baseline, catalog, notes)
    }
    func testExtremeUnicodePayloadFitsWithoutDroppingAliasesOrEvidence() throws {
        let (baseline, catalog, notes) = fixture(label: String(repeating: "👨‍👩‍👧‍👦", count: 80))
        // An Eulerian circuit supplies every distinct directed pair within the 64-event cap.
        var edges = (0..<8).map { from in (0..<8).filter { $0 != from } }, stack = [0], circuit: [Int] = []
        while let vertex = stack.last {
            if let next = edges[vertex].popLast() { stack.append(next) }
            else { circuit.append(stack.removeLast()) }
        }
        var context = ContextMemory()
        for (index, candidate) in circuit.reversed().enumerated() {
            context.record(ContextEvent(key: baseline[candidate].conversationKey, project: catalog.folders[0], topic: notes[candidate].topic,
                kind: .selectedConversation, observedAt: now.addingTimeInterval(Double(index - 60)), source: "fixture", evidence: .observedSelection), now: now)
        }
        let input = RankingInput(baseline: baseline, context: context, catalog: catalog, insights: notes, now: now)
        let body = try input.body(now: now), data = try payload(body)
        XCTAssertLessThanOrEqual(body.count, DecisionsTrialLedger.maximumRequestBytes)
        XCTAssertEqual(body, try input.body(now: now), "compaction must be deterministic")
        let rows = try XCTUnwrap(data["candidates"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 8)
        XCTAssertEqual(rows.compactMap { $0["candidate"] as? String }, (0..<8).map { "c\($0)" })
        XCTAssertTrue(rows.allSatisfy { ($0["label"] as? String)?.isEmpty == false })
        XCTAssertTrue(rows.allSatisfy { $0["provider"] as? String == "codex" && $0["note_updated_hours_ago"] as? Int == 0 })
        XCTAssertEqual((data["recent_transitions"] as? [[String: Any]])?.count, 56)
        let hint = try XCTUnwrap(data["last_known_interaction"] as? [String: Any])
        XCTAssertEqual(hint["evidence"] as? String, "observedSelection")
        XCTAssertNotNil(hint["interaction_hours_ago"])
        XCTAssertFalse(String(decoding: body, as: UTF8.self).contains("thr_fixture"))
        print("Extreme Unicode Decisions payload: \(body.count) bytes, 8 candidates, 56 transition pairs retained")
    }
    func testOptionalNotesAreShortenedBeforeNormalLabels() throws {
        let (baseline, catalog, notes) = fixture(label: "Keep this useful label")
        let input = RankingInput(baseline: baseline, catalog: catalog, insights: notes, now: now)
        let body = try input.body(now: now)
        XCTAssertLessThanOrEqual(body.count, DecisionsTrialLedger.maximumRequestBytes)
        let rows = try XCTUnwrap(try payload(body)["candidates"] as? [[String: Any]])
        XCTAssertEqual(rows.compactMap { $0["label"] as? String }, baseline.map(\.title))
        let retained = rows.compactMap { $0["approved_short_note"] as? String }
        XCTAssertFalse(retained.isEmpty)
        XCTAssertTrue(retained.allSatisfy { !$0.isEmpty && $0.count < 180 })
    }
    func testEscapedControlsAndSingleHugeGraphemeStillFit() throws {
        for label in [String(repeating: "\u{0001}\"\\", count: 80), "x" + String(repeating: "\u{0301}", count: 10_000)] {
            let (baseline, catalog, notes) = fixture(label: label)
            let body = try RankingInput(baseline: baseline, catalog: catalog, insights: notes, now: now).body(now: now)
            XCTAssertLessThanOrEqual(body.count, DecisionsTrialLedger.maximumRequestBytes)
            let rows = try XCTUnwrap(try payload(body)["candidates"] as? [[String: Any]])
            XCTAssertTrue(rows.allSatisfy { ($0["label"] as? String)?.isEmpty == false })
        }
    }
    func testLiteralIDRedactionHandlesOverlapsAndRegexMetacharacters() throws {
        let baseline = [Destination(title: "Inspect opaque-prefix-tail and opaque.+(secret)", threadID: "opaque-prefix"),
                        Destination(title: "Other", threadID: "opaque-prefix-tail", provider: .claude)]
        var context = ContextMemory()
        context.record(ContextEvent(key: ConversationKey(provider: .claude, id: "opaque.+(secret)"),
            topic: "Inspect opaque-prefix-tail and opaque.+(secret)", kind: .selectedConversation,
            observedAt: now, source: "fixture", evidence: .observedSelection), now: now)
        let input = RankingInput(baseline: baseline, context: context, now: now)
        XCTAssertEqual(input.candidates[0].label, "Inspect [id] and [id]")
        let body = String(decoding: try input.body(now: now), as: UTF8.self)
        XCTAssertFalse(body.contains("opaque")); XCTAssertFalse(body.contains("secret")); XCTAssertFalse(body.contains("-tail"))
    }
    func testOnlyUniqueChosenWinnerPromotesAndTailStaysStable() throws {
        let input = RankingInput(baseline: (0..<4).map { Destination(title: "Chat \($0)", threadID: "thr_fixture_\($0)") })
        XCTAssertEqual(try input.order(response: response([0.1, 0.2, 0.5, 0.15, 0.05], choice: "c2")),
                       ["codex:thr_fixture_2", "codex:thr_fixture_0", "codex:thr_fixture_1", "codex:thr_fixture_3"])
        for (scores, choice) in [([0.5, 0.2, 0.1, 0.15, 0.05], "c0"),
                                ([0.1, 0.3, 0.3, 0.2, 0.1], "c1"),
                                ([0.1, 0.2, 0.5, 0.15, 0.05], "c1"),
                                ([0.1, 0.2, 0.1, 0.1, 0.5], "none")] {
            XCTAssertNil(try input.order(response: response(scores, choice: choice)))
        }
        var pipeline = RankingPipeline()
        let job = try XCTUnwrap(pipeline.begin(input, now: 0))
        pipeline.finish(job, response: .success(try response([0.5, 0.2, 0.1, 0.15, 0.05], choice: "c0")), now: 0.1)
        XCTAssertEqual(pipeline.metrics.valid, 1)
        XCTAssertNil(pipeline.begin(input, now: 1), "a valid no-op must not spend another request")
    }
    func testRetainedHintIdentityRemainsRedactedAfterAuditEviction() throws {
        let privateID = "opaque-private-context"
        var context = ContextMemory()
        context.record(ContextEvent(key: ConversationKey(provider: .claude, id: privateID),
            topic: "Review \(privateID) for database contention", kind: .selectedConversation,
            observedAt: now.addingTimeInterval(-1), source: "fixture", evidence: .observedSelection), now: now)
        for index in 0..<80 {
            context.record(ContextEvent(key: ConversationKey(provider: .codex, id: "thr_background_fixture"),
                kind: .turnCompleted, observedAt: now, source: "fixture-\(index)", evidence: .lifecycle), now: now)
        }
        XCTAssertFalse(context.events.contains { $0.key.id == privateID })
        XCTAssertEqual(context.currentHint(at: now)?.key.id, privateID)
        let input = RankingInput(baseline: [Destination(title: "Database", threadID: "thr_public_fixture")], context: context, now: now)
        let body = String(decoding: try input.body(now: now), as: UTF8.self)
        XCTAssertFalse(body.contains(privateID))
        XCTAssertTrue(body.contains("database contention"))
    }
    func testValidatedCompletionRejectsLateAndWrongProviderOrders() throws {
        let baseline = [Destination(title: "Codex", threadID: "shared_fixture"),
                        Destination(title: "Claude", threadID: "shared_fixture", provider: .claude)]
        let input = RankingInput(baseline: baseline)
        var pipeline = RankingPipeline()
        let job = try XCTUnwrap(pipeline.begin(input, now: 0))
        pipeline.finishValidated(job, response: .success(["claude:shared_fixture", "codex:shared_fixture"]), now: 0.76)
        XCTAssertEqual(pipeline.metrics.late, 1)
        XCTAssertEqual(pipeline.snapshot(baseline: baseline, input: input, now: 1), baseline)
        var invalid = RankingPipeline()
        let next = try XCTUnwrap(invalid.begin(input, now: 0))
        invalid.finishValidated(next, response: .success(["claude:shared_fixture", "claude:shared_fixture"]), now: 0.1)
        XCTAssertEqual(invalid.metrics.failed, 1)
        XCTAssertEqual(invalid.snapshot(baseline: baseline, input: input, now: 0.2), baseline)
    }
    func testThousandIDInputAndBodyBenchmark() throws {
        let baseline = (0..<1000).map { Destination(title: "Chat \($0)", threadID: "opaque_fixture_\($0)") }
        var catalog = CatalogCache(); catalog.folders = ["/fixture/project"]
        catalog.entries = baseline.map { CatalogEntry(id: $0.threadID, title: $0.title, folder: catalog.folders[0], updatedAt: now) }
        let notes = catalog.entries.prefix(8).map { ThreadInsight(id: $0.id, folder: $0.folder, updatedAt: now,
            topic: "Review transaction contention with \($0.id) and opaque_fixture_999 in /private/project.") }
        var samples: [Double] = [], bytes = 0
        for _ in 0..<30 {
            let start = ProcessInfo.processInfo.systemUptime
            let input = RankingInput(baseline: baseline, catalog: catalog, insights: notes, now: now)
            let body = try input.body(now: now); bytes = body.count
            samples.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            XCTAssertEqual(input.candidates.count, 8)
            XCTAssertFalse(String(decoding: body, as: UTF8.self).contains("opaque_fixture"))
        }
        samples.sort()
        XCTAssertLessThanOrEqual(bytes, DecisionsTrialLedger.maximumRequestBytes)
        print(String(format: "Decisions input + bounded body / 1000 IDs / 30 samples: median %.3f ms, p95 %.3f ms; %d bytes; background-only", samples[15], samples[28], bytes))
    }
    func testPreparedPromotionPreservesPinsAndThousandRowTail() throws {
        let pins = (0..<2).map { Destination(title: "Pin \($0)", threadID: "thr_pin_\($0)", pinned: true) }
        let chats = (0..<1000).map { Destination(title: "Chat \($0)", threadID: "thr_ready_\($0)") }
        let baseline = pins + chats
        let input = RankingInput(baseline: baseline)
        var pipeline = RankingPipeline()
        let job = try XCTUnwrap(pipeline.begin(input, now: 0))
        let result = try input.order(response: response(Array(repeating: 0.02, count: 7) + [0.8, 0.06], choice: "c7"))
        pipeline.finishValidated(job, response: .success(result), now: 0.1)
        let ranked = pipeline.snapshot(baseline: baseline, input: input, now: 0.2)
        XCTAssertEqual(ranked.count, 1002)
        XCTAssertEqual(ranked.first, chats[7])
        XCTAssertEqual(Array(ranked.dropFirst().prefix(2)), pins)
        XCTAssertEqual(Array(ranked.dropFirst(3).prefix(7)), Array(chats.prefix(7)))
        XCTAssertEqual(Array(ranked.dropFirst(10)), Array(chats.dropFirst(8)))
        XCTAssertEqual(Set(ranked.map(\.conversationKey)).count, ranked.count)
    }
}
