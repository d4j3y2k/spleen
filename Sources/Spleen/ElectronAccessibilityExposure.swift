import AppKit
import ApplicationServices
import SpleenCore

/// Called on the owning observer’s serial queue. Electron can expose a native
/// window before making its conversation web area available to accessibility.
final class ElectronAccessibilityExposure {
    private let bundleID: String
    private let attribute = "AXManualAccessibility" as CFString
    private var lastApp: NSRunningApplication?
    private var retry = AccessibilityExposureRetry()
    private var enabledByObserver: [pid_t: NSRunningApplication] = [:]

    init(bundleID: String) { self.bundleID = bundleID }

    /// Nil means no request was due. Keep the retry state across focus changes.
    func request(for app: NSRunningApplication) -> AXError? {
        guard app.bundleIdentifier == bundleID, app.isActive, AXIsProcessTrusted() else { return nil }
        if lastApp != app {
            lastApp = app
            retry = AccessibilityExposureRetry()
        }
        let now = ProcessInfo.processInfo.systemUptime
        guard retry.shouldAttempt(at: now) else { return nil }
        let pid = app.processIdentifier
        let target = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(target, 0.5)
        var current: CFTypeRef?
        let wasOff = AXUIElementCopyAttributeValue(target, attribute, &current) == .success &&
            current.map { CFGetTypeID($0) == CFBooleanGetTypeID() && !CFBooleanGetValue(($0 as! CFBoolean)) } == true
        let result = AXUIElementSetAttributeValue(target, attribute, kCFBooleanTrue)
        if result == .success && wasOff { enabledByObserver[pid] = app }
        switch result {
        case .success: retry.record(.succeeded, at: now)
        case .cannotComplete, .failure: retry.record(.transientFailure, at: now)
        default: retry.record(.unsupported, at: now)
        }
        return result
    }

    func restore() {
        for (pid, app) in enabledByObserver where !app.isTerminated {
            let target = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(target, 0.5)
            _ = AXUIElementSetAttributeValue(target, attribute, kCFBooleanFalse)
        }
        enabledByObserver.removeAll()
        lastApp = nil
        retry = AccessibilityExposureRetry()
    }
}
