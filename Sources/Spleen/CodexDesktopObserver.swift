import AppKit
import ApplicationServices
import SpleenCore

/// Opt-in AX metadata only. Spleen needs its own Accessibility permission; the
/// Codex computer-use host's permission does not grant this process access.
/// Reads route identity only. Unknown hosts/routes and absent AX URLs fail closed.
final class CodexDesktopObserver {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Opt-in, in-memory counters only. Never contains app/session identifiers or text.
    struct Diagnostics: Encodable {
        var enabled = false
        var startRequests = 0
        var workspaceEvents = 0
        var foregroundChecks = 0
        var foregroundCodexFound = 0
        var attachmentAttempts = 0
        var attachmentSuccesses = 0
        var accessibilityExposureRequests = 0
        var accessibilityExposureSuccesses = 0
        var accessibilityExposureErrors: [String: Int] = [:]
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
        var roles: [String: Int] = [:]
        var metadataAttributes: [String: Int] = [:]
        var routeKinds: [String: Int] = [:]
    }

    private let queue = DispatchQueue(label: "spleen.codex-observation", qos: .utility)
    private let queueKey = DispatchSpecificKey<Bool>()
    /// Fired as soon as a supported route is accepted in front, before the visit dwell.
    /// Placement only: the receiver must not record it as a visit.
    private let onForeground: ((CodexDesktopObservation) -> Void)?
    private let onObservation: (CodexDesktopObservation) -> Void
    private let diagnosticsEnabled: Bool
    private var statistics: Diagnostics
    private var started = false
    private var recoveryTimer: DispatchSourceTimer?
    private var workspaceTokens: [NSObjectProtocol] = []
    private var callbackID: UInt?
    private var observer: AXObserver?
    private var application: AXUIElement?
    private var processID: pid_t?
    private var exposureProcessID: pid_t?
    private var exposureRetry = AccessibilityExposureRetry()
    private var registeredNotifications: [CFString] = []
    private let gate = CodexDesktopObservationGate()
    static let bundleID = "com.openai.codex"

    init(diagnosticsEnabled: Bool = false, onForeground: ((CodexDesktopObservation) -> Void)? = nil,
         onObservation: @escaping (CodexDesktopObservation) -> Void) {
        self.onForeground = onForeground
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

    /// True means armed. If Codex is inactive/absent, attachment waits for activation.
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
        count(\.foregroundCodexFound)
        if processID == active.processIdentifier {
            requestAccessibilityExposure(pid: active.processIdentifier)
            return true
        }
        detach()
        count(\.attachmentAttempts)
        let element = AXUIElementCreateApplication(active.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.1)
        requestAccessibilityExposure(pid: active.processIdentifier)
        var created: AXObserver?
        let callback: AXObserverCallback = { _, _, _, context in
            guard let context else { return }
            let callbackID = UInt(bitPattern: context)
            CodexObservationCallbacks.lookup(callbackID)?.notified(callbackID: callbackID)
        }
        guard AXObserverCreate(active.processIdentifier, callback, &created) == .success,
              let created else { count(\.attachmentFailures); return false }
        observer = created
        application = element
        processID = active.processIdentifier
        // Never reuse an attachment's refcon, including for the same process ID.
        let callbackID = CodexObservationCallbacks.register(self)
        self.callbackID = callbackID
        for name in [kAXFocusedUIElementChangedNotification, kAXFocusedWindowChangedNotification, kAXWindowCreatedNotification] {
            let notification = name as CFString
            if AXObserverAddNotification(created, element, notification, UnsafeMutableRawPointer(bitPattern: callbackID)) == .success {
                registeredNotifications.append(notification)
                count(\.registrationSuccesses)
            } else { count(\.registrationFailures) }
        }
        guard !registeredNotifications.isEmpty else { count(\.attachmentFailures); detach(); return false }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
        count(\.attachmentSuccesses)
        scheduleRead()
        return true
    }

