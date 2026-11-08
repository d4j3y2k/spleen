import XCTest
@testable import SpleenCore

final class CodexSidebarSelectionTests: XCTestCase {
    private let url = "app://-/local/12345678-1234-1234-1234-123456789abc"
    private struct Node {
        var info: CodexSidebarSelection.Metadata
        var children: [Int] = []
    }
    private func scan(_ nodes: [Node], limit: Int = 160, depth: Int = 12,
                      visited: ((Int) -> Void)? = nil) -> CodexDesktopObservation? {
        CodexSidebarSelection.read(navigation: 0, maximumNodes: limit, maximumDepth: depth,
            metadata: { visited?($0); return nodes[$0].info },
            children: { id, budget in nodes[id].children.count <= budget ? nodes[id].children : nil })
    }
    private var nav: CodexSidebarSelection.Metadata { .init(role: "AXGroup", subrole: "AXLandmarkNavigation") }
    func testExactCurrentLocalLink() {
        let nodes = [Node(info: nav, children: [1]), Node(info: .init(role: "AXLink", current: "page", url: url, title: "A"))]
        XCTAssertEqual(scan(nodes)?.id, "12345678-1234-1234-1234-123456789abc")
        XCTAssertNil(scan(nodes, limit: 1))
        XCTAssertNil(scan(nodes, depth: 0))
    }
    func testRejectsMissingMarkerRemoteAndAmbiguity() {
        for current in [nil, "true", "false", "step"] as [String?] {
            XCTAssertNil(scan([Node(info: nav, children: [1]), Node(info: .init(role: "AXLink", current: current, url: url))]))
        }
        XCTAssertNil(scan([Node(info: nav, children: [1]), Node(info: .init(role: "AXLink", current: "page", url: url + "?hostId=remote"))]))
        let link = Node(info: CodexSidebarSelection.Metadata(role: "AXLink", current: "page", url: url))
        XCTAssertNil(scan([Node(info: nav, children: [1,2]), link, link]))
    }
    func testDoesNotDescendIntoMainTextInputsOrLinkLabels() {
        for info in [CodexSidebarSelection.Metadata(role: "AXGroup", subrole: "AXLandmarkMain"),
                     .init(role: "AXTextArea"), .init(role: "AXStaticText"), .init(role: "AXLink")] {
            var visited: [Int] = []
            let nodes = [Node(info: nav, children: [1]), Node(info: info, children: [2]),
                         Node(info: .init(role: "AXLink", current: "page", url: url))]
            XCTAssertNil(scan(nodes, visited: { visited.append($0) }))
            XCTAssertFalse(visited.contains(2))
        }
    }
    func testRequiresNavigationBoundaryAndCompleteReads() {
        XCTAssertNil(scan([Node(info: .init(role: "AXGroup"))]))
        let result: CodexDesktopObservation? = CodexSidebarSelection.read(navigation: 0,
            metadata: { _ in self.nav }, children: { _, _ in nil })
        XCTAssertNil(result)
    }
}
