import AppKit
import ApplicationServices
import SpleenCore

/// Opt-in, bounded reads of Claude's native status chrome, including in background.
/// Never opens a session, scrolls, marks it read, or reads message bodies.
final class ClaudeDesktopStatusObserver {
    private let queue = DispatchQueue(label: "spleen.claude-status", qos: .utility)
    private let gate = ClaudeDesktopObservationGate()
    private var timer: DispatchSourceTimer?
    private let onSample: (LiveSessionState?) -> Void
    private let onReply: ((ConversationKey, ClaudeReplyTime) -> Void)?
    private let diagnostics: ((String) -> Void)?
    private let epoch = UUID().uuidString
    private var sequence: UInt64 = 0
    private static let bundleID = "com.anthropic.claudefordesktop"

    init(diagnostics: ((String) -> Void)? = nil, onReply: ((ConversationKey, ClaudeReplyTime) -> Void)? = nil,
         onSample: @escaping (LiveSessionState?) -> Void) {
        self.diagnostics = diagnostics; self.onReply = onReply; self.onSample = onSample
    }

    func start() {
        stop()
        guard AXIsProcessTrusted() else { return }
        guard let ticket = gate.requestRead(), gate.beginRead(ticket) else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 2, leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in self?.poll(ticket: ticket) }
        self.timer = timer
        timer.resume()
    }

    func stop() { gate.invalidate(); timer?.cancel(); timer = nil }
    deinit { stop() }

    private func poll(ticket: ClaudeDesktopObservationGate.Ticket) {
        guard gate.isCurrent(ticket) else { return }
        let pid = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first?.processIdentifier
        let read = AXIsProcessTrusted() ? pid.flatMap { ClaudeStatusAXReader(pid: $0, diagnostics: diagnostics).read() } : nil
        sequence += 1
        let sample = read?.sample(at: Date(), sequence: sequence, epoch: epoch)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.gate.isCurrent(ticket) else { return }
            guard AXIsProcessTrusted(), let pid,
                  NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == Self.bundleID else {
                self.onSample(nil); return
            }
            self.onSample(sample)
            if let read, let reply = read.lastReply { self.onReply?(read.observation.key, reply) }
        }
    }
}

/// A small structural adapter for the live-tested Code UI. Unknown layouts fail
/// closed. Reads route/title metadata, the current sidebar label, and enabled work
/// controls outside the transcript, plus the latest assistant footer's reply age.
/// Message bodies and older message controls remain opaque.
private final class ClaudeStatusAXReader {
    private let application: AXUIElement
    private let deadline = ProcessInfo.processInfo.systemUptime + 0.6
    private var nodeCount = 0
    private var complete = true
    private let maximumNodes = 480
    private let diagnostics: ((String) -> Void)?
    private struct ElementKey: Hashable {
        let element: AXUIElement
        static func == (a: Self, b: Self) -> Bool { CFEqual(a.element, b.element) }
        func hash(into hasher: inout Hasher) { hasher.combine(CFHash(element)) }
    }
    private var headers: [ElementKey: (role: String, label: String)] = [:]
    private var childCache: [ElementKey: [AXUIElement]] = [:]

    init(pid: pid_t, diagnostics: ((String) -> Void)?) {
        application = AXUIElementCreateApplication(pid); self.diagnostics = diagnostics
    }

