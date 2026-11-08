import Foundation

/// These names preserve the provider's actual event semantics. In particular,
/// Stop is an attempted stop, not proof that every matching hook allowed it.
public enum ActivityHookKind: String, Codable, CaseIterable {
    case sessionStarted = "SessionStart", sessionEnded = "SessionEnd"
    case promptSubmitted = "UserPromptSubmit"
    case preModelRequest = "PreModelRequest", postModelRequest = "PostModelRequest"
    case preToolUse = "PreToolUse", postToolUse = "PostToolUse"
    case permissionRequested = "PermissionRequest"
    case stopAttempted = "Stop", interrupted = "Interrupt"
    case subagentStarted = "SubagentStart", subagentStopAttempted = "SubagentStop"
    /// Separate `notify` callback, not a Stop hook.
    case turnCompleted = "agent-turn-complete"
}

/// Receipt metadata only. No prompt, reply, command, result or transcript path.
public struct ActivityHookEvent: Codable, Equatable {
    public let id: UUID
    public let key: ConversationKey
    public let host: String
    public let project: String
    public let kind: ActivityHookKind
    public let turnID: String?
    public let agentID: String?
    public let toolUseID: String?
    public let receivedAt: Date

    public init(key: ConversationKey, host: String = "local", project: String, kind: ActivityHookKind,
                turnID: String? = nil, agentID: String? = nil, toolUseID: String? = nil,
                receivedAt: Date, id: UUID = UUID()) {
        self.id = id; self.key = key; self.host = host; self.project = project; self.kind = kind
        self.turnID = turnID; self.agentID = agentID; self.toolUseID = toolUseID; self.receivedAt = receivedAt
    }
    public var isValid: Bool {
        guard key.provider == .codex, host == "local", (try? ThreadTarget(key.id).id) == key.id,
              project.hasPrefix("/"), project.utf8.count <= 4096,
              project.rangeOfCharacter(from: .controlCharacters) == nil,
              receivedAt.timeIntervalSince1970.isFinite else { return false }
        func opaque(_ value: String?) -> Bool {
            guard let value else { return true }
            return !value.isEmpty && value.utf8.count <= 160 &&
                value.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil
        }
        guard opaque(turnID), opaque(agentID), opaque(toolUseID) else { return false }
        if kind != .sessionStarted && kind != .sessionEnded && turnID == nil { return false }
        if (kind == .preToolUse || kind == .postToolUse) && toolUseID == nil { return false }
        if (kind == .subagentStarted || kind == .subagentStopAttempted) && agentID == nil { return false }
        return true
    }
}

public enum ActivityHookDecoder {
    public static let maximumInputBytes = 64 * 1024
    public static func codexEvent(data: Data, now: Date = Date()) -> ActivityHookEvent? {
        struct Input: Decodable {
            let session_id: String; let cwd: String; let hook_event_name: ActivityHookKind
            let turn_id: String?; let agent_id: String?; let tool_use_id: String?
        }
        guard data.count <= maximumInputBytes, let input = try? JSONDecoder().decode(Input.self, from: data),
              input.hook_event_name != .turnCompleted else { return nil }
        let event = ActivityHookEvent(key: ConversationKey(provider: .codex, id: input.session_id), project: input.cwd,
            kind: input.hook_event_name, turnID: input.turn_id, agentID: input.agent_id, toolUseID: input.tool_use_id, receivedAt: now)
        return event.isValid ? event : nil
    }
    /// `notify` supplies JSON as one command-line argument, unlike hook stdin.
    /// Completion has an observed receipt time; no source completion timestamp exists.
    public static func codexNotification(data: Data, now: Date = Date()) -> ActivityHookEvent? {
        struct Input: Decodable {
            let type: String; let threadID: String; let turnID: String; let cwd: String
            enum CodingKeys: String, CodingKey { case type, threadID = "thread-id", turnID = "turn-id", cwd }
        }
        guard data.count <= maximumInputBytes, let input = try? JSONDecoder().decode(Input.self, from: data),
              input.type == ActivityHookKind.turnCompleted.rawValue else { return nil }
        let event = ActivityHookEvent(key: ConversationKey(provider: .codex, id: input.threadID), project: input.cwd,
            kind: .turnCompleted, turnID: input.turnID, receivedAt: now)
        return event.isValid ? event : nil
    }
}

