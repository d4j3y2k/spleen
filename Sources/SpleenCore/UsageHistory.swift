import Foundation

/// One window's readings over its current period, for the trend line.
public struct UsageTrend: Codable, Equatable {
    public struct Point: Codable, Equatable {
        public var at: Date
        public var usedPercent: Double
        public init(at: Date, usedPercent: Double) { self.at = at; self.usedPercent = usedPercent }
    }
    public var resetsAt: Date?
    public var durationMinutes: Int?
    public var points: [Point]
    public init(resetsAt: Date?, durationMinutes: Int?, points: [Point]) {
        self.resetsAt = resetsAt; self.durationMinutes = durationMinutes; self.points = points
    }

    /// Where the period began: the reset minus the window's length when both are known,
    /// else the first reading.
    public var start: Date? {
        if let resetsAt, let durationMinutes, durationMinutes > 0 { return resetsAt.addingTimeInterval(-Double(durationMinutes) * 60) }
        return points.first?.at
    }
    /// Whether the period's true start is known, so an even pace can be drawn from it.
    public var hasKnownStart: Bool { resetsAt != nil && (durationMinutes ?? 0) > 0 }
}

/// Percent used over time for each window's current period: timestamps and percentages
/// only, never an account identity. A window's line starts again when its reset passes or
/// its reset time moves, which is also what a different account looks like.
public struct UsageHistory: Codable, Equatable {
    public static let currentVersion = 1
    /// Two reset times this close are the same period; providers send sub-second jitter.
    public static let resetTolerance: TimeInterval = 300
    /// A window with no reset time keeps readings this long.
    public static let unanchoredLifetime: TimeInterval = 8 * 86_400
    public static let maximumPoints = 720
    public static let maximumWindows = 64

    public var version = UsageHistory.currentVersion
    public private(set) var trends: [String: UsageTrend] = [:]
    public init() {}

    public var isEmpty: Bool { trends.isEmpty }
    public func trend(for window: UsageWindow) -> UsageTrend? { trends[window.id] }

    static func samePeriod(_ a: Date?, _ b: Date?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (a?, b?): return abs(a.timeIntervalSince(b)) <= resetTolerance
        default: return false
        }
    }

    /// Adds a reading taken at `reading.checkedAt`. A run of equal values keeps only its
    /// first and latest reading, so a quiet week costs two points. Returns whether anything changed.
    @discardableResult public mutating func record(_ reading: UsageReading) -> Bool {
        let at = reading.checkedAt
        let before = trends
        for window in reading.windows where window.usedPercent.isFinite {
            let point = UsageTrend.Point(at: at, usedPercent: window.usedPercent)
            guard var trend = trends[window.id], Self.samePeriod(trend.resetsAt, window.resetsAt) else {
                if trends[window.id] == nil, trends.count >= Self.maximumWindows { continue }
                trends[window.id] = UsageTrend(resetsAt: window.resetsAt, durationMinutes: window.durationMinutes, points: [point])
                continue
            }
            guard let last = trend.points.last, at > last.at else { continue } // Late or repeated: ignored.
            trend.durationMinutes = window.durationMinutes ?? trend.durationMinutes
            let count = trend.points.count
            if count >= 2, trend.points[count - 2].usedPercent == last.usedPercent, last.usedPercent == point.usedPercent {
                trend.points[count - 1].at = at
            } else {
                trend.points.append(point)
            }
            if trend.points.count > Self.maximumPoints {
                // Thin the older half; the recent half keeps its detail.
                let half = trend.points.count / 2
                trend.points = trend.points[..<half].enumerated().filter { $0.offset % 2 == 0 }.map(\.element) + trend.points[half...]
            }
            trends[window.id] = trend
        }
        prune(at: at)
        return trends != before
    }

    /// Drops windows whose reset has passed and unanchored ones not read for a long time.
    public mutating func prune(at instant: Date) {
        trends = trends.filter { _, trend in
            if let resetsAt = trend.resetsAt { return resetsAt > instant }
            guard let last = trend.points.last else { return false }
            return instant.timeIntervalSince(last.at) <= Self.unanchoredLifetime
        }
    }

    /// Forgets one provider's windows: its account changed or signed out.
    @discardableResult public mutating func remove(prefix: String) -> Bool {
        let kept = trends.filter { !$0.key.hasPrefix(prefix) }
        guard kept.count != trends.count else { return false }
        trends = kept
        return true
    }

    // MARK: File

    public static let maximumFileBytes = 512_000

    /// The saved history, or nil when the file is missing, too large, from another version
    /// or not valid. A file that fails any check is ignored, never repaired in place.
    public static func load(from url: URL) -> UsageHistory? {
        guard let data = try? Data(contentsOf: url), data.count <= maximumFileBytes,
              let history = try? JSONDecoder().decode(UsageHistory.self, from: data),
              history.version == currentVersion, history.trends.count <= maximumWindows else { return nil }
        for trend in history.trends.values {
            guard trend.points.count <= maximumPoints * 2,
                  trend.points.allSatisfy({ $0.usedPercent.isFinite && $0.usedPercent >= 0 && $0.usedPercent <= 100 }),
                  zip(trend.points, trend.points.dropFirst()).allSatisfy({ $0.at < $1.at }) else { return nil }
        }
        return history
    }

    public func save(to url: URL) throws { try PrivateFile.write(JSONEncoder().encode(self), to: url) }
}

/// A trend laid out in the unit square for drawing: x runs from the period's start to its
/// reset, y is the share left. Only recorded readings are plotted; nothing is projected.
public struct UsageTrendPlot: Equatable {
    public struct Spot: Equatable {
        public var x: Double, y: Double
        public init(x: Double, y: Double) { self.x = x; self.y = y }
    }
    /// At least one spot, in time order. The last one is where the line stands now.
    public var line: [Spot]
    /// Whether an even pace, from all of it left at the start to none at the reset, can be drawn.
    public var hasPace: Bool
    public var start: Date
    public var end: Date

    public init?(trend: UsageTrend, now: Date) {
        guard let first = trend.points.first, let last = trend.points.last else { return nil }
        // A reading from just before a known start (reset-time jitter) is drawn at the start.
        let start = trend.start ?? first.at
        let end = trend.resetsAt ?? max(now, last.at)
        let span = end.timeIntervalSince(start)
        guard span > 0 else { return nil }
        func spot(_ at: Date, _ used: Double) -> Spot {
            Spot(x: min(1, max(0, at.timeIntervalSince(start) / span)), y: min(1, max(0, (100 - used) / 100)))
        }
        var line = trend.points.map { spot($0.at, $0.usedPercent) }
        // The latest reading holds until now.
        let current = min(max(now, last.at), end)
        if current > last.at { line.append(spot(current, last.usedPercent)) }
        self.line = line; self.hasPace = trend.hasKnownStart
        self.start = start; self.end = end
    }
}
