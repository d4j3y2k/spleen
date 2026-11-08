import Foundation

/// Status chrome only. A named message/composer/other content subtree is opaque.
/// The caller anchors this scan to the exact, revalidated open Code route.
public struct ClaudeDesktopWorkControls: Equatable {
    public struct Metadata {
        public let role: String
        public let label: String
        public init(role: String, label: String) { self.role = role; self.label = label }
    }
    public var responseStops = 0
    public var backgroundTaskStops = 0
    public var isWorking: Bool { responseStops > 0 || backgroundTaskStops > 0 }
    public init() {}

    public static func read<Node>(in root: Node, metadata: (Node) -> Metadata,
                                  children: (Node) -> [Node], enabled: (Node) -> Bool) -> Self {
        var result = Self()
        func walk(_ node: Node, depth: Int, background: Bool, details: Bool) {
            guard depth < 32 else { return }
            for child in children(node) {
                let info = metadata(child)
                if info.role == "AXButton" {
                    if !background && !details && info.label == "Stop" && enabled(child) { result.responseStops += 1 }
                    if background && info.label == "Stop this task" && enabled(child) { result.backgroundTaskStops += 1 }
                    continue
                }
                guard ["AXGroup", "AXSplitGroup", "AXScrollArea", "AXUnknown"].contains(info.role) else { continue }
                // Background tasks is a status/control region of the current
                // session. Do not enter Chat messages or any other named content.
                guard info.label.isEmpty || info.label == "Background tasks" || info.label == "Session details" else { continue }
                walk(child, depth: depth + 1, background: background || info.label == "Background tasks",
                     details: details || info.label == "Session details")
            }
        }
        walk(root, depth: 0, background: false, details: false)
        return result
    }
}
