import Foundation
import Darwin

public struct CatalogEntry: Codable, Equatable {
    public var id: String
    public var title: String
    public var folder: String
    public var updatedAt: Date
    public var createdAt: Date?
    public init(id: String, title: String, folder: String, updatedAt: Date, createdAt: Date? = nil) {
        self.id = id; self.title = title; self.folder = folder; self.updatedAt = updatedAt; self.createdAt = createdAt
    }
    public var destination: Destination {
        // Codex currently uses UUIDs. Stable fallback UUID for opaque protocol IDs.
        let bytes = Array(id.utf8)
        var hash = [UInt8](repeating: 0, count: 16)
        for (i, byte) in bytes.enumerated() { hash[i % 16] = hash[i % 16] &* 31 &+ byte }
        let hex = hash.map { String(format: "%02x", $0) }.joined()
        let uuid = UUID(uuidString: id) ?? UUID(uuidString: "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.suffix(12))")!
        return Destination(id: uuid, title: title, threadID: id)
    }
}

public struct CatalogCache: Codable {
    public var version = 1
    public var folders: [String] = []
    public var entries: [CatalogEntry] = []
    public var hiddenIDs: [String] = []
    public var refreshedAt: Date?
    public var truncated = false
    public var policy: DiscoveryPolicy?
    public init() {}
    public var effectivePolicy: DiscoveryPolicy { policy ?? .legacy(folders: folders) }
    public func includes(_ entry: CatalogEntry) -> Bool {
        effectivePolicy.allows(folder: entry.folder, key: ConversationKey(provider: .codex, id: entry.id))
    }
    public func merged(with saved: SavedState) -> SavedState {
        var merged = saved
        let known = Set(saved.destinations.filter { $0.provider == .codex }.map(\.threadID))
        let hidden = Set(hiddenIDs)
        merged.destinations += entries.filter { includes($0) && !known.contains($0.id) && !hidden.contains($0.id) }
            .sorted { $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt }.map(\.destination)
        return merged
    }
    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
    public static func load(from url: URL) throws -> CatalogCache {
        let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard (1...2).contains(value.version), value.folders.count <= 10, value.entries.count <= 1000,
              Set(value.entries.map(\.id)).count == value.entries.count,
              value.folders.allSatisfy({ $0.hasPrefix("/") }),
              value.entries.allSatisfy({ (try? ThreadTarget($0.id).id) == $0.id && !$0.title.isEmpty && value.includes($0) }) else { throw SpleenError.invalidStore }
        return value
    }
}

public enum CatalogError: LocalizedError {
    case unavailable, timeout, protocolError, tooLarge, invalidScope
    public var errorDescription: String? {
        switch self {
        case .unavailable: return "Codex catalog is unavailable. Saved and cached chats still work."
        case .timeout: return "Catalog refresh timed out. Try again later."
        case .protocolError: return "This Codex version returned an unsupported catalog response."
        case .tooLarge: return "Catalog response exceeded the safety limit."
        case .invalidScope: return "Choose between one and ten exact project folders."
        }
    }
}

public struct CatalogPage {
    public let entries: [CatalogEntry]
    public let nextCursor: String?
}

public enum CatalogDecoder {
    public static func page(_ data: Data, allowedFolders: [String]) throws -> CatalogPage {
        try page(data, policy: .legacy(folders: allowedFolders))
    }
    public static func page(_ data: Data, policy: DiscoveryPolicy) throws -> CatalogPage {
        struct Row: Decodable { let id: String; let name: String?; let cwd: String; let updatedAt: Double; let createdAt: Double? }
        struct Page: Decodable { let data: [Row]; let nextCursor: String? }
        let page = try JSONDecoder().decode(Page.self, from: data)
        // Decode only required metadata. Never use preview as a fallback title.
        let entries = page.data.compactMap { row -> CatalogEntry? in
            guard policy.allows(folder: row.cwd, key: ConversationKey(provider: .codex, id: row.id)), (try? ThreadTarget(row.id).id) == row.id else { return nil }
            let title = row.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            let created = row.createdAt.flatMap { $0.isFinite && $0 > 0 && $0 <= row.updatedAt ? Date(timeIntervalSince1970: $0) : nil }
            return CatalogEntry(id: row.id, title: String((title?.isEmpty == false ? title! : "Untitled chat · \(row.id.prefix(8))").prefix(240)), folder: row.cwd, updatedAt: Date(timeIntervalSince1970: row.updatedAt), createdAt: created)
        }
        return CatalogPage(entries: entries, nextCursor: page.nextCursor)
    }
}

