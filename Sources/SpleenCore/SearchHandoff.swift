import Foundation

/// Local search transfer only. Queries are neither persisted nor used as activation targets.
/// Keep this wire contract identical in MoonshineCore and SpleenCore.
public struct SearchHandoff: Equatable {
    public enum App: String, CaseIterable {
        case spleen, moonshine
        public var scheme: String { rawValue + "-search" }
        public var bundleID: String { self == .spleen ? "com.davidkim.spleen" : "com.d4j3y2k.moonshine" }
        public var name: String { self == .spleen ? "Spleen" : "Moonshine" }
    }
    public let query: String
    public let returnPID: Int32?
    public init(query: String, returnPID: Int32? = nil) {
        self.query = query; self.returnPID = returnPID
    }
    public func url(for app: App) -> URL? {
        guard query.utf8.count <= 8192, !query.contains("\0"), returnPID == nil || returnPID! > 0 else { return nil }
        var parts = URLComponents()
        parts.scheme = app.scheme; parts.host = "search"
        parts.queryItems = [URLQueryItem(name: "v", value: "1"), URLQueryItem(name: "q", value: query)]
        if let returnPID { parts.queryItems?.append(URLQueryItem(name: "returnPID", value: String(returnPID))) }
        return parts.url
    }
    public init?(url: URL, app: App) {
        guard url.absoluteString.utf8.count <= 32768,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == app.scheme, parts.host == "search", parts.path.isEmpty,
              parts.user == nil, parts.password == nil, parts.port == nil, parts.fragment == nil,
              let items = parts.queryItems, Set(items.map(\.name)).count == items.count,
              Set(items.map(\.name)).isSubset(of: ["v", "q", "returnPID"]),
              items.first(where: { $0.name == "v" })?.value == "1",
              let query = items.first(where: { $0.name == "q" })?.value,
              query.utf8.count <= 8192, !query.contains("\0") else { return nil }
        var pid: Int32?
        if let item = items.first(where: { $0.name == "returnPID" }) {
            guard let value = item.value, let parsed = Int32(value), parsed > 0 else { return nil }
            pid = parsed
        }
        self.init(query: query, returnPID: pid)
    }
}
