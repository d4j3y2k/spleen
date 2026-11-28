import Foundation
import CryptoKit

/// One subscription window a provider reported, in percent used.
public struct UsageWindow: Equatable, Identifiable {
    public var id: String
    public var label: String
    public var usedPercent: Double
    public var resetsAt: Date?
    /// The window's length when the provider states it or its kind fixes it; the trend line
    /// starts its period this long before the reset.
    public var durationMinutes: Int?
    public init(id: String, label: String, usedPercent: Double, resetsAt: Date?, durationMinutes: Int? = nil) {
        self.id = id; self.label = label; self.usedPercent = usedPercent; self.resetsAt = resetsAt
        self.durationMinutes = durationMinutes
    }
    /// One convention everywhere: percent left. The native surfaces floor percent used, so
    /// 0.4 % used reads as 100 % left there and here.
    public var percentLeft: Int { max(0, min(100, 100 - Int(usedPercent.rounded(.down)))) }
    /// A window whose reset has passed (at the boundary too) is expired until a new read.
    public func isExpired(at instant: Date) -> Bool { resetsAt.map { $0 <= instant } ?? false }

    /// A finite percentage in 0…100 after clamping a tiny overshoot; anything else drops the window.
    public static func percent(_ raw: Any?) -> Double? {
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        guard value.isFinite, value >= -0.5, value <= 100.5 else { return nil }
        return min(100, max(0, value))
    }
}

/// A person identified by email or a provider-issued user id (an in-memory hash, never stored).
/// Organization is secondary: compared only when both sides supply it.
public struct UsagePerson: Equatable {
    public var key: String
    public var organization: String?
    public init(key: String, organization: String? = nil) { self.key = key; self.organization = organization }
}

public enum UsageIdentity: Equatable {
    case known(UsagePerson)
    case signedOut
    case unknown

