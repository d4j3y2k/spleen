import Foundation

/// Native status controls for the exact Code route currently displayed in Claude.
/// This is not an engine-ID join or a catalog of other sidebar sessions.
public struct ClaudeDesktopStatus: Equatable {
    public static let source = "claude-desktop-status"
    public let observation: ClaudeDesktopObservation
    public let activity: RuntimeActivity?
    public let isUnread: Bool?
    public let lastReply: ClaudeReplyTime?

    public init?(observation: ClaudeDesktopObservation, matchingSidebarRows: [String], sidebarComplete: Bool,
                 currentRowConfirmed: Bool, workControls: ClaudeDesktopWorkControls? = nil, lastReply: ClaudeReplyTime? = nil) {
        guard observation.surface == .code else { return nil }
        self.observation = observation
        self.lastReply = workControls?.responseStops == 0 ? lastReply : nil
        // Only corroborate the displayed route with its unique, exact sidebar
        // label. Never associate other remembered sessions by title. Duplicate,
        // missing, truncated or unfamiliar rows leave read state unknown.
        var rowActivity: RuntimeActivity?
        var unread: Bool?
        if sidebarComplete, currentRowConfirmed, !observation.title.isEmpty, matchingSidebarRows.count == 1 {
            let text = matchingSidebarRows[0]
            let title = observation.title
            switch text {
            case title: unread = false
            case title + " Running": rowActivity = .working; unread = false
            case title + " Unread response": unread = true
            case title + " Running Unread response", title + " Unread response Running":
                rowActivity = .working; unread = true
            default: break
            }
        }
        // Absence of Running clears our spinner; it does not claim that the task
        // is complete, idle, or waiting for a human.
        activity = workControls?.isWorking == true ? .working : rowActivity
        isUnread = unread
        guard activity != nil || isUnread != nil || self.lastReply != nil else { return nil }
    }

    public func sample(at now: Date, sequence: UInt64, epoch: String) -> LiveSessionState {
        LiveSessionState(key: observation.key, source: Self.source, epoch: epoch,
                         observedAt: now, lifetime: 8, sequence: sequence,
                         activity: activity, isUnread: isUnread)
    }
}
