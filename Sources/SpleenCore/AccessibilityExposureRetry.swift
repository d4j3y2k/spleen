import Foundation

/// Bounded startup recovery; successful and unsupported requests are terminal.
/// Keep this state for a process across foreground/background transitions.
public struct AccessibilityExposureRetry {
    public enum Outcome { case succeeded, transientFailure, unsupported }
    public private(set) var attempts = 0
    public private(set) var nextAttempt: TimeInterval = 0
    public private(set) var finished = false
    public init() {}
    public func shouldAttempt(at uptime: TimeInterval) -> Bool {
        !finished && attempts < 4 && uptime >= nextAttempt
    }
    public mutating func record(_ outcome: Outcome, at uptime: TimeInterval) {
        guard shouldAttempt(at: uptime) else { return }
        attempts += 1
        switch outcome {
        case .succeeded, .unsupported: finished = true
        case .transientFailure:
            if attempts == 4 { finished = true }
            else { nextAttempt = uptime + [0.5, 1.0, 2.0][attempts - 1] }
        }
    }
}
