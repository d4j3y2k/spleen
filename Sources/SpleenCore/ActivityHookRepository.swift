import Foundation
import Darwin

public enum ActivityHookRepositoryError: Error { case invalidFile, fileTooLarge, busy }

/// Private local journal. A stable lock serializes cooperating helpers; a short
/// nonblocking lock deadline ensures lifecycle reporting cannot stall the agent.
public final class ActivityHookRepository {
    public static let maximumFileBytes = 256 * 1024
    public let url: URL
    public init(url: URL) { self.url = url }
    public func load(now: Date = Date()) throws -> ActivityHookSnapshot {
        try locked { var value = try read(); value.prune(now: now); return value }
    }
    @discardableResult public func record(_ event: ActivityHookEvent, now: Date = Date()) throws -> Bool {
        try locked {
            var value = try read()
            guard value.record(event, now: now) else { return false }
            try write(value); return true
        }
    }
    @discardableResult public func setEnabled(_ enabled: Bool, now: Date = Date()) throws -> ActivityHookSnapshot {
        try locked { var value = try read(); value.setEnabled(enabled); value.prune(now: now); try write(value); return value }
    }
    private func locked<T>(_ action: () throws -> T) throws -> T {
        guard url.isFileURL else { throw ActivityHookRepositoryError.invalidFile }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let descriptor = open(url.path + ".lock", O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw systemError() }
        defer { close(descriptor) }
        _ = try regularSize(descriptor)
        let deadline = ProcessInfo.processInfo.systemUptime + 0.2
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR else { throw systemError() }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw ActivityHookRepositoryError.busy }
            usleep(1000)
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try action()
    }
    private func read() throws -> ActivityHookSnapshot {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            if errno == ENOENT { return ActivityHookSnapshot() }
            throw systemError()
        }
        defer { close(descriptor) }
        guard try regularSize(descriptor) <= Self.maximumFileBytes else { throw ActivityHookRepositoryError.fileTooLarge }
        var data = Data(), bytes = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = bytes.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count < 0 { if errno == EINTR { continue }; throw systemError() }
            if count == 0 { break }
            guard data.count + count <= Self.maximumFileBytes else { throw ActivityHookRepositoryError.fileTooLarge }
            data.append(contentsOf: bytes.prefix(count))
        }
        let value = try JSONDecoder().decode(ActivityHookSnapshot.self, from: data)
        try value.validate(); return value
    }
    private func write(_ value: ActivityHookSnapshot) throws {
        try value.validate()
        let data = try JSONEncoder().encode(value)
        guard data.count <= Self.maximumFileBytes else { throw ActivityHookRepositoryError.fileTooLarge }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".activity-\(UUID()).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw systemError() }
        defer { close(descriptor); _ = unlink(temporary.path) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 { if errno == EINTR { continue }; throw systemError() }
                guard count > 0 else { throw ActivityHookRepositoryError.invalidFile }
                offset += count
            }
        }
        guard fsync(descriptor) == 0, rename(temporary.path, url.path) == 0 else { throw systemError() }
    }
    private func regularSize(_ descriptor: Int32) throws -> Int {
        var value = stat()
        guard fstat(descriptor, &value) == 0 else { throw systemError() }
        guard value.st_mode & S_IFMT == S_IFREG, value.st_size >= 0 else { throw ActivityHookRepositoryError.invalidFile }
        return Int(value.st_size)
    }
    private func systemError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}
