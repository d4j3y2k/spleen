import Foundation
import Darwin

/// Why a bounded helper exchange ended without a protocol answer.
public enum HelperError: Error, Equatable {
    /// The executable could not be started at all.
    case launchFailed
    /// The helper exited early, or closed its output or its input.
    case unavailable
    case timeout
    case tooLarge
    case cancelled
}

public struct HelperLimits: Equatable {
    public var runtime: TimeInterval
    public var maximumOutputBytes: Int
    public var terminationGrace: TimeInterval
    public init(runtime: TimeInterval, maximumOutputBytes: Int, terminationGrace: TimeInterval = 0.5) {
        self.runtime = runtime; self.maximumOutputBytes = maximumOutputBytes; self.terminationGrace = terminationGrace
    }
    /// Usage reads: 8 seconds and 1 MB of output per helper.
    public static let usage = HelperLimits(runtime: 8, maximumOutputBytes: 1_000_000)
}

public struct HelperLaunch {
    public var executable: URL
    public var arguments: [String]
    public var environment: [String: String]
    public var workingDirectory: URL
    public init(executable: URL, arguments: [String], environment: [String: String], workingDirectory: URL) {
        self.executable = executable; self.arguments = arguments; self.environment = environment; self.workingDirectory = workingDirectory
    }
}

/// An idempotent cancel flag. Setting it from any thread never signals, waits or touches a
/// descriptor: the helper's owner sees it on its next poll tick and tears the child down.
public final class HelperCancellation {
    private let lock = NSLock()
    private var cancelled = false
    public init() {}
    public func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

private func monotonicSeconds() -> TimeInterval { TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000 }

/// One exchange with a live child: small, bounded writes and bounded line reads. Only the
/// owner thread that spawned the child uses it.
public final class HelperChannel {
    public static let maximumRequestBytes = 4096
    public let pid: pid_t
    fileprivate var input: Int32
    fileprivate let output: Int32
    private let deadline: TimeInterval
    private let limits: HelperLimits
    private let cancellation: HelperCancellation
    private var buffer: [UInt8] = []
    private var scanned = 0
    private var received = 0
    private var written = 0
    private var ended = false
    private static let tick: Int32 = 50

    fileprivate init(pid: pid_t, input: Int32, output: Int32, limits: HelperLimits, cancellation: HelperCancellation) {
        self.pid = pid; self.input = input; self.output = output; self.limits = limits; self.cancellation = cancellation
        deadline = monotonicSeconds() + limits.runtime
    }

    private func checkBounds() throws {
        if cancellation.isCancelled { throw HelperError.cancelled }
        if monotonicSeconds() >= deadline { throw HelperError.timeout }
    }

    private var remainingTick: Int32 {
        Int32(max(1, min(Double(Self.tick), (deadline - monotonicSeconds()) * 1000)))
    }

    /// Whether the leader has exited, without reaping it: its group id stays reserved until teardown.
    private func leaderExited() -> Bool {
        var info = siginfo_t()
        return waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0 && info.si_pid == pid
    }

    /// Writes one request. Requests are fixed and small, so they fit an empty pipe; the
    /// non-blocking writer still retries `EAGAIN` under the same cancel and deadline checks.
    public func send(_ data: Data) throws {
        guard input >= 0, written + data.count <= Self.maximumRequestBytes else { throw HelperError.tooLarge }
        let bytes = [UInt8](data)
        var offset = 0
        while offset < bytes.count {
            try checkBounds()
            let count = bytes[offset...].withUnsafeBufferPointer { Darwin.write(input, $0.baseAddress, $0.count) }
            if count > 0 { offset += count; continue }
            if count < 0 && errno == EINTR { continue }
            if count < 0 && errno == EAGAIN {
                var descriptor = pollfd(fd: input, events: Int16(POLLOUT), revents: 0)
                _ = poll(&descriptor, 1, remainingTick)
                continue
            }
            throw HelperError.unavailable // EPIPE: the child closed its input or exited.
        }
        written += bytes.count
    }

    /// The next newline-terminated line. Every byte counts toward the output cap, including
    /// ignored frames and a line that never ends.
    public func receiveLine() throws -> Data {
        guard let line = try receiveLine(until: nil) else { throw HelperError.timeout }
        return line
    }

    /// The next line, or nil when none completes within `seconds` (still bounded by the
    /// helper's own deadline, output cap and cancel flag).
    public func receiveLine(within seconds: TimeInterval) throws -> Data? {
        try receiveLine(until: monotonicSeconds() + max(0, seconds))
    }

