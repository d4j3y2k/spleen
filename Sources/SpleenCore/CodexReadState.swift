import Foundation
import CryptoKit

public enum CodexReadStateError: Error, Equatable {
    case unavailable, unsupportedSchema, ambiguousIdentity, invalidScope, tooLarge
}

public struct CodexDesktopReadSnapshot: Equatable {
    public let states: [LiveSessionState]
    /// Digest of only the selected identity's local unread metadata, never app text.
    public let contentFingerprint: String
}

/// Reads the Desktop's persisted unread set without opening or marking any chat.
/// This is a version-guarded local Desktop format, not a public API or runtime feed.
/// The caller must supply catalog-validated local keys and stop polling when the
/// Desktop is unavailable. Re-reading durable read metadata does not imply activity.
public struct CodexDesktopReadStateClient {
    public static let source = "desktop-persisted-read-state"
    public static let maximumBytes = 8_000_000
    public static let maximumKeys = 64
    public let stateURL: URL

    public init(stateURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/.codex-global-state.json")) {
        self.stateURL = stateURL
    }

    public func read(keys: [ConversationKey], observedAt: Date = Date(), sequence: UInt64,
                     epoch: String, lifetime: TimeInterval = 15) throws -> CodexDesktopReadSnapshot {
        try Self.validate(keys: keys, observedAt: observedAt, epoch: epoch)
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: stateURL) }
        catch { throw CodexReadStateError.unavailable }
        defer { try? handle.close() }
        let data: Data
        do { data = try handle.read(upToCount: Self.maximumBytes + 1) ?? Data() }
        catch { throw CodexReadStateError.unavailable }
        return try Self.decode(data, keys: keys, observedAt: observedAt, sequence: sequence,
                               epoch: epoch, lifetime: lifetime)
    }

    public static func decode(_ data: Data, keys: [ConversationKey], observedAt: Date,
                              sequence: UInt64, epoch: String,
                              lifetime: TimeInterval = 15) throws -> CodexDesktopReadSnapshot {
        try validate(keys: keys, observedAt: observedAt, epoch: epoch)
        guard data.count <= maximumBytes else { throw CodexReadStateError.tooLarge }
        struct ReadState: Decodable {
            let version: Int
            let unreadByIdentity: [String: [String: [String]]]
        }
        struct Root: Decodable {
            let readState: ReadState
            enum CodingKeys: String, CodingKey { case readState = "electron-thread-read-state-v1" }
        }
        let state: ReadState
        do { state = try JSONDecoder().decode(Root.self, from: data).readState }
        catch { throw CodexReadStateError.unsupportedSchema }
        guard state.version == 1 else { throw CodexReadStateError.unsupportedSchema }
        guard state.unreadByIdentity.count == 1, let identity = state.unreadByIdentity.first,
              !identity.key.isEmpty, identity.key.utf8.count <= 256 else {
            throw CodexReadStateError.ambiguousIdentity
        }
        // Never combine accounts or local hosts, and never adopt a migration list.
        let locals = identity.value.filter { $0.key.hasPrefix("local") }
        guard locals.count == 1, let local = locals.first,
              local.key.hasPrefix("local:"), local.key.count > 6,
              local.key.utf8.count <= 256 else { throw CodexReadStateError.ambiguousIdentity }
        guard local.value.count <= 20_000,
              Set(local.value).count == local.value.count,
              local.value.allSatisfy({ (try? ThreadTarget($0).id) == $0 }) else {
            throw CodexReadStateError.unsupportedSchema
        }
        let unread = Set(local.value)
        struct Fingerprint: Encodable {
            let identity: String
            let localHost: String
            let unread: [String]
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let metadata = try encoder.encode(Fingerprint(identity: identity.key, localHost: local.key,
                                                      unread: unread.sorted()))
        let fingerprint = "desktop-read-v1:" + SHA256.hash(data: metadata)
            .map { String(format: "%02x", $0) }.joined()
        let states = keys.map {
            LiveSessionState(key: $0, source: source, epoch: epoch, observedAt: observedAt,
                             lifetime: lifetime, sequence: sequence,
                             activity: nil, isUnread: unread.contains($0.id))
        }
        return CodexDesktopReadSnapshot(states: states, contentFingerprint: fingerprint)
    }

    private static func validate(keys: [ConversationKey], observedAt: Date, epoch: String) throws {
        guard keys.count <= maximumKeys, Set(keys).count == keys.count,
              keys.allSatisfy({ $0.provider == .codex && (try? ThreadTarget($0.id).id) == $0.id }),
              observedAt.timeIntervalSince1970.isFinite,
              !epoch.isEmpty, epoch.utf8.count <= 128 else { throw CodexReadStateError.invalidScope }
    }
}
