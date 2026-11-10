import XCTest
@testable import SpleenCore

final class SavedTitleTests: XCTestCase {
    private let threadID = "01234567-89ab-cdef-0123-456789abcdef"
    private func catalog(_ title: String) -> CatalogCache {
        var catalog = CatalogCache(); catalog.folders = ["/fixture"]
        catalog.entries = [CatalogEntry(id: threadID, title: title, folder: "/fixture", updatedAt: Date())]
        return catalog
    }

    func testChatSavedByOpeningFollowsCodexRenames() {
        var saved = catalog("First title").entries[0].destination
        saved.followsCatalogTitle = true
        var state = SavedState(); state.destinations = [saved]
        XCTAssertTrue(state.adoptCatalogTitles(from: catalog("Renamed in Codex")))
        XCTAssertEqual(state.destinations[0].title, "Renamed in Codex")
        XCTAssertFalse(state.adoptCatalogTitles(from: catalog("Renamed in Codex")), "an unchanged catalog changes nothing")
        XCTAssertFalse(state.adoptCatalogTitles(from: CatalogCache()), "a chat Codex no longer lists keeps its last title")
        XCTAssertEqual(state.destinations[0].title, "Renamed in Codex")
    }

    func testEditorLabelIsKept() throws {
        var state = SavedState()
        try state.upsert(id: nil, title: "My label", link: threadID, pinned: false)
        XCTAssertEqual(state.destinations[0].followsCatalogTitle, false)
        XCTAssertFalse(state.adoptCatalogTitles(from: catalog("Codex title")))
        XCTAssertEqual(state.destinations[0].title, "My label")
        var opened = catalog("Codex title").entries[0].destination; opened.followsCatalogTitle = true
        state.destinations = [opened]
        try state.upsert(id: opened.id, title: "Codex title", link: threadID, pinned: true)
        XCTAssertEqual(state.destinations[0].followsCatalogTitle, true, "pinning without retitling keeps following Codex")
        try state.upsert(id: opened.id, title: "Renamed by me", link: threadID, pinned: true)
        XCTAssertEqual(state.destinations[0].followsCatalogTitle, false)
        XCTAssertFalse(state.adoptCatalogTitles(from: catalog("Codex again")))
        XCTAssertEqual(state.destinations[0].title, "Renamed by me")
    }

    func testEarlierEntriesFollowOnlyWhenNothingSuggestsALabel() {
        let entry = catalog("Codex title").entries[0]
        let matching = entry.destination
        var placeholder = entry.destination; placeholder.title = "Untitled chat · 01234567"
        var diverged = entry.destination; diverged.title = "Maybe my label"
        let typed = Destination(title: "Codex title", threadID: threadID) // A random ID means it came from the editor.
        for (earlier, follows, title) in [(matching, true, "Codex title"), (placeholder, true, "Codex title"),
                                          (diverged, false, "Maybe my label"), (typed, false, "Codex title")] {
            var state = SavedState(); state.destinations = [earlier]
            XCTAssertTrue(state.adoptCatalogTitles(from: catalog("Codex title")), earlier.title)
            XCTAssertEqual(state.destinations[0].followsCatalogTitle, follows, earlier.title)
            XCTAssertEqual(state.destinations[0].title, title, earlier.title)
        }
    }

    func testClearHistoryForgetsChatsSavedOnlyByOpeningThem() {
        var opened = catalog("Opened").entries[0].destination; opened.followsCatalogTitle = true; opened.lastOpenedAt = Date()
        let pinned = Destination(title: "Pinned opened", threadID: "11111111-2222-4333-8444-555555555555", pinned: true, followsCatalogTitle: true)
        let labeled = Destination(title: "Label", threadID: "21111111-2222-4333-8444-555555555555", followsCatalogTitle: false)
        let earlier = Destination(title: "Earlier", threadID: "31111111-2222-4333-8444-555555555555")
        var state = SavedState(); state.destinations = [opened, pinned, labeled, earlier]
        state.clearRecents()
        XCTAssertEqual(state.destinations.map(\.title), ["Pinned opened", "Label", "Earlier"])
        XCTAssertTrue(state.destinations.allSatisfy { $0.lastOpenedAt == nil })
    }

    func testFlagRoundTripsAndEarlierFilesDecode() throws {
        var item = Destination(title: "Opened", threadID: threadID, followsCatalogTitle: true)
        XCTAssertEqual(try JSONDecoder().decode(Destination.self, from: JSONEncoder().encode(item)).followsCatalogTitle, true)
        item.followsCatalogTitle = nil
        let earlier = try JSONEncoder().encode(item)
        XCTAssertFalse(String(decoding: earlier, as: UTF8.self).contains("followsCatalogTitle"))
        XCTAssertNil(try JSONDecoder().decode(Destination.self, from: earlier).followsCatalogTitle)
    }
}
