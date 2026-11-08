import Foundation

public enum DiscoveryScope: String, Codable { case automaticProjects, exactFolders }

/// Controls metadata discovery only; this does not grant transcript or summary access.
public struct DiscoveryPolicy: Codable, Equatable {
    public var scope: DiscoveryScope
    public var folders: [String]
    public var excludedFolders: [String]
    public var excludedConversationIDs: [ConversationKey]
    public var pageSize: Int { didSet { pageSize = min(100, max(1, pageSize)) } }
    public var maxPages: Int { didSet { maxPages = min(10, max(1, maxPages)) } }
    public var cacheTTL: TimeInterval {
        didSet { cacheTTL = cacheTTL.isFinite ? min(86400, max(30, cacheTTL)) : 300 }
    }

    public init(scope: DiscoveryScope = .automaticProjects, folders: [String] = [],
                excludedFolders: [String] = [], excludedConversationIDs: [ConversationKey] = [],
                pageSize: Int = 50, maxPages: Int = 4, cacheTTL: TimeInterval = 300) {
        self.scope = scope; self.folders = folders; self.excludedFolders = excludedFolders
        self.excludedConversationIDs = excludedConversationIDs
        self.pageSize = min(100, max(1, pageSize)); self.maxPages = min(10, max(1, maxPages))
        self.cacheTTL = cacheTTL.isFinite ? min(86400, max(30, cacheTTL)) : 300
    }

    /// Presence of a legacy store, including an empty one, preserves its exact scope.
    public static func legacy(folders: [String]) -> DiscoveryPolicy {
        DiscoveryPolicy(scope: .exactFolders, folders: folders)
    }
    public var maximumEntries: Int { min(100, max(1, pageSize)) * min(10, max(1, maxPages)) }

    public func allows(folder: String, key: ConversationKey) -> Bool {
        guard let path = Self.canonical(folder), !excludedConversationIDs.contains(key) else { return false }
        let excluded = excludedFolders.compactMap(Self.canonical)
        guard !excluded.contains(where: { path == $0 || path.hasPrefix($0 == "/" ? "/" : $0 + "/") }) else { return false }
        return scope == .automaticProjects || folders.compactMap(Self.canonical).contains(path)
    }
    public func shouldRefresh(lastRefreshedAt: Date?, now: Date = Date()) -> Bool {
        guard let lastRefreshedAt else { return true }
        return lastRefreshedAt > now || now.timeIntervalSince(lastRefreshedAt) >= cacheTTL
    }
    private static func canonical(_ path: String) -> String? {
        guard path.hasPrefix("/"), !path.contains("\0") else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private enum CodingKeys: String, CodingKey {
        case scope, folders, excludedFolders, excludedConversationIDs, pageSize, maxPages, cacheTTL
    }
    public init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        let folders = try box.decode([String].self, forKey: .folders)
        let excluded = try box.decode([String].self, forKey: .excludedFolders)
        let ids = try box.decode([ConversationKey].self, forKey: .excludedConversationIDs)
        let size = try box.decode(Int.self, forKey: .pageSize), pages = try box.decode(Int.self, forKey: .maxPages)
        let ttl = try box.decode(TimeInterval.self, forKey: .cacheTTL)
        guard folders.count <= 1000, excluded.count <= 1000, ids.count <= 10000,
              (folders + excluded).allSatisfy({ Self.canonical($0) != nil }),
              ids.allSatisfy({ !$0.id.isEmpty && $0.id.utf8.count <= 512 }),
              (1...100).contains(size), (1...10).contains(pages), ttl.isFinite, (30...86400).contains(ttl)
        else { throw ContextStoreError.invalidStore }
        self.init(scope: try box.decode(DiscoveryScope.self, forKey: .scope), folders: folders,
                  excludedFolders: excluded, excludedConversationIDs: ids, pageSize: size, maxPages: pages, cacheTTL: ttl)
    }
}
