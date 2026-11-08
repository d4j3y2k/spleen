import XCTest
@testable import SpleenCore

final class TurnTimingTests: XCTestCase {
    private let entry = CatalogEntry(id: "thr_timing_fixture", title: "Work", folder: "/fixture", updatedAt: Date(timeIntervalSince1970: 1_700_000_800))

    func testCompletionTimeIsSeparateFromAStartedOrFailedTurn() throws {
        let data = Data(#"{"data":[{"status":"inProgress","startedAt":1700000700,"completedAt":1700000750,"items":[]},{"status":"failed","startedAt":1700000500,"completedAt":1700000600,"items":[]},{"status":"completed","startedAt":1700000300,"completedAt":1700000400,"items":[]}]}"#.utf8)
        let note = try InsightDecoder.page(data, entry: entry)
        XCTAssertEqual(note.timing?.lastStartedAt, Date(timeIntervalSince1970: 1_700_000_700))
        XCTAssertEqual(note.timing?.lastCompletedAt, Date(timeIntervalSince1970: 1_700_000_400))
        XCTAssertNotEqual(note.timing?.lastCompletedAt, entry.updatedAt, "Catalog activity is not a completion timestamp")
    }

    func testMissingAndInvalidTimingStaysUnknown() throws {
        let legacy = try InsightDecoder.page(Data(#"{"data":[{"items":[]}]}"#.utf8), entry: entry)
        XCTAssertNotNil(legacy.timing, "A checked provider result needs no repeated legacy backfill")
        XCTAssertNil(legacy.timing?.lastCompletedAt)
        XCTAssertNil(legacy.timing?.lastReplyLabel(at: Date()))
        let bad = Data(#"{"data":[{"status":"completed","startedAt":1700000500,"completedAt":1700000400,"items":[]},{"status":"completed","startedAt":999999999998,"completedAt":999999999999,"items":[]},{"status":"interrupted","startedAt":1700000300,"completedAt":1700000350,"items":[]}]}"#.utf8)
        XCTAssertNil(try InsightDecoder.page(bad, entry: entry).timing?.lastCompletedAt)
    }

    func testLegacyNotesDecodeAndTimingRoundTrips() throws {
        let legacy = ThreadInsight(id: entry.id, folder: entry.folder, updatedAt: entry.updatedAt, topic: "Older cached excerpt")
        let decoded = try JSONDecoder().decode(ThreadInsight.self, from: JSONEncoder().encode(legacy))
        XCTAssertNil(decoded.timing)
        let note = try InsightDecoder.page(Data(#"{"data":[{"status":"completed","startedAt":1700000300,"completedAt":1700000400,"items":[]}]}"#.utf8), entry: entry)
        XCTAssertEqual(try JSONDecoder().decode(ThreadInsight.self, from: JSONEncoder().encode(note)), note)
    }

    func testRelativeCompletionLabelsUseTheirOwnTimestamp() {
        let finished = Date(timeIntervalSince1970: 1_700_000_000)
        let timing = TurnTiming(lastCompletedAt: finished, checkedAt: finished.addingTimeInterval(300))
        XCTAssertEqual(timing.lastReplyLabel(at: finished.addingTimeInterval(30)), "Last reply just now")
        XCTAssertEqual(timing.lastReplyLabel(at: finished.addingTimeInterval(120)), "Last reply 2m ago")
        XCTAssertEqual(timing.lastReplyLabel(at: finished.addingTimeInterval(7200)), "Last reply 2h ago")
        XCTAssertEqual(timing.lastReplyLabel(at: finished.addingTimeInterval(172800)), "Last reply 2d ago")
        XCTAssertNil(timing.lastReplyLabel(at: finished.addingTimeInterval(-1)))
    }

    func testVisitAndSelectionLabelsPreserveTheirMeaning() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let selection = ConversationPreview(lastVisitedAt: now.addingTimeInterval(-7200), lastSelectedAt: now.addingTimeInterval(-120))
        XCTAssertEqual(selection.timestamp(at: now)?.kind, .selection)
        XCTAssertEqual(selection.timestamp(at: now)?.label(at: now), "Last selected 2m ago")
        XCTAssertTrue(selection.timestamp(at: now)?.help.hasPrefix("Last selected through Spleen:") == true)
        let visit = ConversationPreview(lastVisitedAt: now.addingTimeInterval(-60), lastSelectedAt: now.addingTimeInterval(-120))
        XCTAssertEqual(visit.timestamp(at: now)?.kind, .visit)
        XCTAssertEqual(visit.timestamp(at: now)?.label(at: now), "Last visited 1m ago")
        XCTAssertNil(ConversationPreview(lastSelectedAt: now.addingTimeInterval(60)).timestamp(at: now))
        XCTAssertNil(ConversationPreview().timestamp(at: now))
    }

    func testReplyAndNavigationRemainIndependentlyAvailable() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let preview = ConversationPreview(
            timing: TurnTiming(lastCompletedAt: now.addingTimeInterval(-7200), checkedAt: now),
            lastVisitedAt: now.addingTimeInterval(-60), lastSelectedAt: now.addingTimeInterval(-120))
        XCTAssertEqual(preview.replyTimestamp(at: now)?.label(at: now), "Last reply 2h ago")
        XCTAssertEqual(preview.interactionTimestamp(at: now)?.label(at: now), "Last visited 1m ago")
        let unknown = ConversationPreview(
            timing: TurnTiming(lastCompletedAt: now.addingTimeInterval(60), checkedAt: now),
            lastSelectedAt: now.addingTimeInterval(-120))
        XCTAssertNil(unknown.replyTimestamp(at: now), "Future or missing completion is not replaced by selection")
        XCTAssertEqual(unknown.interactionTimestamp(at: now)?.kind, .selection)
    }
}
