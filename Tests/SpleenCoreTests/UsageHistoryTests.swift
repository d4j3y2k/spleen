import XCTest
@testable import SpleenCore

/// The usage trend: what is kept, when a line starts again, and how it is laid out.
/// Every value here is invented.
final class UsageHistoryTests: XCTestCase {
    private let reset = Date(timeIntervalSince1970: 1_900_600_000)
    private var start: Date { reset.addingTimeInterval(-10_080 * 60) }
    private func reading(_ used: Double, at: Date, id: String = "codex.weekly", reset: Date?? = .none, minutes: Int? = 10_080) -> UsageReading {
        UsageReading(windows: [UsageWindow(id: id, label: "Weekly limit", usedPercent: used, resetsAt: reset ?? self.reset, durationMinutes: minutes)],
                     checkedAt: at, owner: UsageOwner(user: .unknown))
    }
    private func used(_ history: UsageHistory, _ id: String = "codex.weekly") -> [Double] { history.trends[id]?.points.map(\.usedPercent) ?? [] }

    func testARunOfEqualReadingsKeepsItsFirstAndLatest() {
        var history = UsageHistory()
        let t = start.addingTimeInterval(3600)
        for step in 0..<5 { XCTAssertTrue(history.record(reading(10, at: t.addingTimeInterval(Double(step) * 300)))) }
        XCTAssertEqual(history.trends["codex.weekly"]?.points, [.init(at: t, usedPercent: 10), .init(at: t.addingTimeInterval(1200), usedPercent: 10)])
        for step in 5..<9 { history.record(reading(11, at: t.addingTimeInterval(Double(step) * 300))) }
        XCTAssertEqual(used(history), [10, 10, 11, 11])
        XCTAssertEqual(history.trends["codex.weekly"]?.points.last?.at, t.addingTimeInterval(2400))
    }

    func testALateOrRepeatedReadingIsIgnored() {
        var history = UsageHistory()
        let t = start.addingTimeInterval(3600)
        history.record(reading(10, at: t))
        XCTAssertFalse(history.record(reading(40, at: t)))
        XCTAssertFalse(history.record(reading(40, at: t.addingTimeInterval(-60))))
        XCTAssertEqual(used(history), [10])
    }

    func testResetJitterIsTheSamePeriod() {
        var history = UsageHistory()
        history.record(reading(10, at: start.addingTimeInterval(60)))
        history.record(reading(12, at: start.addingTimeInterval(360), reset: reset.addingTimeInterval(0.4)))
        XCTAssertEqual(used(history), [10, 12])
    }

    func testAPassedResetStartsTheLineAgain() {
        var history = UsageHistory()
        history.record(reading(80, at: reset.addingTimeInterval(-600)))
        let next = reset.addingTimeInterval(10_080 * 60)
        history.record(reading(1, at: reset.addingTimeInterval(120), reset: next))
        XCTAssertEqual(used(history), [1])
        XCTAssertEqual(history.trends["codex.weekly"]?.resetsAt, next)
    }

    func testAMovedResetStartsTheLineAgain() {
        // What a different account looks like when no identity is kept: the same window, another reset.
        var history = UsageHistory()
        history.record(reading(60, at: start.addingTimeInterval(3600)))
        history.record(reading(5, at: start.addingTimeInterval(3900), reset: reset.addingTimeInterval(2 * 86_400)))
        XCTAssertEqual(used(history), [5])
        history.record(reading(6, at: start.addingTimeInterval(4200), reset: .some(nil)))
        XCTAssertEqual(used(history), [6], "a reset time that disappears is another period too")
    }

    func testExpiredAndLongUnreadWindowsAreDropped() {
        var history = UsageHistory()
        let early = reset.addingTimeInterval(-3600)
        history.record(reading(10, at: early, id: "codex.session", reset: early.addingTimeInterval(1800), minutes: 300))
        history.record(reading(10, at: early, id: "claude.unanchored", reset: .some(nil), minutes: nil))
        history.record(reading(20, at: early.addingTimeInterval(1700)))
        XCTAssertEqual(Set(history.trends.keys), ["codex.session", "claude.unanchored", "codex.weekly"])
        history.record(reading(21, at: early.addingTimeInterval(1800)))
        XCTAssertNil(history.trends["codex.session"], "a window is dropped once its reset has passed")
        history.prune(at: early.addingTimeInterval(UsageHistory.unanchoredLifetime + 1))
        XCTAssertNil(history.trends["claude.unanchored"])
    }

    func testRemovingOneProviderKeepsTheOther() {
        var history = UsageHistory()
        history.record(reading(10, at: start.addingTimeInterval(60)))
        history.record(reading(10, at: start.addingTimeInterval(60), id: "claude.weekly.all"))
        XCTAssertTrue(history.remove(prefix: "codex."))
        XCTAssertFalse(history.remove(prefix: "codex."))
        XCTAssertEqual(Array(history.trends.keys), ["claude.weekly.all"])
    }

