import Foundation

public enum ClaudeDesktopSurface: Equatable { case chat, code }

/// Identity observed in Claude's focused accessibility web area. Not a navigation target.
public struct ClaudeDesktopObservation: Equatable {
    public static let maximumTitleCharacters = 180
    public static let maximumTitleBytes = 720
    public let id: String
    public let title: String
    public let surface: ClaudeDesktopSurface

    public var key: ConversationKey {
        ConversationKey(provider: .claude, id: surface == .code ? "desktop-code:" + id : id)
    }

    public init?(url: String, title: String) {
        guard url.utf8.count <= 128 else { return nil }
        // AX may omit the scheme. Only this exact known host can be normalized.
        let raw = url.hasPrefix("claude.ai/") ? "https://" + url : url
        let candidate: String
        if raw.hasPrefix("https://claude.ai/chat/") {
            surface = .chat
            candidate = String(raw.dropFirst("https://claude.ai/chat/".count))
        } else if raw.hasPrefix("https://claude.ai/epitaxy/local_") {
            surface = .code
            candidate = String(raw.dropFirst("https://claude.ai/epitaxy/local_".count))
        } else { return nil }
        guard candidate.utf8.count == 36, let uuid = UUID(uuidString: candidate),
              uuid.uuidString.lowercased() == candidate.lowercased() else { return nil }
        id = (surface == .code ? "local_" : "") + uuid.uuidString.lowercased()
        let suffix = surface == .code ? " - Claude Code" : " - Claude"
        // Bound work before grapheme segmentation: one malicious combining-character
        // cluster can be arbitrarily large despite counting as one Character.
        var boundedTitle = ""
        var inputBytes = 0
        for scalar in title.unicodeScalars.prefix(1024) {
            let width = String(scalar).utf8.count
            guard inputBytes + width <= 2048 else { break }
            boundedTitle.unicodeScalars.append(scalar)
            inputBytes += width
        }
        var cleanTitle = boundedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanTitle.hasSuffix(suffix) { cleanTitle.removeLast(suffix.count) }
        cleanTitle = cleanTitle.components(separatedBy: .controlCharacters).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var result = ""
        var outputBytes = 0
        for character in cleanTitle.prefix(Self.maximumTitleCharacters) {
            let width = String(character).utf8.count
            guard outputBytes + width <= Self.maximumTitleBytes else { break }
            result.append(character)
            outputBytes += width
        }
        self.title = result
    }
}

/// Thread-safe event coalescing and delivery validity, independent of AX or timers.
/// A burst shares its first scheduled read; later events never postpone that read.
public final class ClaudeDesktopObservationGate: @unchecked Sendable {
    public struct Ticket: Equatable, Sendable {
        fileprivate let generation: UUID
        fileprivate let request: UUID
    }

    /// A route must stay in front this long before it counts as a visit. Passing
    /// through a chat on the way to another one is navigation noise, not a return target.
    public static let minimumDwell: TimeInterval = 2

    private let lock = NSLock()
    private var generation = UUID()
    private var pending: Ticket?
    private var delivered: ClaudeDesktopObservation?
    private var committed = false
    private var latestStarted: Ticket?

    public init() {}

    /// Call immediately on activation changes, stop, detach, or lost permission.
    public func invalidate() {
        lock.lock(); defer { lock.unlock() }
        generation = UUID(); pending = nil; delivered = nil; committed = false; latestStarted = nil
    }

    public func requestRead() -> Ticket? {
        lock.lock(); defer { lock.unlock() }
        guard pending == nil else { return nil }
        let ticket = Ticket(generation: generation, request: UUID())
        pending = ticket
        return ticket
    }

    /// A canceled old timer cannot consume a newer pending request.
    public func beginRead(_ ticket: Ticket) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard ticket.generation == generation, pending == ticket else { return false }
        pending = nil; latestStarted = ticket
        return true
    }

    public func isCurrent(_ ticket: Ticket) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return ticket.generation == generation
    }

    /// Call only after checking foreground state and permission on the delivery queue.
    /// True starts a dwell for a newly fronted route; the visit is not recorded yet.
    public func acceptDelivery(_ observation: ClaudeDesktopObservation, for ticket: Ticket) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard ticket.generation == generation, latestStarted == ticket else { return false }
        if delivered?.key == observation.key {
            // The page title often settles after the route. Keep the latest title for
            // the pending commit; a rename after commit is not a user navigation.
            if !committed, delivered != observation { delivered = observation }
            return false
        }
        delivered = observation; committed = false
        return true
    }

    /// Call once `minimumDwell` has elapsed since the matching acceptDelivery, after
    /// rechecking foreground state and permission. Returns the observation to record,
    /// with any title that settled during the dwell, or nil when an activation change
    /// or a newer route intervened, or the route was already committed.
    public func commitDwell(_ observation: ClaudeDesktopObservation, for ticket: Ticket) -> ClaudeDesktopObservation? {
        lock.lock(); defer { lock.unlock() }
        guard ticket.generation == generation, !committed, let delivered, delivered.key == observation.key else { return nil }
        committed = true
        return delivered
    }
}
