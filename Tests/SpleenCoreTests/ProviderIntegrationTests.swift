import XCTest
@testable import SpleenCore

final class ProviderIntegrationTests: XCTestCase {
    let identifier = "01234567-89ab-cdef-0123-456789abcdef"

    func testLegacySavedDestinationAndMixedProviderPersistence() throws {
        let legacy = Data(#"{"version":1,"destinations":[{"id":"11111111-1111-1111-1111-111111111111","title":"Saved title","threadID":"01234567-89ab-cdef-0123-456789abcdef","pinned":true}],"shortcut":{"key":"Space","control":true,"option":true,"command":false,"shift":false},"rememberRecents":true}"#.utf8)
        var state = try JSONDecoder().decode(SavedState.self, from: legacy)
        try state.validate()
        XCTAssertEqual(state.destinations[0].provider, .codex)
        XCTAssertEqual(state.destinations[0].title, "Saved title")
        try state.upsert(id: nil, title: "Claude work", link: "https://claude.ai/chat/\(identifier)", pinned: false)
        XCTAssertEqual(state.version, 2)
        XCTAssertEqual(state.destinations.count, 2)
        XCTAssertEqual(try state.destinations[0].navigationURL.absoluteString, "codex://threads/\(identifier)")
        XCTAssertEqual(try state.destinations[1].navigationURL.absoluteString, "claude://claude.ai/chat/\(identifier)")
        XCTAssertThrowsError(try state.upsert(id: nil, title: "Duplicate", link: "claude://claude.ai/chat/\(identifier)", pinned: false))
        let restored = try JSONDecoder().decode(SavedState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(restored, state)
        XCTAssertEqual(Set(restored.destinations.map(\.conversationKey)).count, 2)
    }

    func testAutomaticCatalogAcceptsProjectsWithoutFolderPickingAndHonorsExclusions() throws {
        let data = Data(#"{"data":[{"id":"thr_first_123","name":"First","cwd":"/personal/first","updatedAt":100},{"id":"thr_second_123","name":"Second","cwd":"/personal/second","updatedAt":101},{"id":"thr_work_123","name":"Work","cwd":"/excluded/client","updatedAt":102}],"nextCursor":"more"}"#.utf8)
        let policy = DiscoveryPolicy(excludedFolders: ["/excluded"], pageSize: 100, maxPages: 10)
        let page = try CatalogDecoder.page(data, policy: policy)
        XCTAssertEqual(page.entries.map(\.folder), ["/personal/first", "/personal/second"])
        XCTAssertEqual(page.nextCursor, "more")
        XCTAssertEqual(try CatalogDecoder.page(data, allowedFolders: ["/personal/first"]).entries.count, 1)
        var catalog = CatalogCache(); catalog.version = 2; catalog.policy = policy; catalog.entries = page.entries
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("catalog.json")
        try catalog.save(to: url)
        let loaded = try CatalogCache.load(from: url)
        XCTAssertEqual(loaded.effectivePolicy.scope, .automaticProjects)
        XCTAssertEqual(loaded.merged(with: SavedState()).destinations.count, 2)
    }

    func testEqualTechnicalIDDoesNotHideCodexCatalogOrLeakNotesToClaude() throws {
        let now = Date()
        var saved = SavedState()
        try saved.upsert(id: nil, title: "Claude title", link: "claude://claude.ai/chat/\(identifier)", pinned: false)
        var catalog = CatalogCache(); catalog.folders = ["/fixture"]
        catalog.entries = [CatalogEntry(id: identifier, title: "Codex title", folder: "/fixture", updatedAt: now)]
        let merged = catalog.merged(with: saved)
        XCTAssertEqual(merged.destinations.count, 2)
        let notes = [ThreadInsight(id: identifier, folder: "/fixture", updatedAt: now, topic: "UnsharedCodexEvidence")]
        let hits = RelevanceSnapshot(state: saved, catalog: catalog, insights: notes).results(query: "UnsharedCodexEvidence")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].provider, .codex)
    }

    func testLegacyCatalogDoesNotSilentlyBroadenScope() throws {
        let legacy = Data(#"{"version":1,"folders":["/fixture"],"entries":[],"hiddenIDs":[],"truncated":false}"#.utf8)
        let catalog = try JSONDecoder().decode(CatalogCache.self, from: legacy)
        XCTAssertEqual(catalog.effectivePolicy.scope, .exactFolders)
        XCTAssertTrue(catalog.includes(CatalogEntry(id: "thr_inside_123", title: "Inside", folder: "/fixture", updatedAt: Date())))
        XCTAssertFalse(catalog.includes(CatalogEntry(id: "thr_outside_123", title: "Outside", folder: "/other", updatedAt: Date())))
    }
}
