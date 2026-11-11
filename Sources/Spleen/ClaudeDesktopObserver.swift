import AppKit
import ApplicationServices
import SpleenCore

/// Opt-in AX metadata only. Spleen needs its own Accessibility permission; the
/// Codex computer-use host's permission does not grant this process access.
/// Code engine hook IDs cannot be substituted for observed Desktop Code IDs.
final class ClaudeDesktopObserver {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Opt-in, in-memory counters only. Never contains app/session identifiers or text.
    struct Diagnostics: Encodable {
        var enabled = false
        var startRequests = 0
        var workspaceEvents = 0
        var foregroundChecks = 0
        var foregroundClaudeFound = 0
        var attachmentAttempts = 0
        var attachmentSuccesses = 0
        var attachmentFailures = 0
        var registrationSuccesses = 0
        var registrationFailures = 0
        var rawAXNotifications = 0
        var staleAXNotifications = 0
        var metadataReadAttempts = 0
        var staleReadDrops = 0
        var foregroundReadRejections = 0
        var focusedWindowMissing = 0
        var webAreasFound = 0
        var metadataParsed = 0
        var acceptedDeliveries = 0
        var dwellCommits = 0
        var dwellAbandonments = 0
        var foregroundDeliveryRejections = 0
        var staleOrDuplicateDeliveryRejections = 0
        var permissionFailures = 0
        var axAttributeFailures = 0
        var scanLimitReached = 0
    }

    private let queue = DispatchQueue(label: "spleen.claude-observation", qos: .utility)
    private let queueKey = DispatchSpecificKey<Bool>()
    /// Fired as soon as a supported route is accepted in front, before the visit dwell.
    /// Placement only: the receiver must not record it as a visit.
    private let onForeground: ((ClaudeDesktopObservation) -> Void)?
    private let onObservation: (ClaudeDesktopObservation) -> Void
    private let diagnosticsEnabled: Bool
    private var statistics: Diagnostics
    private var started = false
    private var recoveryTimer: DispatchSourceTimer?
    private var workspaceTokens: [NSObjectProtocol] = []
    private var callbackID: UInt?
    private var observer: AXObserver?
    private var application: AXUIElement?
    private var processID: pid_t?
    private var registeredNotifications: [CFString] = []
    private let gate = ClaudeDesktopObservationGate()
    /// Attaching can fail while Claude is still launching. Retry with a backoff rather
    /// than stopping observation until Settings is saved again.
    private var attachFailures = 0
    private var attachFailurePID: pid_t?
    private var nextAttachAttempt: TimeInterval = 0
    static let bundleID = "com.anthropic.claudefordesktop"

    /// Fired when Claude is in front showing a page that is not a conversation, such as
    /// a new chat. Placement only: the conversation just left becomes a return target.
    private let onLeftConversation: (() -> Void)?

    init(diagnosticsEnabled: Bool = false, onForeground: ((ClaudeDesktopObservation) -> Void)? = nil,
         onLeftConversation: (() -> Void)? = nil, onObservation: @escaping (ClaudeDesktopObservation) -> Void) {
        self.onForeground = onForeground
        self.onLeftConversation = onLeftConversation
        self.onObservation = onObservation
        self.diagnosticsEnabled = diagnosticsEnabled
        statistics = Diagnostics(enabled: diagnosticsEnabled)
        queue.setSpecific(key: queueKey, value: true)
    }

    /// Call after stop() for a settled probe summary. Contains no additional AX reads.
    func diagnosticsSnapshot() -> Diagnostics {
        if DispatchQueue.getSpecific(key: queueKey) == true { return statistics }
        return queue.sync { statistics }
    }

    private func count(_ counter: WritableKeyPath<Diagnostics, Int>) {
        guard diagnosticsEnabled else { return }
        if DispatchQueue.getSpecific(key: queueKey) == true { statistics[keyPath: counter] += 1 }
        else { queue.async { [weak self] in self?.statistics[keyPath: counter] += 1 } }
    }