    /// In-memory only; the inputs are never logged or written.
    public static func hash(_ parts: [String]) -> String {
        SHA256.hash(data: Data(parts.joined(separator: "\u{1F}").utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}

/// Who a reading belongs to. `user` and `snapshot` are different kinds and are never compared
/// with each other: the signed-in user, and the owner a Codex usage snapshot names.
public struct UsageOwner: Equatable {
    public var user: UsageIdentity
    public var snapshot: String?
    public init(user: UsageIdentity, snapshot: String? = nil) { self.user = user; self.snapshot = snapshot }
}

public struct UsageReading: Equatable {
    public var windows: [UsageWindow]
    /// When Spleen asked the client. A client can answer from its own recent snapshot.
    public var checkedAt: Date
    public var owner: UsageOwner
    public init(windows: [UsageWindow], checkedAt: Date, owner: UsageOwner) {
        self.windows = windows; self.checkedAt = checkedAt; self.owner = owner
    }
}

public enum UsageFailure: Error, Equatable {
    case missingClient, signedOut, noSubscriptionLimits, offlineOrEmpty, timeout, incompatible
    /// The account changed while this read was in flight, so its answer could belong to either.
    case accountChanged
    case cancelled
}

public struct UsageProblem: Error, Equatable {
    public var failure: UsageFailure
    /// Only set from a provider field with an established unit.
    public var retryAfter: Date?
    public init(_ failure: UsageFailure, retryAfter: Date? = nil) { self.failure = failure; self.retryAfter = retryAfter }
}

public enum UsageEvent: Equatable {
    /// The identity a client reported, as soon as it is known and before its usage answer.
    case identity(UsageIdentity)
    case finished(Result<UsageReading, UsageProblem>)
}

/// What a provider read needs from its requester. `emit` may be called on any thread.
public struct UsageFetchRequest {
    public let cancellation: HelperCancellation
    public let cachedOwner: UsageOwner?
    public let emit: (UsageEvent) -> Void
    public init(cancellation: HelperCancellation, cachedOwner: UsageOwner?, emit: @escaping (UsageEvent) -> Void) {
        self.cancellation = cancellation; self.cachedOwner = cachedOwner; self.emit = emit
    }
}

public enum UsageIdentityRules {
    /// Only a confirmed change drops a cache: a sign-out, or two known people that differ
    /// (or the same person in two organizations, when both sides name one). `unknown` on
    /// either side changes nothing.
    public static func confirmsChange(cached: UsageIdentity, observed: UsageIdentity) -> Bool {
        switch (cached, observed) {
        case (_, .signedOut): return true
        case let (.known(old), .known(new)):
            if old.key != new.key { return true }
            if let a = old.organization, let b = new.organization { return a != b }
            return false
        default: return false
        }
    }
    /// Snapshot owners are compared only with snapshot owners, and only when both are named.
    public static func snapshotChanged(cached: String?, observed: String?) -> Bool {
        guard let cached, let observed else { return false }
        return cached != observed
    }
}

public enum UsageLabels {
    /// From the window's actual duration; never from its slot name.
    public static func duration(minutes: Int?) -> String {
        guard let minutes, minutes > 0 else { return "Usage limit" }
        switch minutes {
        case 300: return "5-hour limit"
        case 1440: return "Daily limit"
        case 10080: return "Weekly limit"
        default:
            if minutes % 1440 == 0 { return "\(minutes / 1440)-day limit" }
            if minutes % 60 == 0 { return "\(minutes / 60)-hour limit" }
            return "\(minutes)-minute limit"
        }
    }
    /// A server-supplied name, kept short and printable.
    public static func displayName(_ raw: Any?) -> String? {
        guard let text = raw as? String else { return nil }
        let cleaned = String(text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : String(cleaned.prefix(48))
    }
}

/// Local, locale-aware text for reset and check times. Reset instants are shown as the
/// provider sent them: never shifted, rounded up or derived from a window's length.
public struct UsageTimeFormat {
    public let locale: Locale
    public let timeZone: TimeZone
    public init(locale: Locale = .autoupdatingCurrent, timeZone: TimeZone = .autoupdatingCurrent) {
        self.locale = locale; self.timeZone = timeZone
    }
    private func formatter(_ template: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale; formatter.timeZone = timeZone
        formatter.dateFormat = DateFormatter.dateFormat(fromTemplate: template, options: 0, locale: locale)
        return formatter
    }
    private func sameYear(_ a: Date, _ b: Date) -> Bool {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        return calendar.component(.year, from: a) == calendar.component(.year, from: b)
    }
    /// The exact local date and minute, always with the date: "Tue, Nov 24 at 2:59 PM".
    /// The year is added when it is not the current one.
    public func reset(_ date: Date, now: Date, spoken: Bool = false) -> String {
        let year = sameYear(date, now) ? "" : "y"
        return formatter((spoken ? "EEEEMMMMd" : "EEEMMMd") + year + "jmm").string(from: date)
    }
    /// The full instant with seconds and time zone, for the tooltip and accessibility value.
    public func precise(_ date: Date) -> String { formatter("EEEEMMMMdyjmmsszzzz").string(from: date) }
    public func time(_ date: Date) -> String { formatter("jmm").string(from: date) }

    /// How long from `now`, counted down in whole units: "in 2 d 4 h", "in 5 h 12 min",
    /// "in 37 min", "in under a minute".
    public func relative(to date: Date, now: Date, spoken: Bool = false) -> String {
        let left = date.timeIntervalSince(now)
        guard left >= 60 else { return "in under a minute" }
        let total = Int(left / 60) // Whole minutes left, never rounded up.
        let days = total / 1440, hours = total % 1440 / 60, minutes = total % 60
        func unit(_ value: Int, _ short: String, _ long: String) -> String {
            spoken ? "\(value) \(long)\(value == 1 ? "" : "s")" : "\(value) \(short)"
        }
        if days > 0 { return "in " + ([unit(days, "d", "day")] + (hours > 0 ? [unit(hours, "h", "hour")] : [])).joined(separator: " ") }
        if hours > 0 { return "in " + ([unit(hours, "h", "hour")] + (minutes > 0 ? [unit(minutes, "min", "minute")] : [])).joined(separator: " ") }
        return "in " + unit(minutes, "min", "minute")
    }

    /// The next instant at which a reset's relative text or expiry changes: whole minutes
    /// counted back from the reset itself, so the countdown is exact rather than up to a
    /// minute late. Nil once the reset has passed.
    public static func nextChange(for reset: Date, after now: Date) -> Date? {
        let left = reset.timeIntervalSince(now)
        guard left > 0 else { return nil }
        let step = left.truncatingRemainder(dividingBy: 60)
        return now.addingTimeInterval(step > 0 ? step : 60)
    }
}

/// The ISO 8601 timestamps Claude sends, with or without fractional seconds.
public enum UsageTimestamp {
    public static func parse(_ raw: Any?) -> Date? {
        guard let text = raw as? String, !text.isEmpty, text.count <= 64 else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        let whole = ISO8601DateFormatter()
        whole.formatOptions = [.withInternetDateTime]
        if let date = whole.date(from: text) { return date }
        // Microsecond fractions ("…59.915702+00:00") are wider than the formatter accepts.
        if let dot = text.firstIndex(of: "."),
           let end = text[dot...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) {
            let digits = text[text.index(after: dot)..<end]
            guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return nil }
            let trimmed = text[..<dot] + "." + digits.prefix(3) + text[end...]
            return fractional.date(from: String(trimmed))
        }
        return nil
    }
}

/// Locate installed clients for a menu-bar app, whose PATH may lack the shell's additions.
enum UsageExecutable {
    static func candidates(_ name: String, local: [String], path: String?) -> [String] {
        var list = local
        for directory in (path ?? "").split(separator: ":") where directory.hasPrefix("/") {
            list.append(URL(fileURLWithPath: String(directory)).appendingPathComponent(name).path)
        }
        list += ["/opt/homebrew/bin/" + name, "/usr/local/bin/" + name]
        var seen = Set<String>()
        return list.filter { seen.insert($0).inserted }
    }

    static func resolve(_ candidates: [String]) -> URL? {
        for candidate in candidates {
            let resolved = URL(fileURLWithPath: candidate).resolvingSymlinksInPath().path
            guard let type = try? FileManager.default.attributesOfItem(atPath: resolved)[.type] as? FileAttributeType,
                  type == .typeRegular, FileManager.default.isExecutableFile(atPath: resolved) else { continue }
            return URL(fileURLWithPath: candidate)
        }
        return nil
    }
}
