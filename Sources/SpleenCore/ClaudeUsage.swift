import Foundation

/// Claude subscription limits through Claude Code's experimental `get_usage` control request.
/// Everything that may change with a Claude Code release lives in this file.
public enum ClaudeUsage {
    /// Headless stdio session that loads no settings, hooks, MCP servers or tools and saves
    /// nothing. Account selection (CLAUDE_CONFIG_DIR, ANTHROPIC_*) comes from the environment.
    public static let arguments = ["-p", "--verbose", "--input-format", "stream-json", "--output-format", "stream-json",
                                   "--no-session-persistence", "--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#,
                                   "--tools", "", "--setting-sources", "", "--settings", #"{"disableAllHooks":true}"#]
    public static let initializeRequest = Data((#"{"type":"control_request","request_id":"init","request":{"subtype":"initialize"}}"# + "\n").utf8)
    /// The wire key is `skip_behaviors`. Without it the CLI scans local transcripts, so this
    /// request is sent only to a client that passed `honoursSkipBehaviors`.
    public static let usageRequest = Data((#"{"type":"control_request","request_id":"usage","request":{"subtype":"get_usage","skip_behaviors":true}}"# + "\n").utf8)
    public static let detachedCapability = "get_usage_detached_v1"
    /// Builds without the capability marker whose handler was inspected and honours the flag.
    public static let inspectedVersions: Set<String> = ["2.1.314", "2.1.325", "2.1.328"]

    /// The preflight gate: a usage request goes only to a client established to honour
    /// `skip_behaviors`, by its advertised capability or by an inspected version.
    public static func honoursSkipBehaviors(version: String?, capabilities: Any?) -> Bool {
        if let list = capabilities as? [Any], list.contains(where: { ($0 as? String) == detachedCapability }) { return true }
        if let map = capabilities as? [String: Any], let flag = map[detachedCapability], (flag as? Bool) ?? true { return true }
        guard let version = version?.trimmingCharacters(in: .whitespaces) else { return false }
        return inspectedVersions.contains(version)
    }

    // MARK: Executable and environment

    /// Native installer, older local install, the app's own PATH, then Homebrew and /usr/local.
    /// No login shell is run.
    public static func candidates(home: URL, path: String?) -> [String] {
        var list = [home.appendingPathComponent(".local/bin/claude").path, home.appendingPathComponent(".claude/local/claude").path]
        for directory in (path ?? "").split(separator: ":") where directory.hasPrefix("/") {
            list.append(URL(fileURLWithPath: String(directory)).appendingPathComponent("claude").path)
        }
        list += ["/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        var seen = Set<String>()
        return list.filter { seen.insert($0).inserted }
    }

    /// The first candidate that is an executable regular file after resolving symlinks.
    public static func resolveExecutable(home: URL, path: String?) -> URL? {
        for candidate in candidates(home: home, path: path) {
            let resolved = URL(fileURLWithPath: candidate).resolvingSymlinksInPath().path
            guard let type = try? FileManager.default.attributesOfItem(atPath: resolved)[.type] as? FileAttributeType,
                  type == .typeRegular, FileManager.default.isExecutableFile(atPath: resolved) else { continue }
            return URL(fileURLWithPath: candidate)
        }
        return nil
    }

    /// Spleen's environment unchanged, except that PATH also holds the executable's own
    /// directory, Homebrew and /usr/local, so a `#!/usr/bin/env node` shim beside its node starts.
    public static func environment(base: [String: String], executable: URL) -> [String: String] {
        var environment = base
        var directories = (base["PATH"] ?? "").split(separator: ":").map(String.init).filter { !$0.isEmpty }
        if directories.isEmpty { directories = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"] }
        for extra in [executable.deletingLastPathComponent().path,
                      executable.resolvingSymlinksInPath().deletingLastPathComponent().path,
                      "/opt/homebrew/bin", "/usr/local/bin"] where !directories.contains(extra) {
            directories.append(extra)
        }
        environment["PATH"] = directories.joined(separator: ":")
        return environment
    }

    // MARK: Protocol

    /// The inner `response` of the control response answering `requestID`, or nil for any other line.
    public static func matches(_ line: Data, requestID: String) -> [String: Any]? {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              object["type"] as? String == "control_response",
              let response = object["response"] as? [String: Any],
              response["request_id"] as? String == requestID else { return nil }
        return response
    }

    /// A person is known by email; organization is only a secondary field. An explicit
    /// not-signed-in answer is a first-party backend with no token and no API key.
    public static func identity(_ raw: Any?) -> UsageIdentity {
        guard let account = raw as? [String: Any] else { return .unknown }
        func text(_ key: String) -> String? {
            (account[key] as? String).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        }
        let provider = text("apiProvider")
        if let email = text("email") {
            return .known(UsagePerson(key: UsageIdentity.hash(["claude", email.lowercased(), provider ?? ""]),
                                      organization: text("organization").map { UsageIdentity.hash(["claude-org", $0]) }))
        }
        if provider == nil || provider == "firstParty", text("tokenSource") == "none",
           text("apiKeySource") == nil || text("apiKeySource") == "none" {
            return .signedOut
        }
        return .unknown
    }

    static func mentionsSignIn(_ text: String?) -> Bool {
        guard let text = text?.lowercased() else { return false }
        return ["not logged in", "not signed in", "log in", "login", "sign in", "auth"].contains { text.contains($0) }
    }

    /// Each understood window once. Named fields win over `limits[]`; the dedup key is the
    /// window's kind and scope, never its values. Spend, extra usage, breakdowns and
    /// unknown kinds are ignored.
    public static func windows(_ limits: [String: Any]) -> [UsageWindow] {
        var seen = Set<String>()
        var found: [(order: Int, name: String, window: UsageWindow)] = []
        func add(_ kind: String, scope: String?, label: String, order: Int, used: Any?, reset: Any?) {
            let normal = scope.map { $0.lowercased().split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" }).joined(separator: "-") }
            let key = "\(kind).\(normal ?? "all")"
            guard !seen.contains(key), let percent = UsageWindow.percent(used) else { return }
            seen.insert(key)
            // The kinds fix their lengths: a session is five hours, every weekly kind seven days.
            found.append((order, normal ?? "", UsageWindow(id: "claude.\(key)", label: label, usedPercent: percent,
                                                         resetsAt: UsageTimestamp.parse(reset),
                                                         durationMinutes: kind == "session" ? 300 : 10_080)))
        }
        func named(_ field: String, _ kind: String, scope: String?, label: String, order: Int) {
            guard let window = limits[field] as? [String: Any] else { return }
            add(kind, scope: scope, label: label, order: order, used: window["utilization"], reset: window["resets_at"])
        }
        named("five_hour", "session", scope: nil, label: "5-hour limit", order: 0)
        named("seven_day", "weekly", scope: nil, label: "Weekly limit", order: 1)
        named("seven_day_opus", "weekly_model", scope: "Opus", label: "Weekly limit · Opus", order: 2)
        named("seven_day_sonnet", "weekly_model", scope: "Sonnet", label: "Weekly limit · Sonnet", order: 2)
        for entry in limits["model_scoped"] as? [Any] ?? [] {
            guard let row = entry as? [String: Any], let name = UsageLabels.displayName(row["display_name"]) else { continue }
            add("weekly_model", scope: name, label: "Weekly limit · \(name)", order: 2, used: row["utilization"], reset: row["resets_at"])
        }
        named("seven_day_oauth_apps", "weekly_surface", scope: "connected apps", label: "Weekly limit · connected apps", order: 3)
        for entry in limits["limits"] as? [Any] ?? [] {
            guard let row = entry as? [String: Any], let kind = row["kind"] as? String else { continue }
            switch kind {
            case "session": add("session", scope: nil, label: "5-hour limit", order: 0, used: row["percent"], reset: row["resets_at"])
            case "weekly_all": add("weekly", scope: nil, label: "Weekly limit", order: 1, used: row["percent"], reset: row["resets_at"])
            case "weekly_scoped":
                let scope = row["scope"] as? [String: Any]
                guard let name = UsageLabels.displayName((scope?["model"] as? [String: Any])?["display_name"]) else { continue }
                add("weekly_model", scope: name, label: "Weekly limit · \(name)", order: 2, used: row["percent"], reset: row["resets_at"])
            default: continue
            }
        }
        return found.sorted { $0.order != $1.order ? $0.order < $1.order : $0.name < $1.name }.map(\.window)
    }

    /// The usage reply, judged on its own. `gateVersion` is blocked when a client that passed
    /// preflight still returned a transcript scan.
    public static func outcome(_ reply: [String: Any], identity: UsageIdentity, checkedAt: Date,
                               version: String?, gate: ClaudeUsageGate) -> Result<UsageReading, UsageProblem> {
        guard reply["subtype"] as? String == "success" else {
            return .failure(UsageProblem(mentionsSignIn(reply["error"] as? String) ? .signedOut : .incompatible))
        }
        let usage = reply["response"] as? [String: Any] ?? [:]
        if let behaviors = usage["behaviors"], !(behaviors is NSNull) {
            gate.block(version) // Discarded unread; no further usage request to this version.
            return .failure(UsageProblem(.incompatible))
        }
        if usage["rate_limits_available"] as? Bool == false { return .failure(UsageProblem(.noSubscriptionLimits)) }
        guard let limits = usage["rate_limits"] as? [String: Any] else { return .failure(UsageProblem(.offlineOrEmpty)) }
        let found = windows(limits)
        guard !found.isEmpty else { return .failure(UsageProblem(.offlineOrEmpty)) }
        return .success(UsageReading(windows: found, checkedAt: checkedAt, owner: UsageOwner(user: identity)))
    }

    /// The exchange on the helper's owner thread: initialize (identity and preflight), then at
    /// most one usage request.
    public static func read(channel: HelperChannel, gate: ClaudeUsageGate, now: () -> Date,
                            emit: (UsageEvent) -> Void) throws -> Result<UsageReading, UsageProblem> {
        var initialize: [String: Any]
        do {
            try channel.send(initializeRequest)
            repeat { initialize = matches(try channel.receiveLine(), requestID: "init") ?? [:] } while initialize.isEmpty
        } catch HelperError.unavailable {
            return .failure(UsageProblem(.missingClient)) // Exited before answering: a shim that cannot start.
        }
        guard initialize["subtype"] as? String == "success", let body = initialize["response"] as? [String: Any] else {
            return .failure(UsageProblem(mentionsSignIn(initialize["error"] as? String) ? .signedOut : .incompatible))
        }
        let identity = identity(body["account"])
        emit(.identity(identity))
        if identity == .signedOut { return .failure(UsageProblem(.signedOut)) }
        let version = body["claude_code_version"] as? String
        guard !gate.isBlocked(version), honoursSkipBehaviors(version: version, capabilities: body["capabilities"]) else {
            return .failure(UsageProblem(.incompatible))
        }
        let checkedAt = now()
        try channel.send(usageRequest)
        var reply: [String: Any]
        repeat { reply = matches(try channel.receiveLine(), requestID: "usage") ?? [:] } while reply.isEmpty
        return outcome(reply, identity: identity, checkedAt: checkedAt, version: version, gate: gate)
    }

    public static func launch(executable: URL, workingDirectory: URL, environment base: [String: String]) -> HelperLaunch {
        HelperLaunch(executable: executable, arguments: arguments,
                     environment: environment(base: base, executable: executable), workingDirectory: workingDirectory)
    }

    /// Submits one read to the provider's lane. Every request finishes exactly once.
    /// `executable` is resolved on the lane's thread, never on the caller's.
    public static func fetch(executable resolve: @escaping () -> URL?, workingDirectory: @escaping () -> URL, environment: [String: String],
                             lane: HelperLane, gate: ClaudeUsageGate, request: UsageFetchRequest,
                             limits: HelperLimits = .usage, now: @escaping () -> Date = Date.init) {
        lane.submit(cancellation: request.cancellation, job: { lane, cancellation in
            let executable = resolve(), neutralDirectory = workingDirectory()
            guard let executable else {
                request.emit(.finished(.failure(UsageProblem(cancellation.isCancelled ? .cancelled : .missingClient)))); return
            }
            BoundedHelper.exchange(launch(executable: executable, workingDirectory: neutralDirectory, environment: environment),
                                   limits: limits, cancellation: cancellation, lane: lane,
                                   body: { try read(channel: $0, gate: gate, now: now, emit: request.emit) },
                                   deliver: { result in
                switch result {
                case .success(let outcome): request.emit(.finished(outcome))
                case .failure(let error): request.emit(.finished(.failure(UsageProblem(UsageHelperFailure.map(error)))))
                }
            })
        }, dropped: { request.emit(.finished(.failure(UsageProblem(.cancelled)))) })
    }
}

/// Client versions that passed preflight and still scanned transcripts, for this app run.
public final class ClaudeUsageGate {
    private let lock = NSLock()
    private var blocked = Set<String>()
    public init() {}
    public func isBlocked(_ version: String?) -> Bool { lock.lock(); defer { lock.unlock() }; return blocked.contains(version ?? "") }
    public func block(_ version: String?) { lock.lock(); blocked.insert(version ?? ""); lock.unlock() }
}