    func read() -> ClaudeDesktopStatus? {
        var stage = "window"
        defer { diagnostics?("Claude AX status scan: stage=\(stage), nodes=\(nodeCount), complete=\(complete), budgetExceeded=\(ProcessInfo.processInfo.systemUptime >= deadline).") }
        guard let rawWindow = value(application, kAXFocusedWindowAttribute),
              CFGetTypeID(rawWindow) == AXUIElementGetTypeID() else { return nil }
        let window = rawWindow as! AXUIElement
        stage = "web-area"
        let webAreas = find(in: window, depth: 8, stopAtWebArea: true) { role, _ in role == "AXWebArea" }
        let supported = webAreas.compactMap { node -> (AXUIElement, ClaudeDesktopObservation)? in
            observation(node).map { (node, $0) }
        }
        guard complete, supported.count == 1, let (webArea, before) = supported.first,
              before.surface == .code else { return nil }
        stage = "regions"
        let regions = find(in: webArea, depth: 8) { _, label in label == "Sidebar" || label == "Primary pane" }
        guard complete else { return nil }
        var matchingRows: [String] = []
        let sidebars = regions.filter { label($0) == "Sidebar" }
        var sidebarComplete = sidebars.count == 1
        var currentRowConfirmed = false
        for region in sidebars {
                stage = "sidebar"
                let buttons = find(in: region, depth: 14, requireFullDepth: true) { role, label in
                    role == "AXButton" && label == before.title
                }
                for button in buttons {
                    let current = value(button, "AXARIACurrent")
                    let allowedCurrent = ["true", "false", "page", "step", "location", "date", "time"]
                    diagnostics?("Claude current-row marker: \(allowedCurrent.contains(current as? String ?? "") ? (current as! String) : "absent-or-unknown").")
                    currentRowConfirmed = buttons.count == 1 && ((current as? Bool) == true ||
                        (current as? String) == "page" || (current as? String) == "true")
                    // A matching button's own text must be the complete label;
                    // an empty/unrecognized child still counts toward ambiguity.
                    let texts = find(in: button, depth: 6, requireFullDepth: true) { role, _ in role == "AXStaticText" }
                    let values = texts.compactMap { value($0, kAXValueAttribute) as? String }
                    matchingRows.append(values.joined(separator: " "))
                }
                sidebarComplete = sidebarComplete && complete
        }
        let primaryPanes = regions.filter { label($0) == "Primary pane" }
        var workControls: ClaudeDesktopWorkControls?
        var lastReply: ClaudeReplyTime?
        if primaryPanes.count == 1 {
            workControls = ClaudeDesktopWorkControls.read(in: primaryPanes[0], metadata: { node in
                let info = self.header(node)
                return .init(role: info.role, label: info.label)
            }, children: { self.children($0) }, enabled: { self.value($0, kAXEnabledAttribute) as? Bool == true })
            diagnostics?("Claude work controls: response=\(workControls?.responseStops ?? 0), backgroundTasks=\(workControls?.backgroundTaskStops ?? 0).")
            if workControls?.responseStops == 0 {
                let messages = find(in: primaryPanes[0], depth: 32) { _, label in label == "Chat messages" }
                diagnostics?("Claude reply region: matches=\(messages.count), role=\(messages.first.map { self.role($0) } ?? "none").")
                if messages.count == 1 {
                    lastReply = ClaudeDesktopReplyMetadata.read(in: messages[0], at: Date(), metadata: { node in
                        let info = self.header(node)
                        return .init(role: info.role, label: info.label)
                    }, children: { self.children($0) }, text: { self.value($0, kAXValueAttribute) as? String }, diagnostics: diagnostics)
                }
            }
            diagnostics?("Claude reply metadata: available=\(lastReply != nil).")
        }
        // Reject navigation/rename races and incomplete scans. The URL, never a
        // title search across stored destinations, supplies the sample's identity.
        guard complete, observation(webArea) == before else { return nil }
        stage = "parsed-regions-\(regions.count)-rows-\(matchingRows.count)-current-\(currentRowConfirmed)"
        return ClaudeDesktopStatus(observation: before, matchingSidebarRows: matchingRows,
                                   sidebarComplete: sidebarComplete, currentRowConfirmed: currentRowConfirmed,
                                   workControls: workControls, lastReply: lastReply)
    }

