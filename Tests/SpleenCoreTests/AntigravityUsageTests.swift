import XCTest
@testable import SpleenCore

final class AntigravityUsageTests: XCTestCase {
    private let report = """
    Gemini Models\tWeekly Limit Remaining\t98%\t2030-03-20T12:00:00Z
    Gemini Models\tFive Hour Limit Remaining\t17%\t2030-03-16T12:00:00Z
    Claude and GPT models\tWeekly Limit Remaining\t0%\t2030-03-21T12:00:00Z
    Claude and GPT models\tFive Hour Limit Remaining\t100%\t1970-01-01T00:00:00Z
    """
    private let instant = Date(timeIntervalSince1970: 1_900_000_000)

    func testGroupsWindowsAndEpochReset() throws {
        let reading = try AntigravityUsage.reading(Data(report.utf8), checkedAt: instant).get()
        XCTAssertEqual(reading.checkedAt, instant)
        XCTAssertEqual(reading.owner.user, .unknown)
        XCTAssertEqual(reading.windows.map(\.percentLeft), [98, 17, 0, 100])
        XCTAssertEqual(reading.windows.map(\.durationMinutes), [10_080, 300, 10_080, 300])
        XCTAssertEqual(reading.windows[0].resetsAt, UsageTimestamp.parse("2030-03-20T12:00:00Z"))
        XCTAssertNil(reading.windows[3].resetsAt)
        XCTAssertEqual(Set(reading.windows.map(\.id)).count, 4)
        let changed = report.replacingOccurrences(of: "98%", with: "90%").split(separator: "\n").reversed().joined(separator: "\r\n")
        let second = try AntigravityUsage.reading(Data(changed.utf8), checkedAt: instant + 60).get()
        XCTAssertEqual(second.windows.map(\.id), reading.windows.map(\.id).reversed())
        var history = UsageHistory()
        history.record(reading)
        history.record(second)
        XCTAssertEqual(history.trend(for: reading.windows[0])?.points.map(\.usedPercent), [2, 10])
    }

    func testMalformedAndDuplicateRows() throws {
        let lines = ["unrelated text", report, report,
                     "Group\tWeekly Limit Remaining\tNaN%\t", "Group\tFive Hour Limit Remaining\t101%\t"]
        let mixed = try AntigravityUsage.reading(Data(lines.joined(separator: "\n").utf8), checkedAt: instant).get()
        XCTAssertEqual(mixed.windows.count, 4)
        XCTAssertEqual(AntigravityUsage.reading(Data(), checkedAt: instant), .failure(UsageProblem(.offlineOrEmpty)))
        XCTAssertEqual(AntigravityUsage.reading(Data("other format".utf8), checkedAt: instant), .failure(UsageProblem(.incompatible)))
    }

    func testUsageCommandRequiresSuccessfulExitAndAcceptsUnterminatedLastRow() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let agy = dir.appendingPathComponent("agy")
        // Also verify the helper closes stdin, as it would for a standalone CLI report.
        let script = """
        #!/bin/sh
        [ "$#" = 2 ] && [ "$1" = "--print" ] && [ "$2" = "/usage" ] || exit 2
        if read line; then exit 3; fi
        printf '%s' 'Gemini Models\tWeekly Limit Remaining\t87%\t2030-03-20T12:00:00Z'
        exit "$TEST_STATUS"
        """
        try script.write(to: agy, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: agy.path)
        XCTAssertEqual(AntigravityUsage.resolveExecutable(home: dir, path: dir.path)?.path, agy.path)
        let lane = HelperLane(label: "test.agy.usage")
        for status in [0, 1] {
            let finished = expectation(description: "Usage command exits with \(status)")
            let request = UsageFetchRequest(cancellation: HelperCancellation(), cachedOwner: nil) { event in
                guard case let .finished(result) = event else { return }
                if status == 0 { XCTAssertEqual(try? result.get().windows.first?.percentLeft, 87) }
                else { XCTAssertEqual(result, .failure(UsageProblem(.offlineOrEmpty))) }
                finished.fulfill()
            }
            AntigravityUsage.fetch(executable: { agy }, workingDirectory: { dir }, environment: ["TEST_STATUS": String(status)],
                                   lane: lane, request: request)
            wait(for: [finished], timeout: 3)
            XCTAssertTrue(lane.waitUntilIdle(timeout: 1))
        }
    }
}