    private func receiveLine(until soft: TimeInterval?) throws -> Data? {
        while true {
            if let newline = buffer[scanned...].firstIndex(of: 10) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline); scanned = 0
                return line
            }
            scanned = buffer.count
            if ended { throw HelperError.unavailable }
            try checkBounds()
            if let soft, monotonicSeconds() >= soft { return nil }
            var descriptor = pollfd(fd: output, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, remainingTick)
            if ready < 0 { if errno == EINTR { continue }; throw HelperError.unavailable }
            if ready == 0 {
                // A descendant can keep stdout open after the leader died; the leader is what answers.
                if leaderExited() { throw HelperError.unavailable }
                continue
            }
            var chunk = [UInt8](repeating: 0, count: 65_536)
            let count = chunk.withUnsafeMutableBufferPointer { Darwin.read(output, $0.baseAddress, $0.count) }
            if count < 0 { if errno == EINTR || errno == EAGAIN { continue }; throw HelperError.unavailable }
            if count == 0 { ended = true; continue } // Hangup: buffered data was drained above.
            received += count
            guard received <= limits.maximumOutputBytes else { throw HelperError.tooLarge }
            buffer.append(contentsOf: chunk[..<count])
        }
    }
}

/// Spawns, talks to and reaps one helper. Nothing else touches its pid.
public enum BoundedHelper {
    /// Runs one exchange on the calling (owner) thread. A cancelled token means no spawn.
    /// `deliver` receives the result before teardown starts, so an answer never waits for the
    /// termination grace period; it is called exactly once.
    public static func exchange<T>(_ launch: HelperLaunch, limits: HelperLimits, cancellation: HelperCancellation,
                                   lane: HelperLane? = nil,
                                   body: (HelperChannel) throws -> T,
                                   deliver: (Result<T, HelperError>) -> Void) {
        guard !cancellation.isCancelled else { deliver(.failure(.cancelled)); return }
        let channel: HelperChannel
        do { channel = try spawn(launch, limits: limits, cancellation: cancellation) }
        catch let error as HelperError { deliver(.failure(error)); return }
        catch { deliver(.failure(.launchFailed)); return }
        lane?.childStarted(channel.pid)
        let result: Result<T, HelperError>
        do { result = .success(try body(channel)) }
        catch let error as HelperError { result = .failure(error) }
        catch { result = .failure(.unavailable) }
        deliver(result)
        teardown(channel, grace: limits.terminationGrace)
        lane?.childReaped(channel.pid)
    }

    static func spawn(_ launch: HelperLaunch, limits: HelperLimits, cancellation: HelperCancellation) throws -> HelperChannel {
        var stdinPipe: [Int32] = [-1, -1], stdoutPipe: [Int32] = [-1, -1]
        guard pipe(&stdinPipe) == 0 else { throw HelperError.unavailable }
        guard pipe(&stdoutPipe) == 0 else { close(stdinPipe[0]); close(stdinPipe[1]); throw HelperError.unavailable }
        let all = stdinPipe + stdoutPipe
        // Another thread's spawn must not inherit these ends.
        for descriptor in all { _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC) }
        func closeAll() { for descriptor in all { close(descriptor) } }

        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { closeAll(); throw HelperError.unavailable }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { closeAll(); throw HelperError.unavailable }
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawn_file_actions_adddup2(&actions, stdinPipe[0], 0)
        posix_spawn_file_actions_adddup2(&actions, stdoutPipe[1], 1)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addchdir_np(&actions, launch.workingDirectory.path)
        // Own process group; default dispositions, because Spleen ignores SIGTERM and an ignored
        // disposition survives exec; an empty mask; every other descriptor closed on exec.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF |
                                                    POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)
        var defaults = sigset_t(), mask = sigset_t()
        sigemptyset(&defaults); sigemptyset(&mask)
        for signal in [SIGTERM, SIGINT, SIGPIPE, SIGHUP, SIGQUIT] { sigaddset(&defaults, signal) }
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        posix_spawnattr_setsigmask(&attributes, &mask)

        let argv = ([launch.executable.path] + launch.arguments).map { strdup($0) } + [nil]
        let envp = launch.environment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { for pointer in argv + envp { free(pointer) } }
        if cancellation.isCancelled { closeAll(); throw HelperError.cancelled }
        var pid: pid_t = 0
        let status = posix_spawn(&pid, launch.executable.path, &actions, &attributes, argv, envp)
        close(stdinPipe[0]); close(stdoutPipe[1])
        guard status == 0 else { close(stdinPipe[1]); close(stdoutPipe[0]); throw HelperError.launchFailed }
        let input = stdinPipe[1], output = stdoutPipe[0]
        _ = fcntl(input, F_SETFL, fcntl(input, F_GETFL) | O_NONBLOCK)
        _ = fcntl(input, F_SETNOSIGPIPE, 1)
        _ = fcntl(output, F_SETFL, fcntl(output, F_GETFL) | O_NONBLOCK)
        return HelperChannel(pid: pid, input: input, output: output, limits: limits, cancellation: cancellation)
    }

    /// Close stdin, SIGTERM the group, wait up to the grace period for the leader, SIGKILL the
    /// group, then reap the leader once. The leader is reaped only after the last group signal,
    /// so its group id cannot be reused while it is still being signalled.
    static func teardown(_ channel: HelperChannel, grace: TimeInterval) {
        if channel.input >= 0 { close(channel.input); channel.input = -1 }
        let pid = channel.pid
        killpg(pid, SIGTERM); kill(pid, SIGTERM)
        let end = monotonicSeconds() + grace
        var info = siginfo_t()
        while monotonicSeconds() < end {
            info = siginfo_t()
            if waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0 && info.si_pid == pid { break }
            usleep(5_000)
        }
        // Also catches descendants that ignore SIGTERM or outlived a leader that exited on it.
        killpg(pid, SIGKILL); kill(pid, SIGKILL)
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        close(channel.output)
    }
}