    func testPointsAndWindowsStayBounded() {
        var history = UsageHistory()
        for step in 0..<2_000 { history.record(reading(Double(step) * 0.04, at: start.addingTimeInterval(Double(step) * 300))) }
        let points = history.trends["codex.weekly"]!.points
        XCTAssertLessThanOrEqual(points.count, UsageHistory.maximumPoints)
        XCTAssertEqual(points.first?.usedPercent, 0)
        XCTAssertEqual(points.last?.usedPercent ?? 0, 1_999 * 0.04, accuracy: 0.0001)
        XCTAssertTrue(zip(points, points.dropFirst()).allSatisfy { $0.at < $1.at })
        for index in 0..<(UsageHistory.maximumWindows + 10) { history.record(reading(1, at: start.addingTimeInterval(700_000), id: "codex.bucket\(index)")) }
        XCTAssertLessThanOrEqual(history.trends.count, UsageHistory.maximumWindows)
    }

    func testFileRoundTripIsPrivateAndABadFileIsIgnored() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("spleen-usage-history-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("usage-history.json")
        XCTAssertNil(UsageHistory.load(from: url))
        var history = UsageHistory()
        history.record(reading(10, at: start.addingTimeInterval(60)))
        history.record(reading(12.5, at: start.addingTimeInterval(360)))
        try history.save(to: url)
        XCTAssertEqual(UsageHistory.load(from: url), history)
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(mode.intValue & 0o777, 0o600)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.contains("owner") || text.contains("label"), "only window ids, times and percentages are written")

        try Data("not json".utf8).write(to: url)
        XCTAssertNil(UsageHistory.load(from: url))
        try Data(text.replacingOccurrences(of: "\"version\":1", with: "\"version\":2").utf8).write(to: url)
        XCTAssertNil(UsageHistory.load(from: url))
        try Data(text.replacingOccurrences(of: "12.5", with: "250").utf8).write(to: url)
        XCTAssertNil(UsageHistory.load(from: url), "a percentage out of range rejects the file")
        try Data(count: UsageHistory.maximumFileBytes + 1).write(to: url)
        XCTAssertNil(UsageHistory.load(from: url))
    }

    func testPlotRunsFromThePeriodStartToItsReset() throws {
        let half = start.addingTimeInterval(5_040 * 60)
        let trend = UsageTrend(resetsAt: reset, durationMinutes: 10_080,
                               points: [.init(at: start.addingTimeInterval(1_008 * 60), usedPercent: 0), .init(at: half, usedPercent: 40)])
        let plot = try XCTUnwrap(UsageTrendPlot(trend: trend, now: half.addingTimeInterval(1_008 * 60)))
        XCTAssertEqual(plot.line.map(\.x), [0.1, 0.5, 0.6].map { $0 }, "the latest reading holds until now")
        XCTAssertEqual(plot.line.map(\.y), [1, 0.6, 0.6])
        XCTAssertTrue(plot.hasPace)
        XCTAssertEqual(plot.start, start)
        XCTAssertEqual(UsageTrendPlot(trend: trend, now: half)?.line.count, 2)
        XCTAssertEqual(UsageTrendPlot(trend: trend, now: reset.addingTimeInterval(999))?.line.last?.x, 1, "never drawn past the reset")
    }

    func testPlotWithoutAKnownLengthStartsAtTheFirstReading() throws {
        let first = start.addingTimeInterval(3600)
        let trend = UsageTrend(resetsAt: reset, durationMinutes: nil, points: [.init(at: first, usedPercent: 30)])
        let plot = try XCTUnwrap(UsageTrendPlot(trend: trend, now: first))
        XCTAssertEqual(plot.line, [.init(x: 0, y: 0.7)])
        XCTAssertFalse(plot.hasPace)
        XCTAssertEqual(plot.start, first)
        XCTAssertNil(UsageTrendPlot(trend: UsageTrend(resetsAt: reset, durationMinutes: nil, points: []), now: first))
        XCTAssertNil(UsageTrendPlot(trend: UsageTrend(resetsAt: nil, durationMinutes: nil, points: [.init(at: first, usedPercent: 1)]), now: first),
                     "a single reading with no reset has no span to draw")
        let early = UsageTrend(resetsAt: reset, durationMinutes: 10_080, points: [.init(at: start.addingTimeInterval(-2), usedPercent: 0)])
        XCTAssertEqual(UsageTrendPlot(trend: early, now: start)?.line.first?.x, 0, "a reading just before the start is drawn at the start")
    }

    func testDecodersCarryEachWindowsLength() throws {
        func json(_ text: String) -> Any { try! JSONSerialization.jsonObject(with: Data(text.utf8)) }
        let codex = try CodexUsage.limits(json(#"{"rateLimits":{"limitId":"codex","primary":{"usedPercent":16,"windowDurationMins":300,"resetsAt":1899990000},"secondary":{"usedPercent":42,"windowDurationMins":10080,"resetsAt":1900000000}}}"#)).get().windows
        XCTAssertEqual(codex.map(\.durationMinutes), [300, 10_080])
        let unknown = try CodexUsage.limits(json(#"{"rateLimits":{"limitId":"codex","primary":{"usedPercent":16,"resetsAt":1899990000}}}"#)).get().windows
        XCTAssertEqual(unknown.map(\.durationMinutes), [nil])
        let claude = ClaudeUsage.windows(json(#"{"five_hour":{"utilization":5,"resets_at":"2030-03-17T12:00:00Z"},"seven_day":{"utilization":40,"resets_at":"2030-03-20T12:00:00Z"},"seven_day_opus":{"utilization":7,"resets_at":"2030-03-20T12:00:00Z"}}"#) as! [String: Any])
        XCTAssertEqual(claude.map(\.durationMinutes), [300, 10_080, 10_080])
    }
}
