import Foundation

/// Exact local conversation identity from the focused Codex renderer's AXURL.
/// Route parsing alone never proves focus; the native observer owns that check.
public struct CodexDesktopObservation: Equatable {
    public static let maximumTitleCharacters = 180
    public static let maximumTitleBytes = 720
    public let id: String
    public let title: String
    public var key: ConversationKey { ConversationKey(provider: .codex, id: id) }

    public init?(url: String, title: String) {
        guard url.utf8.count <= 512, let parsed = URL(string: url),
              let key = CodexNavigationRoute.parse(url: parsed),
              let uuid = UUID(uuidString: key.id) else { return nil }
        id = uuid.uuidString.lowercased()
        var bounded = "", bytes = 0
        for scalar in title.unicodeScalars.prefix(1024) {
            let width = String(scalar).utf8.count
            guard bytes + width <= 2048 else { break }
            bounded.unicodeScalars.append(scalar); bytes += width
        }
        var clean = bounded.components(separatedBy: .controlCharacters).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        for suffix in [" - Codex", " - ChatGPT"] where clean.hasSuffix(suffix) { clean.removeLast(suffix.count) }
        var result = ""; bytes = 0
        for character in clean.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maximumTitleCharacters) {
            let width = String(character).utf8.count
            guard bytes + width <= Self.maximumTitleBytes else { break }
            result.append(character); bytes += width
        }
        self.title = result
    }
}

/// Thread-safe event coalescing and delivery validity, independent of AX or timers.
/// A burst shares its first scheduled read; later events never postpone that read.
public final class CodexDesktopObservationGate: @unchecked Sendable {
    public struct Ticket: Equatable, Sendable {
        fileprivate let generation: UUID
        fileprivate let request: UUID
    }

    /// A route must stay in front this long before it counts as a visit. Passing
    /// through a thread on the way to another one is navigation noise, not a return target.
    public static let minimumDwell: TimeInterval = ClaudeDesktopObservationGate.minimumDwell

    private let lock = NSLock()
    private var generation = UUID()
    private var pending: Ticket?
    private var delivered: CodexDesktopObservation?
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
    public func acceptDelivery(_ observation: CodexDesktopObservation, for ticket: Ticket) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard ticket.generation == generation, latestStarted == ticket else { return false }
        if delivered?.key == observation.key {
            // The title can settle after the route. Keep the latest title for the
            // pending commit; a rename after commit is not a user navigation.
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
    public func commitDwell(_ observation: CodexDesktopObservation, for ticket: Ticket) -> CodexDesktopObservation? {
        lock.lock(); defer { lock.unlock() }
        guard ticket.generation == generation, !committed, let delivered, delivered.key == observation.key else { return nil }
        committed = true
        return delivered
    }
}
