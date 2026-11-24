import Foundation

/// The app-server handshake, defined once for the catalog client and the usage read.
public enum CodexHandshake {
    public static func initialize(clientName: String) -> [String: Any] {
        ["id": 0, "method": "initialize", "params": ["clientInfo": ["name": clientName, "version": "0.2.0"]]]
    }
    public static let initialized: [String: Any] = ["method": "initialized", "params": [String: Any]()]
}

/// One line from the app-server, typed for the usage path.
public enum CodexEnvelope {
    case result(id: Int, value: Any)
    case error(id: Int, code: Int?, message: String)
    case notification(method: String, params: Any?)
    case other

    public init(_ line: Data) {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { self = .other; return }
        if let method = object["method"] as? String, object["id"] == nil {
            self = .notification(method: method, params: object["params"]); return
        }
        guard let id = object["id"] as? Int, object["method"] == nil else { self = .other; return }
        if let error = object["error"] as? [String: Any] {
            self = .error(id: id, code: error["code"] as? Int, message: (error["message"] as? String) ?? ""); return
        }
        if let value = object["result"] { self = .result(id: id, value: value); return }
        self = .other
    }
}

/// Codex subscription limits over `codex app-server`: the existing handshake, then
/// `account/read` and `account/rateLimits/read` on one short-lived connection.
public enum CodexUsage {
    public static let clientName = "spleen_usage"
    public static let accountRead: [String: Any] = ["id": 1, "method": "account/read", "params": ["refreshToken": false]]
    public static let limitsRead: [String: Any] = ["id": 2, "method": "account/rateLimits/read"]
    /// How long a limits reply that arrived first waits for its connection's identity.
    static let identityHold: TimeInterval = 1.5

    public static func launch(executable: URL, workingDirectory: URL, environment: [String: String]) -> HelperLaunch {
        HelperLaunch(executable: executable, arguments: ["app-server"], environment: environment, workingDirectory: workingDirectory)
    }

