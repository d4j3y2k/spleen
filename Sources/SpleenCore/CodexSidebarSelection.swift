import Foundation

/// Metadata-only traversal rooted at an already identified navigation landmark.
/// Never accepts titles, selected styling, or a matching URL alone as selection.
public enum CodexSidebarSelection {
    public struct Metadata {
        public let role: String
        public let subrole: String?
        public let current: String?
        public let url: String?
        public let title: String
        public init(role: String, subrole: String? = nil, current: String? = nil,
                    url: String? = nil, title: String = "") {
            self.role = role; self.subrole = subrole; self.current = current
            self.url = url; self.title = title
        }
    }

    /// `children` must return nil if the complete child list cannot fit the budget.
    /// Callbacks may return nil on timeout, stale focus, permission loss, or AX error.
    public static func read<Node>(navigation: Node, maximumNodes: Int = 160, maximumDepth: Int = 12,
                                  metadata: (Node) -> Metadata?,
                                  children: (Node, Int) -> [Node]?) -> CodexDesktopObservation? {
        guard maximumNodes > 0, maximumDepth >= 0,
              let root = metadata(navigation), root.subrole == "AXLandmarkNavigation" else { return nil }
        var queue: [(Node, Int)] = [(navigation, 0)]
        var index = 0
        var found: CodexDesktopObservation?
        var activeCount = 0
        while index < queue.count {
            let (node, depth) = queue[index]; index += 1
            guard let info = metadata(node) else { return nil }
            if info.role == "AXLink" {
                if info.current == "page" {
                    activeCount += 1
                    guard activeCount == 1, let url = info.url,
                          let observation = CodexDesktopObservation(url: url, title: info.title) else { return nil }
                    found = observation
                }
                continue // Link labels/descendants never inspected.
            }
            // Only structural sidebar containers; never descend into message/text/input trees.
            guard ["AXGroup", "AXList", "AXRow", "AXOutline", "AXScrollArea"].contains(info.role),
                  info.subrole == nil || info.subrole == "AXLandmarkNavigation" else { continue }
            let remaining = maximumNodes - queue.count
            guard let next = children(node, remaining), next.count <= remaining else { return nil }
            if depth >= maximumDepth && !next.isEmpty { return nil }
            queue.append(contentsOf: next.map { ($0, depth + 1) })
        }
        return found
    }
}
