import XCTest
@testable import SpleenCore

final class SearchHandoffTests: XCTestCase {
    func testExactQueryRoundTripsToEitherApp() throws {
        for app in SearchHandoff.App.allCases {
            for query in ["", "  piano & synth? #1 + 50% / ", "한글 café 🎹", "line one\nline two"] {
                let request = SearchHandoff(query: query, returnPID: 123)
                let url = try XCTUnwrap(request.url(for: app))
                XCTAssertEqual(SearchHandoff(url: url, app: app), request)
                XCTAssertNil(SearchHandoff(url: url, app: app == .spleen ? .moonshine : .spleen))
            }
        }
    }
    func testRejectsMalformedAndUnrelatedRoutes() {
        for suffix in ["search?v=2&q=test", "search?v=1&q=one&q=two", "search?v=1", "search?v=1&q=test&action=run",
                       "search/path?v=1&q=test", "search?v=1&q=test#fragment", "search?v=1&q=test&returnPID=-1",
                       "search?v=1&q=test&returnPID=99999999999999", "user@search?v=1&q=test", "search?v=1&q=%00"] {
            XCTAssertNil(SearchHandoff(url: URL(string: "spleen-search://" + suffix)!, app: .spleen), suffix)
        }
    }
    func testBoundedQueryAndOptionalReturnTarget() throws {
        let request = SearchHandoff(query: String(repeating: "a", count: 8192))
        XCTAssertEqual(SearchHandoff(url: try XCTUnwrap(request.url(for: .moonshine)), app: .moonshine), request)
        XCTAssertNil(SearchHandoff(query: String(repeating: "a", count: 8193)).url(for: .moonshine))
        XCTAssertNil(SearchHandoff(query: "\0").url(for: .moonshine))
    }
}