    static func line(_ message: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]); data.append(10); return data
    }

    public struct Account: Equatable {
        public var identity: UsageIdentity
        /// The workspace account id: the same kind as a usage snapshot's owner.
        public var snapshotKey: String?
        public var type: String?
    }

    public static func account(_ result: Any) -> Account {
        guard let object = result as? [String: Any] else { return Account(identity: .unknown) }
        let routing = object["workspaceRouting"] as? [String: Any]
        let workspace = (routing?["chatgptAccountId"] as? String).flatMap { $0.isEmpty ? nil : UsageIdentity.hash(["codex-account", $0]) }
        guard let account = object["account"] as? [String: Any] else {
            // No account: signed out when this server needs an OpenAI sign-in.
            return Account(identity: object["requiresOpenaiAuth"] as? Bool == true ? .signedOut : .unknown, snapshotKey: workspace)
        }
        let type = account["type"] as? String
        var identity = UsageIdentity.unknown
        if let user = object["userId"] as? String, !user.isEmpty {
            identity = .known(UsagePerson(key: UsageIdentity.hash(["codex-user", type ?? "", user]), organization: workspace))
        } else if let email = account["email"] as? String, !email.isEmpty {
            identity = .known(UsagePerson(key: UsageIdentity.hash(["codex-email", type ?? "", email.lowercased()]), organization: workspace))
        }
        return Account(identity: identity, snapshotKey: workspace, type: type)
    }

    /// Windows from `rateLimitsByLimitId` when it holds buckets, else the single compatible
    /// `rateLimits` bucket; never both, since they can describe the same bucket.
    public static func limits(_ result: Any) -> Result<(windows: [UsageWindow], snapshot: String?), UsageFailure> {
        guard let object = result as? [String: Any] else { return .failure(.incompatible) }
        let snapshot = (object["accountId"] as? String).flatMap { $0.isEmpty ? nil : UsageIdentity.hash(["codex-account", $0]) }
        var buckets: [(key: String, value: [String: Any])] = []
        if let map = object["rateLimitsByLimitId"] as? [String: Any] {
            buckets = map.compactMap { key, value in (value as? [String: Any]).map { (key, $0) } }
        }
        if buckets.isEmpty, let single = object["rateLimits"] as? [String: Any] {
            buckets = [((single["limitId"] as? String) ?? "codex", single)]
        }
        guard !buckets.isEmpty else { return .failure(.incompatible) }
        struct Bucket { let key: String; let name: String?; let windows: [(minutes: Int?, window: UsageWindow)] }
        let parsed: [Bucket] = buckets.map { key, bucket in
            let limitKey = (bucket["limitId"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? key
            let windows: [(Int?, UsageWindow)] = ["primary", "secondary"].compactMap { slot in
                guard let raw = bucket[slot] as? [String: Any], let used = UsageWindow.percent(raw["usedPercent"]) else { return nil }
                let minutes = (raw["windowDurationMins"] as? NSNumber).map(\.intValue)
                let reset = (raw["resetsAt"] as? NSNumber).flatMap { $0.doubleValue.isFinite && $0.doubleValue > 0 ? Date(timeIntervalSince1970: $0.doubleValue) : nil }
                return (minutes, UsageWindow(id: "codex.\(limitKey).\(minutes.map(String.init) ?? slot)",
                                             label: UsageLabels.duration(minutes: minutes), usedPercent: used, resetsAt: reset,
                                             durationMinutes: minutes.flatMap { $0 > 0 ? $0 : nil }))
            }
            return Bucket(key: limitKey, name: UsageLabels.displayName(bucket["limitName"]), windows: windows)
        }
        let several = parsed.count > 1
        let ordered = parsed.sorted { a, b in
            if (a.key == "codex") != (b.key == "codex") { return a.key == "codex" }
            return (a.name ?? a.key).localizedStandardCompare(b.name ?? b.key) == .orderedAscending
        }
        var windows: [UsageWindow] = []
        for bucket in ordered {
            let prefix = several ? (bucket.name ?? (bucket.key == "codex" ? nil : bucket.key)) : nil
            for (_, window) in bucket.windows.sorted(by: { ($0.minutes ?? .max) < ($1.minutes ?? .max) }) {
                var labelled = window
                if let prefix { labelled.label = "\(prefix) · \(window.label)" }
                windows.append(labelled)
            }
        }
        return windows.isEmpty ? .failure(.offlineOrEmpty) : .success((windows, snapshot))
    }

    static func mentionsSignIn(_ message: String) -> Bool {
        let text = message.lowercased()
        return ["authentication required", "not logged in", "not signed in", "log in", "login", "sign in", "unauthorized"].contains { text.contains($0) }
    }

    /// The whole exchange on the helper's owner thread. Identity is emitted the moment it
    /// arrives; a limits reply is judged against the identity in force on this connection.
    public static func read(channel: HelperChannel, cachedOwner: UsageOwner?, now: () -> Date,
                            emit: (UsageEvent) -> Void) throws -> Result<UsageReading, UsageProblem> {
        try channel.send(line(CodexHandshake.initialize(clientName: clientName)))
        handshake: while true {
            switch CodexEnvelope(try channel.receiveLine()) {
            case .result(id: 0, _): break handshake
            case .error(id: 0, _, _): return .failure(UsageProblem(.incompatible))
            default: continue
            }
        }
        try channel.send(line(CodexHandshake.initialized))
        try channel.send(line(accountRead))
        try channel.send(line(limitsRead))
        var account: Account?
        var accountResolved = false
        var signOutSeen = false, switchSeen = false
        var held: CodexEnvelope?
        var heldSince: TimeInterval = 0

        func judge(_ reply: CodexEnvelope) -> Result<UsageReading, UsageProblem> {
            if signOutSeen { return .failure(UsageProblem(.signedOut)) }
            let nonSubscription = account?.type.map { $0 != "chatgpt" } ?? false
            switch reply {
            case .error(_, _, let message):
                if mentionsSignIn(message) { emit(.identity(.signedOut)); return .failure(UsageProblem(.signedOut)) }
                return .failure(UsageProblem(nonSubscription ? .noSubscriptionLimits : .offlineOrEmpty))
            case .result(_, let value):
                switch limits(value) {
                case .failure(let failure): return .failure(UsageProblem(nonSubscription ? .noSubscriptionLimits : failure))
                case .success(let decoded):
                    let inForce = account?.snapshotKey
                    if switchSeen {
                        // After a switch only a reply naming the owner now in force is trusted.
                        guard let named = decoded.snapshot, let inForce, named == inForce else { return .failure(UsageProblem(.accountChanged)) }
                    } else if UsageIdentityRules.snapshotChanged(cached: inForce, observed: decoded.snapshot) {
                        return .failure(UsageProblem(.accountChanged))
                    }
                    return .success(UsageReading(windows: decoded.windows, checkedAt: now(),
                                                 owner: UsageOwner(user: account?.identity ?? .unknown, snapshot: decoded.snapshot)))
                }
            default: return .failure(UsageProblem(.incompatible))
            }
        }

        while true {
            if let reply = held, accountResolved { return judge(reply) }
            let line: Data
            if held != nil {
                let left = identityHold - (ProcessInfo.processInfo.systemUptime - heldSince)
                guard left > 0, let next = try channel.receiveLine(within: left) else { return judge(held!) }
                line = next
            } else { line = try channel.receiveLine() }
            switch CodexEnvelope(line) {
            case .result(id: 1, let value):
                let observed = Self.account(value)
                account = observed; accountResolved = true
                emit(.identity(observed.identity))
                if observed.identity == .signedOut { signOutSeen = true }
                if let cachedOwner, UsageIdentityRules.confirmsChange(cached: cachedOwner.user, observed: observed.identity)
                    || UsageIdentityRules.snapshotChanged(cached: cachedOwner.snapshot, observed: observed.snapshotKey) {
                    switchSeen = true
                }
            case .error(id: 1, _, _):
                accountResolved = true // An older server without account/read: identity stays unknown.
            case .notification(method: "account/updated", let params):
                let fields = params as? [String: Any] ?? [:]
                if fields.keys.contains("authMode"), fields["authMode"] is NSNull {
                    signOutSeen = true; emit(.identity(.signedOut))
                } else if fields["reason"] as? String != "workspaceRoutingReady" {
                    switchSeen = true // A sign-in or switch whose owner this connection cannot name.
                }
            case let reply where Self.isLimitsReply(reply):
                if accountResolved { return judge(reply) }
                held = reply; heldSince = ProcessInfo.processInfo.systemUptime
            default: continue
            }
        }
    }

    static func isLimitsReply(_ envelope: CodexEnvelope) -> Bool {
        switch envelope {
        case .result(id: 2, _), .error(id: 2, _, _): return true
        default: return false
        }
    }

    /// Submits one read to the provider's lane. Every request finishes exactly once.
    /// `executable` is resolved on the lane's thread, never on the caller's.
    public static func fetch(executable resolve: @escaping () -> URL?, workingDirectory: @escaping () -> URL, environment: [String: String],
                             lane: HelperLane, request: UsageFetchRequest, limits: HelperLimits = .usage,
                             now: @escaping () -> Date = Date.init) {
        lane.submit(cancellation: request.cancellation, job: { lane, cancellation in
            let executable = resolve(), neutralDirectory = workingDirectory()
            guard let executable, FileManager.default.isExecutableFile(atPath: executable.path) else {
                request.emit(.finished(.failure(UsageProblem(cancellation.isCancelled ? .cancelled : .missingClient)))); return
            }
            BoundedHelper.exchange(launch(executable: executable, workingDirectory: neutralDirectory, environment: environment),
                                   limits: limits, cancellation: cancellation, lane: lane,
                                   body: { try read(channel: $0, cachedOwner: request.cachedOwner, now: now, emit: request.emit) },
                                   deliver: { result in
                switch result {
                case .success(let outcome): request.emit(.finished(outcome))
                case .failure(let error): request.emit(.finished(.failure(UsageProblem(UsageHelperFailure.map(error)))))
                }
            })
        }, dropped: { request.emit(.finished(.failure(UsageProblem(.cancelled)))) })
    }
}

enum UsageHelperFailure {
    static func map(_ error: HelperError) -> UsageFailure {
        switch error {
        case .timeout: return .timeout
        case .tooLarge: return .incompatible
        case .cancelled: return .cancelled
        case .launchFailed: return .missingClient
        case .unavailable: return .offlineOrEmpty
        }
    }
}
