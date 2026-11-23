import XCTest
import Darwin
@testable import SpleenCore

/// Real stand-in processes. Each case checks that the helper and its descendant are gone.
final class HelperProcessTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("spleen-helper-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private func script(_ body: String, name: String = UUID().uuidString) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        chmod(url.path, 0o755)
        return url
    }
    private func launch(_ executable: URL) -> HelperLaunch {
        HelperLaunch(executable: executable, arguments: [], environment: ["PATH": "/usr/bin:/bin"], workingDirectory: directory)
    }
    private func gone(_ pid: pid_t, within seconds: TimeInterval = 2) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        repeat {
            if kill(pid, 0) == -1 && errno == ESRCH { return true }
            usleep(10_000)
        } while Date() < end
        return false
    }
    private func pid(_ line: Data, _ prefix: String) -> pid_t? {
        let text = String(decoding: line, as: UTF8.self)
        guard text.hasPrefix(prefix + " ") else { return nil }
        return pid_t(text.dropFirst(prefix.count + 1))
    }

    private struct Run<T> { var result: Result<T, HelperError>?; var deliveredAt: TimeInterval = 0; var finishedAt: TimeInterval = 0; var deliveries = 0 }
    private func exchange<T>(_ executable: URL, limits: HelperLimits = HelperLimits(runtime: 5, maximumOutputBytes: 1_000_000),
                             cancellation: HelperCancellation = HelperCancellation(), lane: HelperLane? = nil,
                             body: (HelperChannel) throws -> T) -> Run<T> {
        var run = Run<T>()
        BoundedHelper.exchange(launch(executable), limits: limits, cancellation: cancellation, lane: lane, body: body) {
            run.result = $0; run.deliveries += 1; run.deliveredAt = ProcessInfo.processInfo.systemUptime
        }
        run.finishedAt = ProcessInfo.processInfo.systemUptime
        return run
    }

    private let announcing = """
    echo "pid $$"
    sleep 30 &
    echo "child $!"
    """

    func testNormalReplyArrivesBeforeTeardownAndEverythingIsReaped() throws {
        // Ignoring SIGTERM makes teardown take the whole grace period, so delivery order is visible.
        let executable = try script("trap '' TERM\n" + announcing + "\nread request\necho \"reply $request\"\nsleep 30")
        var leader: pid_t?, child: pid_t?
        let run = exchange(executable) { channel -> String in
            leader = self.pid(try channel.receiveLine(), "pid"); child = self.pid(try channel.receiveLine(), "child")
            try channel.send(Data("ping\n".utf8))
            return String(decoding: try channel.receiveLine(), as: UTF8.self)
        }
        XCTAssertEqual(try run.result?.get(), "reply ping")
        XCTAssertEqual(run.deliveries, 1)
        XCTAssertLessThan(run.deliveredAt, run.finishedAt - 0.35, "the reply is delivered before the termination grace period")
        XCTAssertTrue(try gone(XCTUnwrap(leader)) && gone(XCTUnwrap(child)))
    }

    func testSilenceTimesOut() throws {
        let executable = try script(announcing + "\nsleep 30")
        var leader: pid_t?, child: pid_t?
        let start = ProcessInfo.processInfo.systemUptime
        let run = exchange(executable, limits: HelperLimits(runtime: 0.6, maximumOutputBytes: 1000)) { channel -> Data in
            leader = self.pid(try channel.receiveLine(), "pid"); child = self.pid(try channel.receiveLine(), "child")
            return try channel.receiveLine()
        }
        XCTAssertEqual(run.result?.failureValue, .timeout)
        XCTAssertLessThan(run.finishedAt - start, 2)
        XCTAssertTrue(try gone(XCTUnwrap(leader)) && gone(XCTUnwrap(child)))
    }

    func testOutputOverTheCapWithoutNewline() throws {
        let marker = directory.appendingPathComponent("pid")
        let executable = try script("echo $$ > \(marker.path)\nhead -c 3000000 /dev/zero | tr '\\0' 'a'\nsleep 30")
        let run = exchange(executable, limits: HelperLimits(runtime: 5, maximumOutputBytes: 1_000_000)) { try $0.receiveLine() }
        XCTAssertEqual(run.result?.failureValue, .tooLarge)
        let leader = try XCTUnwrap(pid_t(String(contentsOf: marker).trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertTrue(gone(leader))
    }

    func testFloodOfIrrelevantFramesCountsTowardTheCap() throws {
        let marker = directory.appendingPathComponent("pid")
        let executable = try script("echo $$ > \(marker.path)\nyes '{\"type\":\"noise\"}'")
        var ignored = 0
        let run = exchange(executable, limits: HelperLimits(runtime: 5, maximumOutputBytes: 200_000)) { channel -> Data in
            while true {
                let line = try channel.receiveLine()
                if !line.starts(with: Data("{\"type\":\"noise\"".utf8)) { return line }
                ignored += 1
            }
        }
        XCTAssertEqual(run.result?.failureValue, .tooLarge)
        XCTAssertGreaterThan(ignored, 1000)
        let leader = try XCTUnwrap(pid_t(String(contentsOf: marker).trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertTrue(gone(leader))
    }

    func testEarlyExitBeforeTheWriteIsABrokenPipeNotASignal() throws {
        let executable = try script("exec 0<&-\necho \"pid $$\"\nsleep 0.3")
        var leader: pid_t?
        let run = exchange(executable) { channel -> Void in
            leader = self.pid(try channel.receiveLine(), "pid")
            usleep(50_000)
            try channel.send(Data("request\n".utf8))
        }
        XCTAssertEqual(run.result?.failureValue, .unavailable)
        XCTAssertTrue(gone(try XCTUnwrap(leader)))
        let quick = try script("exit 0")
        let eof = exchange(quick) { try $0.receiveLine() }
        XCTAssertEqual(eof.result?.failureValue, .unavailable)
    }

    func testChildIgnoringSIGTERMIsKilled() throws {
        let executable = try script("trap '' TERM\n" + announcing + "\nsleep 30")
        var leader: pid_t?, child: pid_t?
        let run = exchange(executable) { channel -> Void in
            leader = self.pid(try channel.receiveLine(), "pid"); child = self.pid(try channel.receiveLine(), "child")
        }
        XCTAssertNotNil(try? run.result?.get())
        XCTAssertTrue(try gone(XCTUnwrap(leader)) && gone(XCTUnwrap(child)))
    }

    func testDescendantHoldingStdoutOpenDoesNotKeepTheReadAlive() throws {
        let executable = try script(announcing + "\nexit 0")
        var child: pid_t?
        let start = ProcessInfo.processInfo.systemUptime
        let run = exchange(executable) { channel -> Data in
            _ = try channel.receiveLine(); child = self.pid(try channel.receiveLine(), "child")
            return try channel.receiveLine()
        }
        XCTAssertEqual(run.result?.failureValue, .unavailable)
        XCTAssertLessThan(run.finishedAt - start, 2, "the leader's exit ends the read before the deadline")
        XCTAssertTrue(gone(try XCTUnwrap(child)))
    }

    func testCancelBeforeSpawnStartsNothing() throws {
        let marker = directory.appendingPathComponent("spawned")
        let executable = try script("touch \(marker.path)\nsleep 30")
        let token = HelperCancellation(); token.cancel(); token.cancel()
        let lane = HelperLane(label: "test.cancel-before")
        let run = exchange(executable, cancellation: token, lane: lane) { try $0.receiveLine() }
        XCTAssertEqual(run.result?.failureValue, .cancelled)
        usleep(100_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertTrue(lane.startedPIDs.isEmpty)
    }

    func testCancelRacingSpawnAndMidRead() throws {
        let executable = try script("sleep 30")
        let lane = HelperLane(label: "test.race")
        for attempt in 0..<12 {
            let token = HelperCancellation()
            let finished = expectation(description: "finished \(attempt)")
            var outcome: Result<Data, HelperError>?
            lane.submit(cancellation: token, job: { lane, cancellation in
                BoundedHelper.exchange(self.launch(executable), limits: HelperLimits(runtime: 5, maximumOutputBytes: 1000),
                                       cancellation: cancellation, lane: lane, body: { try $0.receiveLine() }) { outcome = $0 }
                finished.fulfill()
            }, dropped: { XCTFail("nothing was replaced") })
            if attempt % 2 == 1 { usleep(useconds_t(attempt * 15_000)) } // Racing the spawn, then mid-read.
            let cancelledAt = ProcessInfo.processInfo.systemUptime
            token.cancel()
            wait(for: [finished], timeout: 3)
            XCTAssertEqual(outcome?.failureValue, .cancelled)
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - cancelledAt, 1)
        }
        XCTAssertTrue(lane.waitUntilIdle(timeout: 2))
        XCTAssertEqual(lane.maximumLiveChildren, 1)
        for pid in lane.startedPIDs { XCTAssertTrue(gone(pid)) }
    }

    func testCancelRacingTeardownChangesNothing() throws {
        let executable = try script("trap '' TERM\necho ready\nsleep 30")
        let token = HelperCancellation()
        let lane = HelperLane(label: "test.teardown")
        var deliveries = 0
        let done = expectation(description: "done")
        lane.submit(cancellation: token, job: { lane, cancellation in
            BoundedHelper.exchange(self.launch(executable), limits: HelperLimits(runtime: 5, maximumOutputBytes: 1000),
                                   cancellation: cancellation, lane: lane, body: { try $0.receiveLine() }) { _ in
                deliveries += 1
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { token.cancel() } // During the grace period.
            }
            done.fulfill()
        }, dropped: {})
        wait(for: [done], timeout: 3)
        XCTAssertEqual(deliveries, 1)
        XCTAssertTrue(lane.isIdle)
        for pid in lane.startedPIDs { XCTAssertTrue(gone(pid)) }
    }

    func testRepeatedStartCancelReplacesThePendingLaunch() throws {
        let markers = directory.appendingPathComponent("markers")
        try FileManager.default.createDirectory(at: markers, withIntermediateDirectories: true)
        let lane = HelperLane(label: "test.pending")
        var dropped = 0, ran: [Int] = []
        let lock = NSLock()
        for round in 0..<6 {
            let tokens = (0..<3).map { _ in HelperCancellation() }
            let last = expectation(description: "round \(round)")
            for (index, token) in tokens.enumerated() {
                let name = "\(round)-\(index)"
                let executable = try script("touch \(markers.appendingPathComponent(name).path)\nsleep 30", name: "s\(name)")
                lane.submit(cancellation: token, job: { lane, cancellation in
                    BoundedHelper.exchange(self.launch(executable), limits: HelperLimits(runtime: 5, maximumOutputBytes: 1000),
                                           cancellation: cancellation, lane: lane, body: { try $0.receiveLine() }) { _ in }
                    lock.lock(); ran.append(index); lock.unlock()
                    if index == 2 { last.fulfill() }
                }, dropped: { lock.lock(); dropped += 1; lock.unlock() })
            }
            tokens[0].cancel()     // The first is live; the second was replaced by the third while pending.
            usleep(150_000)
            tokens[2].cancel()
            wait(for: [last], timeout: 4)
            XCTAssertFalse(FileManager.default.fileExists(atPath: markers.appendingPathComponent("\(round)-1").path),
                           "a replaced pending launch never spawns")
        }
        XCTAssertTrue(lane.waitUntilIdle(timeout: 2))
        XCTAssertEqual(dropped, 6)
        XCTAssertEqual(ran.filter { $0 == 1 }.count, 0)
        XCTAssertEqual(lane.maximumLiveChildren, 1, "never more than one live child per provider")
        for pid in lane.startedPIDs { XCTAssertTrue(gone(pid)) }
    }

    func testRequestsAreBoundedToOneSmallWrite() throws {
        let executable = try script("sleep 30")
        let run = exchange(executable) { try $0.send(Data(repeating: 65, count: HelperChannel.maximumRequestBytes + 1)) }
        XCTAssertEqual(run.result?.failureValue, .tooLarge)
    }

    func testMissingExecutableIsALaunchFailure() {
        let run = exchange(directory.appendingPathComponent("missing")) { try $0.receiveLine() }
        XCTAssertEqual(run.result?.failureValue, .launchFailed)
    }

    func testChildStartsWithDefaultSignalsInItsOwnGroupAndNeutralDirectory() throws {
        // The test runner may ignore SIGTERM; the child must not inherit that.
        let previous = signal(SIGTERM, SIG_IGN)
        defer { signal(SIGTERM, previous) }
        let executable = try script("echo \"$(pwd -P)\"\necho \"pgid $(ps -o pgid= -p $$ | tr -d ' ') $$\"\nexec sleep 30")
        var lines: [String] = []
        var leader: pid_t = 0
        let run = exchange(executable) { channel -> Void in
            leader = channel.pid
            lines = [String(decoding: try channel.receiveLine(), as: UTF8.self), String(decoding: try channel.receiveLine(), as: UTF8.self)]
            let start = ProcessInfo.processInfo.systemUptime
            kill(channel.pid, SIGTERM)
            // Still alive after SIGTERM would mean the ignored disposition leaked through exec.
            while kill(channel.pid, 0) == 0 && ProcessInfo.processInfo.systemUptime - start < 1 {
                var info = siginfo_t()
                if waitid(P_PID, id_t(channel.pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0 && info.si_pid == channel.pid { break }
                usleep(10_000)
            }
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 0.9, "SIGTERM has its default action in the child")
        }
        XCTAssertNotNil(try? run.result?.get())
        XCTAssertEqual(lines.first.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }, directory.resolvingSymlinksInPath().path)
        let parts = lines.last?.split(separator: " ") ?? []
        XCTAssertEqual(parts.count, 3)
        if parts.count == 3 { XCTAssertEqual(parts[1], parts[2], "the child leads its own process group") }
        XCTAssertTrue(gone(leader))
    }
}
