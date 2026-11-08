import XCTest
@testable import SpleenCore

final class DotTests: XCTestCase {
    func testPreservesCloudHostWithoutChangingLocalThreadLinks() throws {
        let link = "codex://threads/thr_dot_fixture?hostId=durable"
        XCTAssertEqual(try DotTarget(" \(link)\n").url.absoluteString, link)
        XCTAssertEqual(try DotTarget("codex://threads/thr_dot_fixture").url.absoluteString, "codex://threads/thr_dot_fixture")
        XCTAssertThrowsError(try ThreadTarget(link))
    }

    func testRejectsOtherRoutesAndAdditionalParameters() {
        for link in ["", "https://example.com", "codex://threads/new?hostId=durable",
                     "codex://settings?hostId=durable", "codex://threads/thr_dot_fixture?prompt=hello",
                     "codex://threads/thr_dot_fixture?hostId=durable&prompt=hello",
                     "codex://threads/thr_dot_fixture?hostId=durable&hostId=local",
                     "codex://threads/thr_dot_fixture?hostId=", "codex://threads/thr_dot_fixture?",
                     "codex://threads/thr_dot_fixture?hostId=../other", "codex://threads/thr_dot_fixture#fragment",
                     "codex://user@threads/thr_dot_fixture?hostId=durable"] {
            XCTAssertThrowsError(try DotTarget(link), link)
        }
    }

    func testOptionalSettingSurvivesRoundTripAndLoadsOlderStores() throws {
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        var state = SavedState()
        let oldData = try encoder.encode(state)
        XCTAssertNil(try decoder.decode(SavedState.self, from: oldData).dotLink)
        state.dotLink = "codex://threads/thr_dot_fixture?hostId=durable"
        try state.validate()
        XCTAssertEqual(try decoder.decode(SavedState.self, from: encoder.encode(state)), state)
        state.dotLink = "codex://threads/new"
        XCTAssertThrowsError(try state.validate())
    }
}
