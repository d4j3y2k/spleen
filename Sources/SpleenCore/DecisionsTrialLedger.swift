import Foundation
import CryptoKit
import Darwin

public enum DecisionsTrialError: Error {
    case invalidConfiguration, expired, limitReached, duplicateRequest
    case oversizedRequest, corruptLedger, configurationMismatch, clockMovedBackwards
}

/// Explicit finite request allowance. This is not an estimate or guarantee of dollar spend.
public struct DecisionsTrialConfiguration: Codable, Equatable {
    public let id: String
    public let maximumRequests: Int
    public let expiresAt: Date
    public init(id: String, maximumRequests: Int = 20, expiresAt: Date) throws {
        guard !id.isEmpty, id.utf8.count <= 80,
              id.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil,
              (1...100).contains(maximumRequests), expiresAt.timeIntervalSince1970.isFinite else {
            throw DecisionsTrialError.invalidConfiguration
        }
        self.id = id; self.maximumRequests = maximumRequests; self.expiresAt = expiresAt
    }
    private enum CodingKeys: String, CodingKey { case id, maximumRequests, expiresAt }
    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: fields.decode(String.self, forKey: .id),
                      maximumRequests: fields.decode(Int.self, forKey: .maximumRequests),
                      expiresAt: fields.decode(Date.self, forKey: .expiresAt))
    }
}

public struct DecisionsTrialStatus {
    public let reservedRequests: Int
    public let remainingRequests: Int
    public let expired: Bool
}

/// Reserve before sending. Every reservation survives failures, cancellations, and restarts.
/// Only hashes and timestamps are stored; never credentials, payloads, or conversation text.
/// All filesystem work belongs on a utility queue, outside presentation and typing.
public final class DecisionsTrialLedger {
    public static let maximumRequestBytes = 6000
    private static let maximumFileBytes = 32768
    public let url: URL
    public let configuration: DecisionsTrialConfiguration
    /// The largest body this ledger reserves. Ranking keeps the default; assessment passes its own.
    public let requestByteLimit: Int
    /// How many times one body may be reserved. One rejects every repeat. More lets a caller
    /// retry a request that failed, and each attempt still counts toward `maximumRequests`.
    public let attemptsPerRequest: Int
    private struct Reservation: Codable { let fingerprint: String; let reservedAt: Date }
    private struct State: Codable { let version: Int; let configuration: DecisionsTrialConfiguration; var reservations: [Reservation] }

    public init(url: URL, configuration: DecisionsTrialConfiguration,
                requestByteLimit: Int = DecisionsTrialLedger.maximumRequestBytes, attemptsPerRequest: Int = 1) {
        self.url = url; self.configuration = configuration
        self.requestByteLimit = min(32_000, max(1, requestByteLimit))
        self.attemptsPerRequest = min(5, max(1, attemptsPerRequest))
    }
    public func status(now: Date = Date()) throws -> DecisionsTrialStatus {
        try locked {
            let state = try read()
            return DecisionsTrialStatus(reservedRequests: state.reservations.count,
                remainingRequests: max(0, configuration.maximumRequests - state.reservations.count),
                expired: now >= configuration.expiresAt)
        }
    }
    public func reserve(body: Data, now: Date = Date()) throws {
        guard !body.isEmpty, body.count <= requestByteLimit else { throw DecisionsTrialError.oversizedRequest }
        guard now.timeIntervalSince1970.isFinite else { throw DecisionsTrialError.invalidConfiguration }
        let fingerprint = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        try locked {
            var state = try read()
            guard now < configuration.expiresAt else { throw DecisionsTrialError.expired }
            guard !state.reservations.contains(where: { $0.reservedAt > now }) else { throw DecisionsTrialError.clockMovedBackwards }
            guard state.reservations.filter({ $0.fingerprint == fingerprint }).count < attemptsPerRequest else { throw DecisionsTrialError.duplicateRequest }
            guard state.reservations.count < configuration.maximumRequests else { throw DecisionsTrialError.limitReached }
            state.reservations.append(Reservation(fingerprint: fingerprint, reservedAt: now))
            try write(state)
        }
    }
    private func read() throws -> State {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            if errno == ENOENT { return State(version: 1, configuration: configuration, reservations: []) }
            throw systemError()
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw systemError() }
        guard info.st_mode & S_IFMT == S_IFREG, (0...Self.maximumFileBytes).contains(Int(info.st_size)) else { throw DecisionsTrialError.corruptLedger }
        var data = Data(), bytes = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = bytes.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count < 0 { if errno == EINTR { continue }; throw systemError() }
            if count == 0 { break }
            guard data.count + count <= Self.maximumFileBytes else { throw DecisionsTrialError.corruptLedger }
            data.append(contentsOf: bytes.prefix(count))
        }
        guard let state = try? JSONDecoder().decode(State.self, from: data), state.version == 1,
              (1...100).contains(state.configuration.maximumRequests), state.reservations.count <= state.configuration.maximumRequests,
              Dictionary(grouping: state.reservations, by: \.fingerprint).values.allSatisfy({ $0.count <= attemptsPerRequest }),
              state.reservations.allSatisfy({ $0.fingerprint.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil && $0.reservedAt.timeIntervalSince1970.isFinite }) else {
            throw DecisionsTrialError.corruptLedger
        }
        guard state.configuration == configuration else { throw DecisionsTrialError.configurationMismatch }
        return state
    }
    private func write(_ state: State) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(state)
        guard data.count <= Self.maximumFileBytes else { throw DecisionsTrialError.corruptLedger }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".decisions-\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw systemError() }
        defer { close(descriptor); _ = unlink(temporary.path) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 { if errno == EINTR { continue }; throw systemError() }
                guard count > 0 else { throw DecisionsTrialError.corruptLedger }
                offset += count
            }
        }
        guard fsync(descriptor) == 0, rename(temporary.path, url.path) == 0 else { throw systemError() }
        let parent = open(url.deletingLastPathComponent().path, O_RDONLY | O_CLOEXEC)
        guard parent >= 0 else { throw systemError() }
        defer { close(parent) }
        guard fsync(parent) == 0 else { throw systemError() }
    }
    private func locked<T>(_ operation: () throws -> T) throws -> T {
        guard url.isFileURL else { throw DecisionsTrialError.invalidConfiguration }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let descriptor = open(url.path + ".lock", O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw systemError() }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw DecisionsTrialError.corruptLedger }
        while flock(descriptor, LOCK_EX) != 0 { if errno != EINTR { throw systemError() } }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try operation()
    }
    private func systemError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}
