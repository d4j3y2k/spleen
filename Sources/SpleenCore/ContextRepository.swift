import Foundation
import Darwin

public enum ContextRepositoryError: Error {
    case fileTooLarge, invalidFile
}

/// All cooperating writers lock the stable sidecar, never the replaced JSON inode.
/// Perform repository work off the shortcut/UI path; acquiring the lock can wait.
public final class ContextRepository {
    public static let maximumFileBytes = 256 * 1024
    public let url: URL

    public init(url: URL) { self.url = url }

    public func load() throws -> ContextMemory {
        try withLock { try readMemory() }
    }

    @discardableResult
    public func record(_ event: ContextEvent, now: Date = Date()) throws -> ContextMemory {
        try withLock {
            var memory = try readMemory()
            memory.record(event, now: now)
            try writeMemory(memory)
            return memory
        }
    }

    @discardableResult
    public func setRecentsEnabled(_ enabled: Bool, clear: Bool = false) throws -> ContextMemory {
        try withLock {
            var memory = try readMemory()
            memory.setRecentsEnabled(enabled)
            if clear { memory.clear() }
            try writeMemory(memory)
            return memory
        }
    }

    private func withLock<T>(_ operation: () throws -> T) throws -> T {
        guard url.isFileURL else { throw ContextRepositoryError.invalidFile }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let descriptor = open(url.path + ".lock", O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw Self.systemError() }
        defer { close(descriptor) }
        try Self.requireRegularFile(descriptor)
        while flock(descriptor, LOCK_EX) != 0 {
            if errno != EINTR { throw Self.systemError() }
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try operation()
    }

    private func readMemory() throws -> ContextMemory {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            if errno == ENOENT { return ContextMemory() }
            throw Self.systemError()
        }
        defer { close(descriptor) }
        let size = try Self.requireRegularFile(descriptor)
        guard size <= Self.maximumFileBytes else { throw ContextRepositoryError.fileTooLarge }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR { continue }
                throw Self.systemError()
            }
            if count == 0 { break }
            guard data.count + count <= Self.maximumFileBytes else { throw ContextRepositoryError.fileTooLarge }
            data.append(contentsOf: buffer.prefix(count))
        }
        // Decode errors propagate. Never replace or repair a corrupt store implicitly.
        return try JSONDecoder().decode(ContextMemory.self, from: data)
    }

    private func writeMemory(_ memory: ContextMemory) throws {
        let data = try JSONEncoder().encode(memory)
        guard data.count <= Self.maximumFileBytes else { throw ContextRepositoryError.fileTooLarge }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".context-\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw Self.systemError() }
        defer { close(descriptor); _ = unlink(temporary.path) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw Self.systemError()
                }
                guard count > 0 else { throw ContextRepositoryError.invalidFile }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else { throw Self.systemError() }
        guard rename(temporary.path, url.path) == 0 else { throw Self.systemError() }
    }

    @discardableResult
    private static func requireRegularFile(_ descriptor: Int32) throws -> Int {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw systemError() }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0 else { throw ContextRepositoryError.invalidFile }
        return Int(info.st_size)
    }

    private static func systemError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}

public enum ContextHookDecoder {
    public static let maximumInputBytes = 64 * 1024

    /// Decode only metadata. No transcript path is opened; unknown fields are discarded.
    public static func codexEvent(data: Data, now: Date = Date()) -> ContextEvent? {
        guard data.count <= maximumInputBytes, now.timeIntervalSince1970.isFinite,
              let input = try? JSONDecoder().decode(CodexInput.self, from: data),
              let target = try? ThreadTarget(input.session_id), target.id == input.session_id,
              input.cwd.hasPrefix("/"), input.cwd.utf8.count <= 4096,
              input.cwd.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        let kind: ContextEventKind
        switch input.hook_event_name {
        case "SessionStart": kind = .sessionStarted
        case "UserPromptSubmit": kind = .userPromptSubmitted
        case "Stop": kind = .turnCompleted
        default: return nil
        }
        return ContextEvent(key: ConversationKey(provider: .codex, id: target.id), project: input.cwd,
                            kind: kind, observedAt: now, source: "codex-hook", evidence: .lifecycle)
    }

    private struct CodexInput: Decodable {
        let session_id: String
        let cwd: String
        let hook_event_name: String
    }
}