/// One owner per provider: at most one live child, and one replaceable pending launch that
/// starts once the previous child has been reaped.
public final class HelperLane {
    public typealias Job = (HelperLane, HelperCancellation) -> Void
    private struct Pending { let cancellation: HelperCancellation; let job: Job; let dropped: () -> Void }
    private let queue: DispatchQueue
    private let condition = NSCondition()
    private var active: HelperCancellation?
    private var pending: Pending?
    private var live = 0
    private var maximumLive = 0
    private var started: [pid_t] = []

    public init(label: String) { queue = DispatchQueue(label: label, qos: .userInitiated) }

    /// Runs `job` on the lane's owner thread now, or after the current child has been reaped.
    /// A launch still waiting is replaced, and its `dropped` callback runs instead of its job.
    public func submit(cancellation: HelperCancellation, job: @escaping Job, dropped: @escaping () -> Void) {
        condition.lock()
        if active == nil {
            active = cancellation
            condition.unlock()
            queue.async { self.run(cancellation, job) }
            return
        }
        let replaced = pending
        pending = Pending(cancellation: cancellation, job: job, dropped: dropped)
        condition.unlock()
        replaced?.cancellation.cancel()
        replaced?.dropped()
    }

    private func run(_ cancellation: HelperCancellation, _ job: @escaping Job) {
        var next: (HelperCancellation, Job)? = (cancellation, job)
        while let (token, work) = next {
            work(self, token)
            condition.lock()
            if let waiting = pending {
                pending = nil; active = waiting.cancellation; next = (waiting.cancellation, waiting.job)
            } else {
                active = nil; next = nil; condition.broadcast()
            }
            condition.unlock()
        }
    }

    /// Cancels the live exchange (the owner tears it down on its next tick) and drops a waiting launch.
    public func cancelAll() {
        condition.lock()
        let running = active, waiting = pending
        pending = nil
        condition.unlock()
        running?.cancel()
        waiting?.cancellation.cancel()
        waiting?.dropped()
    }

    /// Waits on the lane's own condition, never the main queue, so Quit can call it.
    @discardableResult public func waitUntilIdle(timeout: TimeInterval) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        condition.lock(); defer { condition.unlock() }
        while active != nil { if !condition.wait(until: end) { return active == nil } }
        return true
    }

    public var isIdle: Bool { condition.lock(); defer { condition.unlock() }; return active == nil }
    /// Test evidence: the most children this lane ever had alive at once, and their pids.
    public var maximumLiveChildren: Int { condition.lock(); defer { condition.unlock() }; return maximumLive }
    public var startedPIDs: [pid_t] { condition.lock(); defer { condition.unlock() }; return started }

    func childStarted(_ pid: pid_t) {
        condition.lock(); live += 1; maximumLive = max(maximumLive, live); started.append(pid); condition.unlock()
    }
    func childReaped(_ pid: pid_t) { condition.lock(); live -= 1; condition.unlock() }
}
