import XCTest
@testable import SpleenCore

final class CodexReadStateTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let unread = ConversationKey(provider: .codex, id: "thr_unread_fixture")
    let read = ConversationKey(provider: .codex, id: "thr_read_fixture")

    func fixture(unreadIDs: [String] = ["thr_unread_fixture"], version: Int = 1,
                 identities: [String: [String: [String]]]? = nil,
                 extra: String = "ignored app text") throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "electron-thread-read-state-v1": ["version": version,
                "unreadByIdentity": identities ?? ["account-fingerprint": ["local:host-fingerprint": unreadIDs]],
                "legacyMigration": ["unreadThreadIdsByHostId": ["local": [read.id]]]],
            "unrelated-app-state": extra
        ])
    }
    func decode(_ data: Data, keys: [ConversationKey]? = nil, sequence: UInt64 = 1) throws -> CodexDesktopReadSnapshot {
        try CodexDesktopReadStateClient.decode(data, keys: keys ?? [unread, read], observedAt: now,
                                               sequence: sequence, epoch: "test-process")
    }

    func testExplicitLocalUnreadSetAndAbsenceAreSeparateFromRuntimeAndCompletion() throws {
        let snapshot = try decode(fixture())
        XCTAssertEqual(snapshot.states.map(\.isUnread), [true, false])
        XCTAssertTrue(snapshot.states.allSatisfy {
            $0.activity == nil && $0.completion == nil && $0.activityObservedAt == nil &&
            $0.completionObservedAt == nil && $0.unreadObservedAt == now &&
            $0.source == "desktop-persisted-read-state" && $0.host == "local"
        })
        XCTAssertTrue(snapshot.contentFingerprint.hasPrefix("desktop-read-v1:"))
    }

    func testReadUnreadTransitionsUseOnlyCurrentLocalSet() throws {
        let first = try decode(fixture())
        let second = try decode(fixture(unreadIDs: []), sequence: 2)
        let third = try decode(fixture(unreadIDs: [read.id]), sequence: 3)
        XCTAssertEqual(first.states.map(\.isUnread), [true, false])
        XCTAssertEqual(second.states.map(\.isUnread), [false, false])
        XCTAssertEqual(third.states.map(\.isUnread), [false, true])
        XCTAssertEqual(third.states.map(\.sequence), [3, 3])
        XCTAssertNotEqual(first.contentFingerprint, second.contentFingerprint)
        XCTAssertNotEqual(second.contentFingerprint, third.contentFingerprint)
    }

    func testRemoteStateAndLegacyMigrationNeverLeakIntoLocalState() throws {
        let data = try fixture(identities: ["identity": ["local:host": [],
            "remote-control:remote-host": [read.id], "durable:cloud-host": [unread.id]]])
        XCTAssertEqual(try decode(data).states.map(\.isUnread), [false, false])
    }

    func testFingerprintIgnoresUnrelatedTextAndUnreadOrder() throws {
        let a = try decode(fixture(unreadIDs: [unread.id, read.id], extra: "one"))
        let b = try decode(fixture(unreadIDs: [read.id, unread.id], extra: "two"))
        XCTAssertEqual(a.contentFingerprint, b.contentFingerprint)
    }

    func testMissingUnknownMalformedAndAmbiguousStateFailsInsteadOfMarkingRead() throws {
        let inputs: [Data] = [Data("{}".utf8), Data("not json".utf8), try fixture(version: 2),
            try fixture(identities: [:]),
            try fixture(identities: ["one": ["local:host": []], "two": ["local:host": []]]),
            try fixture(identities: ["one": ["local:first": [], "local:second": []]]),
            try fixture(identities: ["one": ["remote-control:host": []]]),
            try fixture(identities: ["one": ["local:": []]]),
            try fixture(unreadIDs: [unread.id, unread.id]), try fixture(unreadIDs: ["invalid/path"])]
        for input in inputs { XCTAssertThrowsError(try decode(input)) }
    }

    func testForeignDuplicateInvalidAndExcessiveRequestedKeysRejected() throws {
        let data = try fixture()
        for keys in [[ConversationKey(provider: .claude, id: unread.id)], [read, read],
                     [ConversationKey(provider: .codex, id: "invalid/path")],
                     (0..<65).map { ConversationKey(provider: .codex, id: "thr_fixture_\($0)") }] {
            XCTAssertThrowsError(try decode(data, keys: keys))
        }
        XCTAssertThrowsError(try decode(Data(repeating: 32, count: CodexDesktopReadStateClient.maximumBytes + 1)))
    }

    func testFileReadDoesNotRewriteStateAndFailureIsUnknown() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("state.json"), bytes = try fixture()
        try bytes.write(to: url)
        let client = CodexDesktopReadStateClient(stateURL: url)
        let sample = try client.read(keys: [unread, read], observedAt: now, sequence: 4, epoch: "file-reader")
        XCTAssertEqual(sample.states.map(\.isUnread), [true, false])
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        try FileManager.default.removeItem(at: url)
        XCTAssertThrowsError(try client.read(keys: [read], sequence: 5, epoch: "file-reader"))
    }
}
