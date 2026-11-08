import Foundation

/// Reads only the trailing, top-level assistant actions toolbar of Chat messages.
/// Older selected-message toolbars live inside Message N and remain opaque.
public enum ClaudeDesktopReplyMetadata {
    public static func read<Node>(in root: Node, at now: Date,
        metadata: (Node) -> ClaudeDesktopWorkControls.Metadata,
        children: (Node) -> [Node], text: (Node) -> String?, diagnostics: ((String) -> Void)? = nil) -> ClaudeReplyTime? {
        let rootInfo = metadata(root)
        guard rootInfo.label == "Chat messages" else { return nil }
        // Claude wraps the keyboard-navigation hint separately. The message
        // list is the final anonymous child; never search earlier branches.
        let rootRows = children(root)
        guard let wrapper = rootRows.last, metadata(wrapper).role == "AXGroup", metadata(wrapper).label.isEmpty else { return nil }
        var rows = children(wrapper)
        for _ in 0..<16 {
            guard rows.count == 1, let only = rows.first, metadata(only).role == "AXGroup", metadata(only).label.isEmpty else { break }
            rows = children(only)
        }
        diagnostics?("Claude reply structure: rows=\(rows.count), trailingRole=\(rows.last.map { metadata($0).role } ?? "none").")
        guard rows.count > 1, let trailing = rows.last else { return nil }
        var count = 0, complete = true
        func leaves(_ node: Node, depth: Int) -> [Node] {
            count += 1
            guard depth < 16, count <= 64 else { complete = false; return [] }
            let info = metadata(node)
            guard info.role == "AXGroup", info.label.isEmpty else { return [node] }
            return children(node).flatMap { leaves($0, depth: depth + 1) }
        }
        let footers = leaves(trailing, depth: 0).filter { metadata($0).role == "AXToolbar" && metadata($0).label == "Message actions" }
        guard complete, footers.count == 1 else { return nil }
        let controls = children(footers[0]).flatMap { leaves($0, depth: 0) }
        guard complete else { return nil }
        diagnostics?("Claude reply structure: controls=\(controls.count), readAloud=\(controls.contains { metadata($0).label == "Read aloud" }), texts=\(controls.filter { metadata($0).role == "AXStaticText" }.count).")
        guard controls.contains(where: { metadata($0).role == "AXButton" && metadata($0).label == "Read aloud" }),
              !controls.contains(where: { metadata($0).label == "Read by Claude" }) else { return nil }
        let times = controls.filter { metadata($0).role == "AXStaticText" }.compactMap { node in
            text(node).flatMap { ClaudeReplyTime(label: $0, observedAt: now) }
        }
        return times.count == 1 ? times[0] : nil
    }
}