    /// Utility queue only. No input, navigation, permission prompt or remote call.
    /// Retry only communication/initialization failures, never unsupported attributes.
    private func requestAccessibilityExposure(pid: pid_t) {
        guard started, Self.isTrusted,
              NSRunningApplication(processIdentifier: pid)?.isActive == true else { return }
        if exposureProcessID != pid {
            exposureProcessID = pid
            exposureRetry = AccessibilityExposureRetry()
        }
        let now = ProcessInfo.processInfo.systemUptime
        guard exposureRetry.shouldAttempt(at: now) else { return }
        let target = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(target, 0.5)
        count(\.accessibilityExposureRequests)
        let result = AXUIElementSetAttributeValue(target, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        if result == .success { count(\.accessibilityExposureSuccesses) }
        else if diagnosticsEnabled { statistics.accessibilityExposureErrors[String(result.rawValue), default: 0] += 1 }
        let outcome: AccessibilityExposureRetry.Outcome
        switch result {
        case .success: outcome = .succeeded
        case .cannotComplete, .failure: outcome = .transientFailure
        default: outcome = .unsupported
        }
        exposureRetry.record(outcome, at: now)
    }

    private func detach() {
        gate.invalidate()
        if let callbackID { CodexObservationCallbacks.remove(callbackID) }
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

    private func readFocusedMetadata(ticket: CodexDesktopObservationGate.Ticket) {
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
        if let observation = CodexSidebarMetadataReader.read(focusedWindow: window, deadline: deadline,
            isCurrent: { self.gate.isCurrent(ticket) && Self.isTrusted }) {
            count(\.metadataParsed)
            deliver(observation, pid: pid, ticket: ticket)
            return
        }
        var nodes: [(AXUIElement, Int)] = [(window, 0)]
        var index = 0
        while index < nodes.count, index < 80, mayRead(ticket, before: deadline) {
            let (node, depth) = nodes[index]; index += 1
            guard let role = value(node, kAXRoleAttribute, ticket: ticket, deadline: deadline) as? String else { continue }
            if diagnosticsEnabled {
                statistics.roles[role, default: 0] += 1
                var names: CFArray?
                if AXUIElementCopyAttributeNames(node, &names) == .success, let values = names as? [String] {
                    for name in values where ["AXURL", "AXDocument", "AXChildren", "AXContents", "AXVisibleChildren", "AXSubrole", "AXARIACurrent"].contains(name) {
                        statistics.metadataAttributes[name, default: 0] += 1
                        if name == "AXURL" || name == "AXDocument", let raw = value(node, name, ticket: ticket, deadline: deadline) {
                            let url = (raw as? URL)?.absoluteString ?? (raw as? String) ?? ""
                            let category = CodexDesktopObservation(url: url, title: "") != nil ? "exact-local" : (url.isEmpty ? "empty" : (url.hasPrefix("app:") ? "other-app-route" : "other-scheme"))
                            statistics.routeKinds[role + ":" + name + ":" + category, default: 0] += 1
                        }
                    }
                }
            }
            if role == "AXWebArea" { count(\.webAreasFound) }
            if role == "AXWebArea", let raw = value(node, kAXURLAttribute, ticket: ticket, deadline: deadline) {
                let url = (raw as? URL)?.absoluteString ?? (raw as? String)
                let title = value(node, kAXTitleAttribute, ticket: ticket, deadline: deadline) as? String ?? ""
                if let url, let observation = CodexDesktopObservation(url: url, title: title), mayRead(ticket, before: deadline) {
                    count(\.metadataParsed)
                    deliver(observation, pid: pid, ticket: ticket)
                    return
                }
            }
            // A web area is the leaf of our scan, even on an unknown route. Never
            // descend through conversation DOM looking for another matching URL.
            guard role != "AXWebArea", depth < 8, nodes.count < 80,
                  prepareRead(node, ticket: ticket, deadline: deadline) else { continue }
            var children: CFArray?
            // Copy only the bounded prefix. Never fetch message value/text or scroll.
            let result = AXUIElementCopyAttributeValues(node, kAXChildrenAttribute as CFString, 0, 80 - nodes.count, &children)
            if result != .success { count(\.axAttributeFailures) }
            if result == .success,
               mayRead(ticket, before: deadline), let children = children as? [AXUIElement] {
                nodes.append(contentsOf: children.map { ($0, depth + 1) })
            }
        }
        if index >= 80 { count(\.scanLimitReached) }
    }

    private func deliver(_ observation: CodexDesktopObservation, pid: pid_t, ticket: CodexDesktopObservationGate.Ticket) {
        let gate = self.gate, callback = onObservation, fronted = onForeground
        DispatchQueue.main.async { [weak self] in
            guard Self.isTrusted else {
                self?.count(\.permissionFailures); gate.invalidate()
                self?.queue.async { [weak self] in self?.stopOnQueue() }
                return
            }
            guard let app = NSRunningApplication(processIdentifier: pid), app.isActive,
                  app.bundleIdentifier == Self.bundleID else { self?.count(\.foregroundDeliveryRejections); return }
            guard gate.acceptDelivery(observation, for: ticket) else { self?.count(\.staleOrDuplicateDeliveryRejections); return }
            self?.count(\.acceptedDeliveries)
            fronted?(observation)
            // A thread passed through on the way to another one is not a visit.
            // Record only if the same route is still in front after the dwell.
            DispatchQueue.main.asyncAfter(deadline: .now() + CodexDesktopObservationGate.minimumDwell) { [weak self] in
                guard Self.isTrusted, let app = NSRunningApplication(processIdentifier: pid),
                      app.isActive, app.bundleIdentifier == Self.bundleID,
                      let settled = gate.commitDwell(observation, for: ticket) else { self?.count(\.dwellAbandonments); return }
                self?.count(\.dwellCommits)
                callback(settled)
            }
        }
    }

    private func mayRead(_ ticket: CodexDesktopObservationGate.Ticket, before deadline: TimeInterval) -> Bool {
        gate.isCurrent(ticket) && ProcessInfo.processInfo.systemUptime < deadline
    }

    private func prepareRead(_ element: AXUIElement, ticket: CodexDesktopObservationGate.Ticket, deadline: TimeInterval) -> Bool {
        guard mayRead(ticket, before: deadline) else { return false }
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { return false }
        AXUIElementSetMessagingTimeout(element, Float(min(0.1, remaining)))
        return true
    }

    private func value(_ element: AXUIElement, _ attribute: String,
                       ticket: CodexDesktopObservationGate.Ticket, deadline: TimeInterval) -> CFTypeRef? {
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
private enum CodexObservationCallbacks {
    private final class WeakOwner {
        weak var value: CodexDesktopObserver?
        init(_ value: CodexDesktopObserver) { self.value = value }
    }
    private static let lock = NSLock()
    private static var next: UInt = 1
    private static var owners: [UInt: WeakOwner] = [:]
    static func register(_ owner: CodexDesktopObserver) -> UInt {
        lock.lock(); defer { lock.unlock() }
        let id = next; next += 1; owners[id] = WeakOwner(owner); return id
    }
    static func lookup(_ id: UInt) -> CodexDesktopObserver? {
        lock.lock(); defer { lock.unlock() }; return owners[id]?.value
    }
    static func remove(_ id: UInt) { lock.lock(); defer { lock.unlock() }; owners.removeValue(forKey: id) }
}