    private func observation(_ element: AXUIElement) -> ClaudeDesktopObservation? {
        guard let raw = value(element, kAXURLAttribute) else { return nil }
        let url = (raw as? URL)?.absoluteString ?? (raw as? String)
        guard let url else { return nil }
        return ClaudeDesktopObservation(url: url, title: value(element, kAXTitleAttribute) as? String ?? "")
    }

    private func find(in element: AXUIElement, depth: Int, stopAtWebArea: Bool = false, requireFullDepth: Bool = false,
                      matches: (String, String) -> Bool) -> [AXUIElement] {
        guard depth > 0 else {
            if requireFullDepth { complete = false; diagnostics?("Claude AX sidebar depth limit reached.") }
            return []
        }
        var result: [AXUIElement] = []
        for child in children(element) {
            let childRole = role(child)
            // Text content is not inspected to navigate the tree.
            let childLabel = childRole == "AXStaticText" ? "" : label(child)
            if matches(childRole, childLabel) { result.append(child); continue }
            if stopAtWebArea && childRole == "AXWebArea" { continue }
            guard isContainer(childRole), stopAtWebArea || childLabel.isEmpty else { continue }
            result += find(in: child, depth: depth - 1, stopAtWebArea: stopAtWebArea, requireFullDepth: requireFullDepth, matches: matches)
        }
        return result
    }

    private func isContainer(_ role: String) -> Bool { ["AXGroup", "AXSplitGroup", "AXScrollArea", "AXUnknown"].contains(role) }
    private func role(_ element: AXUIElement) -> String { header(element).role }
    private func label(_ element: AXUIElement) -> String { header(element).label }
    private func header(_ element: AXUIElement) -> (role: String, label: String) {
        let key = ElementKey(element: element)
        if let cached = headers[key] { return cached }
        // Structural traversal needs only the role of text nodes. Read their
        // value only when explicitly inside the verified footer or sidebar row.
        if let role = value(element, kAXRoleAttribute) as? String, role == "AXStaticText" {
            headers[key] = (role, ""); return (role, "")
        }
        guard prepare(element) else { return ("", "") }
        var raw: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element,
            [kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute] as CFArray,
            AXCopyMultipleAttributeOptions(rawValue: 0), &raw) == .success,
              let values = raw as? [Any], values.count == 3 else { complete = false; return ("", "") }
        let title = values[1] as? String ?? ""
        let result = (role: values[0] as? String ?? "", label: title.isEmpty ? (values[2] as? String ?? "") : title)
        headers[key] = result
        return result
    }
    private func prepare(_ element: AXUIElement) -> Bool {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard complete, remaining > 0 else { complete = false; return false }
        AXUIElementSetMessagingTimeout(element, Float(min(0.08, remaining)))
        return true
    }
    private func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        guard prepare(element) else { return nil }
        var result: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &result)
        if error != .success && error != .attributeUnsupported && error != .noValue {
            complete = false; diagnostics?("Claude AX attribute failed: \(attribute), error=\(error.rawValue).")
        }
        return error == .success ? result : nil
    }
    private func children(_ element: AXUIElement) -> [AXUIElement] {
        let key = ElementKey(element: element)
        if let cached = childCache[key] { return cached }
        guard prepare(element) else { return [] }
        var count: CFIndex = 0
        let countResult = AXUIElementGetAttributeValueCount(element, kAXChildrenAttribute as CFString, &count)
        guard countResult == .success, nodeCount + count <= maximumNodes else {
            complete = false; diagnostics?("Claude AX children unavailable: error=\(countResult.rawValue), limit=\(nodeCount + count > maximumNodes).")
            return []
        }
        guard count > 0 else { return [] }
        var result: CFArray?
        guard AXUIElementCopyAttributeValues(element, kAXChildrenAttribute as CFString, 0, count, &result) == .success,
              let nodes = result as? [AXUIElement] else { complete = false; return [] }
        nodeCount += nodes.count
        childCache[key] = nodes
        return nodes
    }
}
