import ApplicationServices
import Foundation
import SpleenCore

/// Call only with a navigation landmark from the focused Codex window.
/// The caller owns foreground/trust/generation checks before and after delivery.
enum CodexSidebarMetadataReader {
    /// Structural metadata only. Stops at main/content landmarks and at each nav.
    static func read(focusedWindow: AXUIElement, deadline: TimeInterval,
                     isCurrent: () -> Bool) -> CodexDesktopObservation? {
        var failedRead = false
        func valid(_ node: AXUIElement) -> Bool {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0, isCurrent() else { return false }
            AXUIElementSetMessagingTimeout(node, Float(min(0.05, remaining)))
            return true
        }
        func string(_ node: AXUIElement, _ key: String) -> String? {
            guard valid(node) else { return nil }
            var raw: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(node, key as CFString, &raw)
            if status != .success && status != .noValue && status != .attributeUnsupported { failedRead = true }
            guard status == .success, valid(node) else { return nil }
            return raw as? String
        }
        var queue: [(AXUIElement, Int)] = [(focusedWindow, 0)]
        var index = 0
        var landmarks: [AXUIElement] = []
        while index < queue.count {
            let (node, depth) = queue[index]; index += 1
            guard let role = string(node, "AXRole") else { return nil }
            let subrole = string(node, "AXSubrole")
            if subrole == "AXLandmarkNavigation" { landmarks.append(node); continue }
            guard subrole == nil || ["AXStandardWindow", "AXLandmarkApplication"].contains(subrole!),
                  ["AXWindow", "AXGroup", "AXSplitGroup", "AXWebArea", "AXScrollArea"].contains(role),
                  valid(node) else { continue }
            var count: CFIndex = 0
            guard AXUIElementGetAttributeValueCount(node, "AXChildren" as CFString, &count) == .success,
                  count >= 0, count <= 120 - queue.count, valid(node) else { return nil }
            if count == 0 { continue }
            guard depth < 12 else { return nil }
            var array: CFArray?
            guard AXUIElementCopyAttributeValues(node, "AXChildren" as CFString, 0, count, &array) == .success,
                  let children = array as? [AXUIElement], children.count == count, valid(node) else { return nil }
            queue.append(contentsOf: children.map { ($0, depth + 1) })
        }
        // No guessing which of multiple navigation landmarks is the chat sidebar.
        guard !failedRead, landmarks.count == 1, isCurrent() else { return nil }
        return read(navigation: landmarks[0], deadline: deadline, isCurrent: isCurrent)
    }

    static func read(navigation: AXUIElement, deadline: TimeInterval,
                     isCurrent: () -> Bool) -> CodexDesktopObservation? {
        var failedRead = false
        func valid(_ element: AXUIElement) -> Bool {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0, isCurrent() else { return false }
            AXUIElementSetMessagingTimeout(element, Float(min(0.05, remaining)))
            return true
        }
        func value(_ node: AXUIElement, _ name: String) -> CFTypeRef? {
            guard valid(node) else { return nil }
            var result: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(node, name as CFString, &result)
            if status != .success && status != .noValue && status != .attributeUnsupported { failedRead = true }
            guard status == .success, valid(node) else { return nil }
            return result
        }
        let result = CodexSidebarSelection.read(navigation: navigation, metadata: { node in
            guard let role = value(node, "AXRole") as? String else { return nil }
            let subrole = value(node, "AXSubrole") as? String
            guard role == "AXLink" else {
                return .init(role: role, subrole: subrole)
            }
            let current = value(node, "AXARIACurrent") as? String
            guard current == "page" else { return .init(role: role, subrole: subrole, current: current) }
            let raw = value(node, "AXURL")
            let url = (raw as? URL)?.absoluteString ?? (raw as? String)
            let title = value(node, "AXTitle") as? String ?? ""
            return .init(role: role, subrole: subrole, current: current, url: url, title: title)
        }, children: { node, budget in
            guard valid(node) else { return nil }
            var count: CFIndex = 0
            guard AXUIElementGetAttributeValueCount(node, "AXChildren" as CFString, &count) == .success,
                  count >= 0, count <= budget, valid(node) else { return nil }
            if count == 0 { return [] }
            var array: CFArray?
            guard AXUIElementCopyAttributeValues(node, "AXChildren" as CFString, 0, count, &array) == .success,
                  let children = array as? [AXUIElement], children.count == count, valid(node) else { return nil }
            return children
        })
        guard !failedRead, isCurrent(), ProcessInfo.processInfo.systemUptime < deadline else { return nil }
        return result
    }
}
