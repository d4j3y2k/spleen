import Foundation

/// A standing opt-in with a daily request cap. Each local calendar day gets its own
/// durable ledger, so the cap survives restarts and resets at midnight.
/// Credentials are supplied by the caller; nothing is discovered here.
public final class DailyDecisionsTransport: DecisionsTransport {
    public let dailyLimit: Int
    private let credential: String
    private let directory: URL
    private let consentID: String
    private let calendar: Calendar
    private let session: URLSession?
    private let now: () -> Date
    private let requestTimeout: TimeInterval
    private let lock = NSLock()
    /// Yesterday's transport stays alive so a request in flight at midnight isn't cancelled.
    private var transports: [String: DecisionsHTTPTransport] = [:]

    public init(credential: String, directory: URL, consentID: String, dailyLimit: Int = 100,
                calendar: Calendar = .current, session: URLSession? = nil,
                now: @escaping () -> Date = Date.init, requestTimeout: TimeInterval = 5) throws {
        guard (1...100).contains(dailyLimit), !consentID.isEmpty, consentID.utf8.count <= 60,
              consentID.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil,
              directory.isFileURL else { throw DecisionsTrialError.invalidConfiguration }
        self.credential = credential; self.directory = directory; self.consentID = consentID
        self.dailyLimit = dailyLimit; self.calendar = calendar; self.session = session
        self.now = now; self.requestTimeout = requestTimeout
    }

    /// Local calendar day as yyyy-MM-dd, which also sorts chronologically.
    public static func day(for date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    @discardableResult public func send(body: Data, completion: @escaping (Result<Data, Error>) -> Void) -> (() -> Void) {
        let transport: DecisionsHTTPTransport
        do { transport = try current() } catch { completion(.failure(error)); return {} }
        return transport.send(body: body, completion: completion)
    }

    private func current() throws -> DecisionsHTTPTransport {
        let instant = now()
        guard instant.timeIntervalSince1970.isFinite else { throw DecisionsTrialError.invalidConfiguration }
        let start = calendar.startOfDay(for: instant)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { throw DecisionsTrialError.invalidConfiguration }
        let today = Self.day(for: instant, calendar: calendar)
        let yesterday = Self.day(for: start.addingTimeInterval(-1), calendar: calendar)
        lock.lock(); defer { lock.unlock() }
        if let existing = transports[today] { return existing }
        let configuration = try DecisionsTrialConfiguration(id: "\(consentID)-\(today)", maximumRequests: dailyLimit, expiresAt: end)
        let ledger = DecisionsTrialLedger(url: directory.appendingPathComponent("\(consentID)-\(today).json"), configuration: configuration)
        let transport = DecisionsHTTPTransport(approvedCredential: credential, ledger: ledger, session: session,
                                               now: now, requestTimeout: requestTimeout)
        transports = transports.filter { $0.key >= yesterday }
        transports[today] = transport
        let directory = directory, consentID = consentID
        DispatchQueue.global(qos: .utility).async {
            Self.pruneLedgers(in: directory, consentID: consentID, keepingFrom: yesterday)
        }
        return transport
    }

    /// Removes this consent's ledgers (and their lock files) for days before `keepingFrom`.
    /// Only exact `<consentID>-yyyy-MM-dd.json[.lock]` names are touched.
    static func pruneLedgers(in directory: URL, consentID: String, keepingFrom day: String) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        let prefix = consentID + "-"
        for name in names where name.hasPrefix(prefix) {
            let rest = name.dropFirst(prefix.count)
            guard rest.hasSuffix(".json") || rest.hasSuffix(".json.lock") else { continue }
            let date = String(rest.prefix(10))
            guard date.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) != nil,
                  [".json", ".json.lock"].contains(String(rest.dropFirst(10))), date < day else { continue }
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}