    /// True means armed. If Claude is inactive/absent, attachment waits for activation.
    /// Only an explicit user action should pass promptForPermission: true.
    @discardableResult
    func start(promptForPermission: Bool = false) -> Bool {
        count(\.startRequests)
        let trusted = promptForPermission
            ? AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            : Self.isTrusted
        guard trusted else { count(\.permissionFailures); stop(); return false }
        queue.async { [weak self] in
            guard let self else { return }
            if self.started {
                let supported = self.reconcile()
                if !supported { self.stopOnQueue() }
                return
            }
            self.started = true
            // Some Electron route changes emit no focus notification. A bounded,
            // foreground-only metadata sample closes that gap without reading text.
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 0.5, repeating: 0.5, leeway: .milliseconds(100))
            timer.setEventHandler { [weak self] in
                guard let self, self.started else { return }
                if self.reconcile() { self.scheduleRead() }
                else { self.stopOnQueue() }
            }
            self.recoveryTimer = timer; timer.resume()
            let center = NSWorkspace.shared.notificationCenter
            for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
                self.workspaceTokens.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] notification in
                    if notification.name == NSWorkspace.didTerminateApplicationNotification {
                        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                              app.bundleIdentifier == Self.bundleID else { return }
                    }
                    self?.workspaceChanged()
                })
            }
            let supported = self.reconcile()
            if !supported { self.stopOnQueue() }
        }
        return true
    }

    func stop() {
        // Invalidate before waiting for the utility queue or an in-flight AX request.
        gate.invalidate()
        if DispatchQueue.getSpecific(key: queueKey) == true { stopOnQueue() }
        else { queue.sync { stopOnQueue() } }
    }

    private func stopOnQueue() {
        started = false
        recoveryTimer?.cancel(); recoveryTimer = nil
        for token in workspaceTokens { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        workspaceTokens.removeAll()
        detach()
        attachFailures = 0; attachFailurePID = nil; nextAttachAttempt = 0
    }

    private func attachFailed() -> Bool {
        count(\.attachmentFailures)
        attachFailures += 1
        nextAttachAttempt = ProcessInfo.processInfo.systemUptime + min(30, 0.5 * pow(2, Double(attachFailures - 1)))
        return true // Stay armed; the recovery timer retries after the backoff.
    }

    deinit { stop() }

    private func workspaceChanged() {
        count(\.workspaceEvents)
        // Capture the transition even if A→B→A finishes before reconcile can run.
        gate.invalidate()
        queue.async { [weak self] in
            guard let self, self.started else { return }
            self.detach()
            if !self.reconcile() { self.stopOnQueue() }
        }
    }

    fileprivate func notified(callbackID: UInt) {
        queue.async { [weak self] in
            guard let self else { return }
            self.count(\.rawAXNotifications)
            guard self.callbackID == callbackID else { self.count(\.staleAXNotifications); return }
            self.scheduleRead()
        }
    }

    private func reconcile() -> Bool {
        guard started else { return false }
        guard Self.isTrusted else { count(\.permissionFailures); detach(); return false }
        count(\.foregroundChecks)
        guard let active = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first(where: { $0.isActive }) else {
            detach()
            return true
        }
        count(\.foregroundClaudeFound)
        if processID == active.processIdentifier { return true }
        detach()
        if attachFailurePID != active.processIdentifier {
            attachFailurePID = active.processIdentifier; attachFailures = 0; nextAttachAttempt = 0
        }
        guard ProcessInfo.processInfo.systemUptime >= nextAttachAttempt else { return true }
        count(\.attachmentAttempts)
        let element = AXUIElementCreateApplication(active.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.1)
        var created: AXObserver?
        let callback: AXObserverCallback = { _, _, _, context in
            guard let context else { return }
            let callbackID = UInt(bitPattern: context)
            ClaudeObservationCallbacks.lookup(callbackID)?.notified(callbackID: callbackID)
        }
        guard AXObserverCreate(active.processIdentifier, callback, &created) == .success,
              let created else { return attachFailed() }
        observer = created
        application = element
        processID = active.processIdentifier
        // Never reuse an attachment's refcon, including for the same process ID.
        let callbackID = ClaudeObservationCallbacks.register(self)
        self.callbackID = callbackID
        for name in [kAXFocusedUIElementChangedNotification, kAXFocusedWindowChangedNotification, kAXWindowCreatedNotification] {
            let notification = name as CFString
            if AXObserverAddNotification(created, element, notification, UnsafeMutableRawPointer(bitPattern: callbackID)) == .success {
                registeredNotifications.append(notification)
                count(\.registrationSuccesses)
            } else { count(\.registrationFailures) }
        }
        guard !registeredNotifications.isEmpty else { detach(); return attachFailed() }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
        attachFailures = 0; nextAttachAttempt = 0
        count(\.attachmentSuccesses)
        scheduleRead()
        return true
    }

    private func detach() {
        gate.invalidate()
        if let callbackID { ClaudeObservationCallbacks.remove(callbackID) }
        callbackID = nil
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            if let application {
                for name in registeredNotifications { AXObserverRemoveNotification(observer, application, name) }
            }
        }
        registeredNotifications.removeAll()
        observer = nil; application = nil; processID = nil
    }

    private func scheduleRead() {
        guard started, observer != nil, let ticket = gate.requestRead() else { return }
        // First-edge coalescing: frequent focus events cannot defer this deadline.
        queue.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self, self.gate.beginRead(ticket) else { return }
            self.readFocusedMetadata(ticket: ticket)
        }
    }

    private func readFocusedMetadata(ticket: ClaudeDesktopObservationGate.Ticket) {
        count(\.metadataReadAttempts)
        guard started else { return }
        guard Self.isTrusted else { count(\.permissionFailures); stopOnQueue(); return }
        guard gate.isCurrent(ticket), let pid = processID, let application else { count(\.staleReadDrops); return }
        guard let running = NSRunningApplication(processIdentifier: pid), running.isActive,
              running.bundleIdentifier == Self.bundleID else { count(\.foregroundReadRejections); return }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.35
        defer {
            if ProcessInfo.processInfo.systemUptime >= deadline { count(\.scanLimitReached) }
        }
        guard let rawWindow = value(application, kAXFocusedWindowAttribute, ticket: ticket, deadline: deadline),
              CFGetTypeID(rawWindow) == AXUIElementGetTypeID() else { count(\.focusedWindowMissing); return }
        let window = rawWindow as! AXUIElement
        var nodes: [(AXUIElement, Int)] = [(window, 0)]
        var index = 0
        // A known non-conversation page, with nothing left unread, means no conversation is
        // in front. Anything unreadable or unfamiliar stays unknown.
        var sawOtherPage = false, incomplete = false
        while index < nodes.count, index < 80, mayRead(ticket, before: deadline) {
            let (node, depth) = nodes[index]; index += 1
            guard let role = value(node, kAXRoleAttribute, ticket: ticket, deadline: deadline) as? String else { incomplete = true; continue }
            if role == "AXWebArea" { count(\.webAreasFound) }
            if role == "AXWebArea", let raw = value(node, kAXURLAttribute, ticket: ticket, deadline: deadline) {
                let url = (raw as? URL)?.absoluteString ?? (raw as? String)
                if let url, ClaudeDesktopObservation.isOtherClaudePage(url: url) { sawOtherPage = true }
                let title = value(node, kAXTitleAttribute, ticket: ticket, deadline: deadline) as? String ?? ""
                if let url, let observation = ClaudeDesktopObservation(url: url, title: title), mayRead(ticket, before: deadline) {
                    count(\.metadataParsed)
                    let gate = self.gate
                    let callback = onObservation, fronted = onForeground
                    DispatchQueue.main.async { [weak self] in
                        guard Self.isTrusted else {
                            self?.count(\.permissionFailures)
                            gate.invalidate()
                            self?.queue.async { [weak self] in self?.stopOnQueue() }
                            return
                        }
                        guard let app = NSRunningApplication(processIdentifier: pid),
                              app.isActive, app.bundleIdentifier == Self.bundleID else { self?.count(\.foregroundDeliveryRejections); return }
                        guard gate.acceptDelivery(observation, for: ticket) else { self?.count(\.staleOrDuplicateDeliveryRejections); return }
                        self?.count(\.acceptedDeliveries)
                        fronted?(observation)
                        // A chat passed through on the way to another one is not a visit.
                        // Record only if the same route is still in front after the dwell.
                        DispatchQueue.main.asyncAfter(deadline: .now() + ClaudeDesktopObservationGate.minimumDwell) { [weak self] in
                            guard Self.isTrusted, let app = NSRunningApplication(processIdentifier: pid),
                                  app.isActive, app.bundleIdentifier == Self.bundleID,
                                  let settled = gate.commitDwell(observation, for: ticket) else { self?.count(\.dwellAbandonments); return }
                            self?.count(\.dwellCommits)
                            callback(settled)
                        }
                    }
                    return
                }
            }
            // A web area is the leaf of our scan, even on an unknown route. Never
            // descend through conversation DOM looking for another matching URL.
            guard role != "AXWebArea", depth < ClaudeDesktopObservation.webAreaSearchDepth, nodes.count < 80,
                  prepareRead(node, ticket: ticket, deadline: deadline) else { continue }
            var children: CFArray?
            // Copy only the bounded prefix. Never fetch message value/text or scroll.
            let result = AXUIElementCopyAttributeValues(node, kAXChildrenAttribute as CFString, 0, 80 - nodes.count, &children)
            if result != .success { count(\.axAttributeFailures); incomplete = true }
            if result == .success,
               mayRead(ticket, before: deadline), let children = children as? [AXUIElement] {
                nodes.append(contentsOf: children.map { ($0, depth + 1) })
            }
        }
        if index >= 80 { count(\.scanLimitReached) }
        if sawOtherPage, !incomplete, index >= nodes.count, nodes.count < 80, mayRead(ticket, before: deadline) {
            let gate = self.gate, left = onLeftConversation
            DispatchQueue.main.async {
                guard Self.isTrusted, let app = NSRunningApplication(processIdentifier: pid), app.isActive,
                      app.bundleIdentifier == Self.bundleID, gate.clearDelivery(for: ticket) else { return }
                left?()
            }
        }
    }

    private func mayRead(_ ticket: ClaudeDesktopObservationGate.Ticket, before deadline: TimeInterval) -> Bool {
        gate.isCurrent(ticket) && ProcessInfo.processInfo.systemUptime < deadline
    }

    private func prepareRead(_ element: AXUIElement, ticket: ClaudeDesktopObservationGate.Ticket, deadline: TimeInterval) -> Bool {
        guard mayRead(ticket, before: deadline) else { return false }
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { return false }
        AXUIElementSetMessagingTimeout(element, Float(min(0.1, remaining)))
        return true
    }

    private func value(_ element: AXUIElement, _ attribute: String,
                       ticket: ClaudeDesktopObservationGate.Ticket, deadline: TimeInterval) -> CFTypeRef? {
        guard prepareRead(element, ticket: ticket, deadline: deadline) else { return nil }
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else {
            count(\.axAttributeFailures)
            return nil
        }
        guard mayRead(ticket, before: deadline) else { return nil }
        return result
    }
}

/// Opaque callback IDs avoid dereferencing a freed refcon after stop/re-attachment.
private enum ClaudeObservationCallbacks {
    private final class WeakOwner {
        weak var value: ClaudeDesktopObserver?
        init(_ value: ClaudeDesktopObserver) { self.value = value }
    }
    private static let lock = NSLock()
    private static var next: UInt = 1
    private static var owners: [UInt: WeakOwner] = [:]
    static func register(_ owner: ClaudeDesktopObserver) -> UInt {
        lock.lock(); defer { lock.unlock() }
        let id = next; next += 1; owners[id] = WeakOwner(owner); return id
    }
    static func lookup(_ id: UInt) -> ClaudeDesktopObserver? {
        lock.lock(); defer { lock.unlock() }; return owners[id]?.value
    }
    static func remove(_ id: UInt) { lock.lock(); defer { lock.unlock() }; owners.removeValue(forKey: id) }
}