public struct ActivityHookRecord: Codable, Equatable {
    public let sequence: UInt64
    public let event: ActivityHookEvent
}

/// A bounded receipt log with a producer epoch. Polling never renews event leases.
public struct ActivityHookSnapshot: Codable, Equatable {
    public static let maximumEvents = 128
    public static let retention: TimeInterval = 3600
    public static let pulseLifetime: TimeInterval = 15
    public static let source = "codex-lifecycle-hooks"
    public private(set) var version = 1
    public private(set) var enabled = false
    public private(set) var epoch = UUID().uuidString
    public private(set) var sequence: UInt64 = 0
    public private(set) var records: [ActivityHookRecord] = []
    public var events: [ActivityHookEvent] { records.map(\.event) }
    public init() {}
    public mutating func setEnabled(_ value: Bool) {
        guard enabled != value else { return }
        enabled = value; records = []; epoch = UUID().uuidString; sequence = 0
    }
    @discardableResult public mutating func record(_ event: ActivityHookEvent, now: Date) -> Bool {
        guard enabled, event.isValid, now.timeIntervalSince1970.isFinite, event.receivedAt <= now,
              now.timeIntervalSince(event.receivedAt) < Self.pulseLifetime,
              sequence < UInt64.max, !records.contains(where: { $0.event.id == event.id }),
              records.last(where: { $0.event.key == event.key }).map({ $0.event.receivedAt <= event.receivedAt }) ?? true else { return false }
        prune(now: now)
        sequence += 1; records.append(ActivityHookRecord(sequence: sequence, event: event))
        if records.count > Self.maximumEvents { records.removeFirst(records.count - Self.maximumEvents) }
        return true
    }
    public mutating func prune(now: Date) {
        records.removeAll { now.timeIntervalSince($0.event.receivedAt) >= Self.retention || $0.event.receivedAt > now }
    }
    public func validate() throws {
        guard version == 1, UUID(uuidString: epoch) != nil, records.count <= Self.maximumEvents,
              enabled || records.isEmpty, Set(records.map { $0.event.id }).count == records.count,
              records.allSatisfy({ $0.sequence > 0 && $0.sequence <= sequence && $0.event.isValid }) else {
            throw ActivityHookRepositoryError.invalidFile
        }
        var previousTimes: [ConversationKey: Date] = [:]
        for index in records.indices {
            let record = records[index]
            guard index == 0 || record.sequence > records[index - 1].sequence,
                  previousTimes[record.event.key].map({ record.event.receivedAt >= $0 }) ?? true else {
                throw ActivityHookRepositoryError.invalidFile
            }
            previousTimes[record.event.key] = record.event.receivedAt
        }
    }

    /// Actual receipt times, not renewed by polling. Useful ranking history even
    /// when a long model/tool operation has outlasted its live evidence lease.
    public func recentActivity(at now: Date) -> [ConversationKey: Date] {
        guard enabled else { return [:] }
        var dates: [ConversationKey: Date] = [:]
        for record in records {
            let event = record.event
            guard [.promptSubmitted, .preModelRequest, .preToolUse, .subagentStarted].contains(event.kind),
                  event.receivedAt <= now, now.timeIntervalSince(event.receivedAt) < ContextMemory.hintLifetime else { continue }
            dates[event.key] = max(dates[event.key] ?? .distantPast, event.receivedAt)
        }
        return dates
    }

