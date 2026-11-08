import Foundation
import XCTest
@testable import SpleenCore

final class ContextRepositoryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000)

    private func withRepository(_ body: (ContextRepository) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(ContextRepository(url: directory.appendingPathComponent("context.json")))
    }

    private func event(_ id: String) -> ContextEvent {
        ContextEvent(key: ConversationKey(provider: .codex, id: id), project: "/workspace",
                     kind: .sessionStarted, observedAt: now, source: "test", evidence: .lifecycle)
    }

    func testMissingRoundTripBoundsAndRecentsControls() throws {
        try withRepository { repository in
            XCTAssertTrue(try repository.load().events.isEmpty)
            for index in 0..<70 { try repository.record(event("thread_\(index)"), now: now) }
            XCTAssertEqual(try repository.load().events.count, ContextMemory.maximumEvents)
            XCTAssertLessThanOrEqual(try Data(contentsOf: repository.url).count, ContextRepository.maximumFileBytes)
            XCTAssertFalse(try repository.setRecentsEnabled(false).recentsEnabled)
            XCTAssertTrue(try repository.record(event("disabled"), now: now).events.isEmpty)
            try repository.setRecentsEnabled(true)
            try repository.record(event("enabled"), now: now)
            XCTAssertEqual(try repository.load().events.map(\.key.id), ["enabled"])
            XCTAssertTrue(try repository.setRecentsEnabled(true, clear: true).events.isEmpty)
        }
    }

    func testCorruptAndOversizedFilesArePreservedByAllMutations() throws {
        try withRepository { repository in
            _ = try repository.load()
            for data in [Data("{broken".utf8), Data(repeating: 32, count: ContextRepository.maximumFileBytes + 1)] {
                try data.write(to: repository.url)
                XCTAssertThrowsError(try repository.load())
                XCTAssertThrowsError(try repository.record(event("ignored"), now: now))
                XCTAssertThrowsError(try repository.setRecentsEnabled(false, clear: true))
                XCTAssertEqual(try Data(contentsOf: repository.url), data)
            }
        }
    }

    func testConcurrentIndependentRepositoryWritersDoNotLoseEvents() throws {
        try withRepository { repository in
            let lock = NSLock()
            var failures: [Error] = []
            DispatchQueue.concurrentPerform(iterations: 24) { index in
                do {
                    try ContextRepository(url: repository.url).record(event("thread_\(index)"), now: now)
                } catch {
                    lock.lock(); failures.append(error); lock.unlock()
                }
            }
            XCTAssertTrue(failures.isEmpty)
            XCTAssertEqual(Set(try repository.load().events.map(\.key.id)), Set((0..<24).map { "thread_\($0)" }))
        }
    }

    func testHookDecoderKeepsOnlyMetadataAndNeverClaimsAttention() throws {
        for (name, kind) in [("SessionStart", ContextEventKind.sessionStarted),
                             ("UserPromptSubmit", .userPromptSubmitted), ("Stop", .turnCompleted)] {
            let data = try JSONSerialization.data(withJSONObject: [
                "session_id": "thr_example123", "cwd": "/workspace", "hook_event_name": name,
                "prompt": "PRIVATE_PROMPT", "transcript_path": "/PRIVATE_TRANSCRIPT", "last_assistant_message": "PRIVATE_REPLY"
            ])
            let decoded = try XCTUnwrap(ContextHookDecoder.codexEvent(data: data, now: now))
            XCTAssertEqual(decoded.key, ConversationKey(provider: .codex, id: "thr_example123"))
            XCTAssertEqual(decoded.project, "/workspace")
            XCTAssertEqual(decoded.kind, kind)
            XCTAssertEqual(decoded.observedAt, now)
            XCTAssertEqual(decoded.evidence, .lifecycle)
            XCTAssertFalse(decoded.contributesInteraction)
            let encoded = String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self)
            XCTAssertFalse(encoded.contains("PRIVATE"))
            var memory = ContextMemory()
            memory.record(decoded, now: now)
            XCTAssertNil(memory.currentHint(at: now))
            XCTAssertNil(memory.latestObservedSelection(at: now))
        }
    }

    func testHookDecoderRejectsInvalidInputs() throws {
        let valid: [String: Any] = ["session_id": "thr_example123", "cwd": "/workspace", "hook_event_name": "Stop"]
        for (key, value) in [("session_id", "new"), ("session_id", "codex://threads/thr_example123"),
                             ("session_id", "../unsafe"), ("session_id", " thr_example123"),
                             ("cwd", "relative"), ("cwd", "/bad\npath"),
                             ("cwd", "/" + String(repeating: "x", count: 4096)),
                             ("hook_event_name", "SubagentStop"), ("hook_event_name", "selectedConversation")] {
            var object = valid; object[key] = value
            XCTAssertNil(ContextHookDecoder.codexEvent(data: try JSONSerialization.data(withJSONObject: object), now: now))
        }
        for key in valid.keys {
            var object = valid; object.removeValue(forKey: key)
            XCTAssertNil(ContextHookDecoder.codexEvent(data: try JSONSerialization.data(withJSONObject: object), now: now))
            object = valid; object[key] = 123
            XCTAssertNil(ContextHookDecoder.codexEvent(data: try JSONSerialization.data(withJSONObject: object), now: now))
        }
        XCTAssertNil(ContextHookDecoder.codexEvent(data: Data("[]".utf8), now: now))
        XCTAssertNil(ContextHookDecoder.codexEvent(data: Data("{broken".utf8), now: now))
        XCTAssertNil(ContextHookDecoder.codexEvent(data: Data(repeating: 32, count: ContextHookDecoder.maximumInputBytes + 1), now: now))
    }
}
