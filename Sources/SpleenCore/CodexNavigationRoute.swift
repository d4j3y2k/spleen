import Foundation

/// Decodes only the packaged Codex renderer's live conversation route. This is
/// not itself proof of foreground visibility: callers must read the focused
/// window's live AXURL and confirm the app identity before recording a visit.
// Installed renderer route matching explicitly uses hostId ?? "local".
// Verified in app.asar webview/assets/async/117976.e5d78b46fd.js (Nov 7, 2026).
public enum CodexNavigationRoute {
    public static func parse(url: URL, defaultHostIsVerifiedLocal: Bool = true) -> ConversationKey? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "app", components.host == "-", components.port == nil,
              components.user == nil, components.password == nil,
              components.fragment == nil, !components.percentEncodedPath.lowercased().contains("%2f") else { return nil }
        let query = components.queryItems ?? []
        // initialRoute belongs to bootstrap, not observed current navigation.
        guard !query.contains(where: { $0.name == "initialRoute" }) else { return nil }
        let hosts = query.filter { $0.name == "hostId" }
        guard hosts.count <= 1 else { return nil }
        if let host = hosts.first {
            guard host.value == "local" else { return nil }
        } else if !defaultHostIsVerifiedLocal { return nil }
        let path = components.path.split(separator: "/", omittingEmptySubsequences: false)
        let id: String
        if path.count == 3, path[0].isEmpty, path[1] == "local" {
            id = String(path[2])
        } else if path.count == 4, path[0].isEmpty, path[1] == "hotkey-window", path[2] == "thread" {
            id = String(path[3])
        } else { return nil }
        guard UUID(uuidString: id) != nil else { return nil }
        return ConversationKey(provider: .codex, id: id)
    }
}