/// A bounded, short-lived stdio client. No resume, turn, auth or mutation methods.
/// Call on a background queue. The app-server owns its supported store access.
public final class CodexCatalogClient {
    public let executable: URL
    public init(executable: URL = URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex")) { self.executable = executable }
    public func fetch(folders: [String]) throws -> (entries: [CatalogEntry], truncated: Bool) {
        guard !folders.isEmpty, folders.count <= 10, folders.allSatisfy({ $0.hasPrefix("/") }) else { throw CatalogError.invalidScope }
        return try fetch(policy: .legacy(folders: folders))
    }
    public func fetch(policy: DiscoveryPolicy) throws -> (entries: [CatalogEntry], truncated: Bool) {
        guard policy.scope == .automaticProjects || (!policy.folders.isEmpty && policy.folders.count <= 10 && policy.folders.allSatisfy({ $0.hasPrefix("/") })) else { throw CatalogError.invalidScope }
        return try session { send, receive in
        var entries: [CatalogEntry] = [], cursor: String?
        for pageIndex in 1...min(10, max(1, policy.maxPages)) {
            var params: [String: Any] = ["limit": min(100, max(1, policy.pageSize)), "archived": false, "useStateDbOnly": true,
                "sourceKinds": ["cli", "vscode", "exec", "appServer", "unknown"], "sortKey": "updated_at"]
            if policy.scope == .exactFolders { params["cwd"] = policy.folders }
            if let cursor { params["cursor"] = cursor }
            try send(["id": pageIndex, "method": "thread/list", "params": params])
            let page = try CatalogDecoder.page(receive(pageIndex), policy: policy)
            entries += page.entries; cursor = page.nextCursor
            if cursor == nil { break }
        }
        var seen = Set<String>()
        return (Array(entries.filter { seen.insert($0.id).inserted }.prefix(policy.maximumEntries)), cursor != nil)
        }
    }
    /// At most eight changed, exact-folder threads and three summary turns each.
    /// Older providers simply leave title/project relevance available.
    public func insights(entries: [CatalogEntry], folders: [String]) throws -> [ThreadInsight] {
        guard !folders.isEmpty, folders.count <= 10, folders.allSatisfy({ $0.hasPrefix("/") }),
              entries.count <= 8, entries.allSatisfy({ folders.contains($0.folder) && (try? ThreadTarget($0.id).id) == $0.id }) else { throw CatalogError.invalidScope }
        return try insights(entries: entries, policy: .legacy(folders: folders))
    }
    public func insights(entries: [CatalogEntry], policy: DiscoveryPolicy) throws -> [ThreadInsight] {
        guard entries.count <= 8, entries.allSatisfy({ policy.allows(folder: $0.folder, key: ConversationKey(provider: .codex, id: $0.id)) && (try? ThreadTarget($0.id).id) == $0.id }) else { throw CatalogError.invalidScope }
        return try session { send, receive in
            var results: [ThreadInsight] = []
            for (index, entry) in entries.enumerated() {
                do {
                    let id = index * 3 + 1
                    try send(["id": id, "method": "thread/read", "params": ["threadId": entry.id, "includeTurns": false]])
                    try InsightDecoder.validateMetadata(receive(id), entry: entry, folders: [entry.folder])
                    try send(["id": id + 1, "method": "thread/turns/list", "params": ["threadId": entry.id, "limit": 3, "sortDirection": "desc", "itemsView": "summary"]])
                    let note = try InsightDecoder.page(receive(id + 1), entry: entry)
                    // A message update during the read invalidates this window too.
                    try send(["id": id + 2, "method": "thread/read", "params": ["threadId": entry.id, "includeTurns": false]])
                    try InsightDecoder.validateMetadata(receive(id + 2), entry: entry, folders: [entry.folder])
                    results.append(note)
                } catch CatalogError.invalidScope { continue }
                catch { break } // Keep completed notes, no retries or unbounded reads.
            }
            return results
        }
    }
    private func session<T>(_ body: (_ send: ([String: Any]) throws -> Void, _ receive: (Int) throws -> Data) throws -> T) throws -> T {
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = executable; process.arguments = ["app-server"]
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw CatalogError.unavailable }
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            // A helper is never left running if graceful termination fails.
            let end = ProcessInfo.processInfo.systemUptime + 0.5
            while process.isRunning && ProcessInfo.processInfo.systemUptime < end { usleep(10_000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            try? output.fileHandleForReading.close()
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        var buffer = Data(), total = 0
        func send(_ message: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: message); data.append(10)
            try input.fileHandleForWriting.write(contentsOf: data)
        }
        func receive(_ id: Int) throws -> Data {
            while ProcessInfo.processInfo.systemUptime < deadline {
                if let newline = buffer.firstIndex(of: 10) {
                    let line = buffer[..<newline]; buffer.removeSubrange(...newline)
                    guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any] else { throw CatalogError.protocolError }
                    guard object["id"] as? Int == id else { continue }
                    guard object["error"] == nil, let result = object["result"] else { throw CatalogError.protocolError }
                    return try JSONSerialization.data(withJSONObject: result)
                }
                var fd = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
                let ready = poll(&fd, 1, 100)
                guard ready >= 0 else { throw CatalogError.unavailable }
                if ready == 0 { continue }
                var bytes = [UInt8](repeating: 0, count: 16384)
                let count = Darwin.read(fd.fd, &bytes, bytes.count)
                guard count > 0 else { throw CatalogError.unavailable }
                total += count; guard total <= 4_000_000 else { throw CatalogError.tooLarge }
                buffer.append(contentsOf: bytes.prefix(count))
            }
            throw CatalogError.timeout
        }
        try send(["id": 0, "method": "initialize", "params": ["clientInfo": ["name": "spleen_catalog", "version": "0.2.0"]]])
        _ = try receive(0)
        try send(["method": "initialized", "params": [:]])
        return try body(send, receive)
    }
}