    /// Conservative pulses, not a complete runtime subscription. PermissionRequest
    /// does not prove a visible blocker (another hook can auto-allow). Stop does not
    /// prove completion (another hook can continue). Only notify proves a turn ended.
    public func samples(at now: Date) -> [LiveSessionState] {
        guard enabled, now.timeIntervalSince1970.isFinite else { return [] }
        let groups = Dictionary(grouping: records.filter { $0.event.receivedAt <= now && now.timeIntervalSince($0.event.receivedAt) < Self.retention }, by: { $0.event.key })
        return groups.keys.sorted { $0.id < $1.id }.compactMap { key in
            guard let records = groups[key], let latest = records.last else { return nil }
            var rootTurn: String?
            var retiredTurns = Set<String>()
            var active: [String: Date] = [:]
            var completed: String?
            func unit(_ event: ActivityHookEvent, _ suffix: String) -> String { (event.agentID ?? "root") + ":" + suffix }
            for record in records {
                let event = record.event
                if event.kind == .sessionStarted || event.kind == .sessionEnded {
                    rootTurn = nil; retiredTurns = []; active = [:]; completed = nil
                    continue
                }
                guard let turn = event.turnID else { continue }
                let canStartTurn = event.kind == .promptSubmitted || event.kind == .preModelRequest || event.kind == .preToolUse
                if event.agentID == nil, canStartTurn, turn != rootTurn, !retiredTurns.contains(turn) {
                    if let rootTurn { retiredTurns.insert(rootTurn) }
                    rootTurn = turn; active = [:]; completed = nil
                }
                guard rootTurn == nil || rootTurn == turn, !retiredTurns.contains(turn) else { continue }
                if rootTurn == nil { rootTurn = turn }
                switch event.kind {
                case .preModelRequest:
                    if event.agentID == nil { completed = nil }
                    active[unit(event, "model")] = event.receivedAt
                case .postModelRequest:
                    active.removeValue(forKey: unit(event, "model"))
                case .preToolUse:
                    if event.agentID == nil { completed = nil }
                    active[unit(event, "tool:" + (event.toolUseID ?? ""))] = event.receivedAt
                case .postToolUse:
                    active.removeValue(forKey: unit(event, "tool:" + (event.toolUseID ?? "")))
                case .subagentStarted:
                    active[unit(event, "agent")] = event.receivedAt
                case .subagentStopAttempted:
                    let prefix = (event.agentID ?? "") + ":"
                    active = active.filter { !$0.key.hasPrefix(prefix) }
                case .permissionRequested:
                    // There is no stable approval resolution event in this hook schema.
                    // Clear only this agent's pending operation; leave other agents alone.
                    let prefix = (event.agentID ?? "root") + ":"
                    active = active.filter { !$0.key.hasPrefix(prefix) }
                case .stopAttempted, .interrupted:
                    if let agent = event.agentID { active = active.filter { !$0.key.hasPrefix(agent + ":") } }
                    else { active = active.filter { !$0.key.hasPrefix("root:") } }
                case .turnCompleted:
                    completed = turn; active = active.filter { !$0.key.hasPrefix("root:") }
                case .promptSubmitted:
                    completed = nil // A prompt is not proof a request has started.
                case .sessionStarted, .sessionEnded: break
                }
            }
            let newestActive = active.values.filter { $0 <= now && now.timeIntervalSince($0) < Self.pulseLifetime }.max()
            let expires = newestActive?.addingTimeInterval(Self.pulseLifetime) ?? latest.event.receivedAt.addingTimeInterval(Self.pulseLifetime)
            guard expires > now else { return nil }
            return LiveSessionState(key: key, source: Self.source, epoch: epoch,
                observedAt: latest.event.receivedAt, lifetime: max(0, expires.timeIntervalSince(latest.event.receivedAt)),
                sequence: latest.sequence, activity: newestActive == nil ? nil : .working, isUnread: nil,
                completion: completed.map { LiveTurnCompletion(turnID: $0) })
        }
    }
}
