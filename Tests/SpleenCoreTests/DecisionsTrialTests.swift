import XCTest
import Darwin
@testable import SpleenCore

final class DecisionsTrialTests: XCTestCase {
    let date = Date(timeIntervalSince1970: 2_000_000_000)
    func withLedger(limit: Int = 2, _ body: (DecisionsTrialLedger, URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("spleen-trial-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = try DecisionsTrialConfiguration(id: "fixture", maximumRequests: limit, expiresAt: date.addingTimeInterval(3600))
        try body(DecisionsTrialLedger(url: directory.appendingPathComponent("trial.json"), configuration: configuration), directory)
    }
    func testARepeatedBodyIsAllowedOnlyUpToItsAttemptsAndEveryAttemptCounts() throws {
        try withLedger(limit: 4) { strict, _ in
            let retrying = DecisionsTrialLedger(url: strict.url, configuration: strict.configuration, attemptsPerRequest: 2)
            let body = Data("failed once".utf8)
            try retrying.reserve(body: body, now: date)
            try retrying.reserve(body: body, now: date)
            XCTAssertThrowsError(try retrying.reserve(body: body, now: date)) { XCTAssertEqual($0 as? DecisionsTrialError, .duplicateRequest) }
            XCTAssertEqual(try retrying.status(now: date).reservedRequests, 2)
            try retrying.reserve(body: Data("another".utf8), now: date)
            try retrying.reserve(body: Data("another".utf8), now: date)
            // The allowance is spent by attempts, not by distinct bodies.
            XCTAssertThrowsError(try retrying.reserve(body: Data("fifth".utf8), now: date)) { XCTAssertEqual($0 as? DecisionsTrialError, .limitReached) }
            // A ledger that allows no repeats does not accept a file holding them.
            XCTAssertThrowsError(try strict.status(now: date)) { XCTAssertEqual($0 as? DecisionsTrialError, .corruptLedger) }
        }
    }
    func testRequestByteLimitIsPerLedger() throws {
        try withLedger { ranking, _ in
            let body = Data(repeating: 0x61, count: DecisionsTrialLedger.maximumRequestBytes + 1)
            XCTAssertThrowsError(try ranking.reserve(body: body, now: date)) { XCTAssertEqual($0 as? DecisionsTrialError, .oversizedRequest) }
            let assessment = DecisionsTrialLedger(url: ranking.url, configuration: ranking.configuration,
                                                  requestByteLimit: SessionAssessmentInput.maximumRequestBytes)
            try assessment.reserve(body: body, now: date)
            let tooLarge = Data(repeating: 0x61, count: SessionAssessmentInput.maximumRequestBytes + 1)
            XCTAssertThrowsError(try assessment.reserve(body: tooLarge, now: date)) { XCTAssertEqual($0 as? DecisionsTrialError, .oversizedRequest) }
        }
    }
    func testRequestAllowanceAndDuplicateProtectionSurviveRestart() throws {
        try withLedger { ledger, _ in
            let first = Data("first request".utf8), second = Data("second request".utf8)
            try ledger.reserve(body: first, now: date)
            let restarted = DecisionsTrialLedger(url: ledger.url, configuration: ledger.configuration)
            XCTAssertThrowsError(try restarted.reserve(body: first, now: date))
            try restarted.reserve(body: second, now: date)
            XCTAssertThrowsError(try ledger.reserve(body: Data("third request".utf8), now: date))
            XCTAssertEqual(try restarted.status(now: date).reservedRequests, 2)
            XCTAssertEqual(try restarted.status(now: date).remainingRequests, 0)
            let contents = try String(contentsOf: ledger.url)
            XCTAssertFalse(contents.contains("first request")); XCTAssertFalse(contents.contains("second request"))
        }
    }
    func testConcurrentWritersCannotExceedAllowance() throws {
        try withLedger(limit: 3) { ledger, _ in
            let lock = NSLock(); var accepted = 0
            DispatchQueue.concurrentPerform(iterations: 20) { index in
                let independent = DecisionsTrialLedger(url: ledger.url, configuration: ledger.configuration)
                do {
                    try independent.reserve(body: Data("request \(index)".utf8), now: date)
                    lock.lock(); accepted += 1; lock.unlock()
                } catch { }
            }
            XCTAssertEqual(accepted, 3)
            XCTAssertEqual(try ledger.status(now: date).remainingRequests, 0)
        }
    }
    func testExpiryClockChangesAndConfigurationCannotResetAllowance() throws {
        try withLedger { ledger, _ in
            XCTAssertThrowsError(try ledger.reserve(body: Data("expired".utf8), now: date.addingTimeInterval(3600)))
            XCTAssertEqual(try ledger.status(now: date).reservedRequests, 0)
            try ledger.reserve(body: Data("valid".utf8), now: date)
            XCTAssertThrowsError(try ledger.reserve(body: Data("clock reversal".utf8), now: date.addingTimeInterval(-1)))
            let changed = try DecisionsTrialConfiguration(id: "different", maximumRequests: 100, expiresAt: date.addingTimeInterval(7200))
            XCTAssertThrowsError(try DecisionsTrialLedger(url: ledger.url, configuration: changed).reserve(body: Data("reset attempt".utf8), now: date))
            XCTAssertEqual(try ledger.status(now: date).reservedRequests, 1)
        }
        XCTAssertThrowsError(try DecisionsTrialConfiguration(id: "bad/path", maximumRequests: 20, expiresAt: date))
        XCTAssertThrowsError(try DecisionsTrialConfiguration(id: "fixture", maximumRequests: 0, expiresAt: date))
        XCTAssertThrowsError(try JSONDecoder().decode(DecisionsTrialConfiguration.self, from: Data(#"{"id":"fixture","maximumRequests":9999,"expiresAt":2000000000}"#.utf8)))
    }
    func testCorruptOversizedAndSymlinkedLedgersArePreserved() throws {
        try withLedger { ledger, directory in
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let corrupt = Data("{corrupt".utf8); try corrupt.write(to: ledger.url)
            XCTAssertThrowsError(try ledger.reserve(body: Data("request".utf8), now: date))
            XCTAssertEqual(try Data(contentsOf: ledger.url), corrupt)
            try FileManager.default.removeItem(at: ledger.url)
            let target = directory.appendingPathComponent("untouched.json")
            try corrupt.write(to: target)
            try FileManager.default.createSymbolicLink(at: ledger.url, withDestinationURL: target)
            XCTAssertThrowsError(try ledger.reserve(body: Data("request".utf8), now: date))
            XCTAssertEqual(try Data(contentsOf: target), corrupt)
        }
        try withLedger { ledger, _ in
            XCTAssertThrowsError(try ledger.reserve(body: Data(repeating: 65, count: 6001), now: date))
            XCTAssertEqual(try ledger.status(now: date).reservedRequests, 0)
        }
    }
    func testTransportReservesBeforeSendingAndCannotRetryAcrossRestart() throws {
        try withLedger { ledger, _ in
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [DecisionsStubProtocol.self]
            let session = URLSession(configuration: config)
            defer { session.invalidateAndCancel() }
            DecisionsStubProtocol.reset()
            let transport = DecisionsHTTPTransport(approvedCredential: "synthetic-test-only", ledger: ledger, session: session)
            let received = expectation(description: "stubbed request")
            transport.send(body: Data("unique payload".utf8)) { result in
                if case .failure = result { XCTFail("stubbed request was rejected") }
                received.fulfill()
            }
            wait(for: [received], timeout: 2)
            XCTAssertEqual(DecisionsStubProtocol.requests, 1)
            XCTAssertEqual(try ledger.status().reservedRequests, 1)
            let restartedLedger = DecisionsTrialLedger(url: ledger.url, configuration: ledger.configuration)
            let restarted = DecisionsHTTPTransport(approvedCredential: "synthetic-test-only", ledger: restartedLedger, session: session)
            let denied = expectation(description: "duplicate blocked before HTTP")
            restarted.send(body: Data("unique payload".utf8)) { result in
                if case .success = result { XCTFail("duplicate was sent") }
                denied.fulfill()
            }
            wait(for: [denied], timeout: 2)
            XCTAssertEqual(DecisionsStubProtocol.requests, 1)
        }
    }
    func testTransportRejectsOversizedBodyWithoutNetworkOrReservation() throws {
        try withLedger { ledger, _ in
            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [DecisionsStubProtocol.self]
            let session = URLSession(configuration: config)
            defer { session.invalidateAndCancel() }
            DecisionsStubProtocol.reset()
            let transport = DecisionsHTTPTransport(approvedCredential: "synthetic-test-only", ledger: ledger, session: session)
            let denied = expectation(description: "oversized blocked")
            transport.send(body: Data(repeating: 65, count: 6001)) { result in
                if case .success = result { XCTFail("oversized request was sent") }
                denied.fulfill()
            }
            wait(for: [denied], timeout: 2)
            XCTAssertEqual(DecisionsStubProtocol.requests, 0)
            XCTAssertEqual(try ledger.status().reservedRequests, 0)
        }
    }
    func testNonSuccessStatusIsReportedByCodeAndKeepsItsReservation() throws {
        try withLedger { ledger, _ in
            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [DecisionsStubProtocol.self]
            let session = URLSession(configuration: config)
            defer { session.invalidateAndCancel() }
            DecisionsStubProtocol.reset(); DecisionsStubProtocol.status = 401
            defer { DecisionsStubProtocol.reset() }
            let transport = DecisionsHTTPTransport(approvedCredential: "synthetic-test-only", ledger: ledger, session: session)
            let rejected = expectation(description: "status code surfaced")
            transport.send(body: Data("rejected payload".utf8)) { result in
                if case .failure(let error) = result, let http = error as? DecisionsHTTPStatusError {
                    XCTAssertEqual(http.statusCode, 401); XCTAssertFalse(http.isTransient)
                } else { XCTFail("a non-2xx reply must surface its status code") }
                rejected.fulfill()
            }
            wait(for: [rejected], timeout: 2)
            XCTAssertEqual(DecisionsStubProtocol.requests, 1)
            XCTAssertEqual(try ledger.status().reservedRequests, 1, "a rejected request keeps its reservation")
        }
        XCTAssertTrue(DecisionsHTTPStatusError(statusCode: 429).isTransient)
        XCTAssertTrue(DecisionsHTTPStatusError(statusCode: 503).isTransient)
        XCTAssertFalse(DecisionsHTTPStatusError(statusCode: 400).isTransient)
    }
    func testCancellationWinsSynchronousResponseRaceExactlyOnce() {
        var outcomes: [Result<Data, Error>] = [], taskCancellations = 0
        let gate = DecisionsRequestGate { outcomes.append($0) }
        XCTAssertTrue(gate.install {
            taskCancellations += 1
            // Reproduce a response delivered while URLSession cancellation is in progress.
            gate.complete(.success(Data("racing response".utf8)))
        })
        gate.cancel()
        gate.complete(.success(Data("late response".utf8)))
        gate.cancel()
        XCTAssertTrue(gate.isCancelled)
        XCTAssertEqual(taskCancellations, 1)
        XCTAssertEqual(outcomes.count, 1)
        if let result = outcomes.first, case .failure(let error) = result {
            XCTAssertEqual((error as? URLError)?.code, .cancelled)
        } else { XCTFail("cancellation must claim the outcome before cancelling the task") }
    }
    func testCompletionAndPreInstallationCancellationEachDeliverOnce() {
        var responseOutcomes = 0, responseCancellations = 0
        let completed = DecisionsRequestGate { result in
            responseOutcomes += 1
            if case .failure = result { XCTFail("response already won arbitration") }
        }
        XCTAssertTrue(completed.install { responseCancellations += 1 })
        completed.complete(.success(Data()))
        completed.cancel()
        completed.complete(.failure(URLError(.cancelled)))
        XCTAssertEqual(responseOutcomes, 1)
        XCTAssertEqual(responseCancellations, 0)

        var cancelledOutcomes = 0, lateTaskCancellations = 0
        let cancelled = DecisionsRequestGate { _ in cancelledOutcomes += 1 }
        cancelled.cancel()
        XCTAssertFalse(cancelled.install { lateTaskCancellations += 1 })
        cancelled.cancel()
        XCTAssertEqual(cancelledOutcomes, 1)
        XCTAssertEqual(lateTaskCancellations, 1)
    }
    func testTrialExpiryWhileLedgerBlockedConsumesReservationWithoutStartingHTTP() throws {
        try withLedger { ledger, directory in
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let descriptor = open(ledger.url.path + ".lock", O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { XCTFail("could not open fixture lock"); return }
            var locked = false
            defer { if locked { _ = flock(descriptor, LOCK_UN) }; close(descriptor) }
            guard flock(descriptor, LOCK_EX) == 0 else { XCTFail("could not hold fixture lock"); return }
            locked = true

            let sampledBeforeReservation = expectation(description: "reservation sampled time while ledger unavailable")
            let clock = DecisionsClockFixture(date: date, firstRead: { sampledBeforeReservation.fulfill() })
            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [DecisionsStubProtocol.self]
            let session = URLSession(configuration: config)
            defer { session.invalidateAndCancel() }
            DecisionsStubProtocol.reset()
            let transport = DecisionsHTTPTransport(approvedCredential: "synthetic-test-only", ledger: ledger,
                                                   session: session, now: { clock.read() })
            let denied = expectation(description: "expired send rejected after reservation")
            transport.send(body: Data("blocked reservation fixture".utf8)) { result in
                if case .failure(let error) = result, case DecisionsTrialError.expired = error { }
                else { XCTFail("transport must report expiry after durable reservation") }
                denied.fulfill()
            }
            wait(for: [sampledBeforeReservation], timeout: 2)
            XCTAssertFalse(FileManager.default.fileExists(atPath: ledger.url.path), "no reservation can commit through the held lock")
            clock.set(ledger.configuration.expiresAt.addingTimeInterval(1))
            XCTAssertEqual(flock(descriptor, LOCK_UN), 0); locked = false
            wait(for: [denied], timeout: 2)
            XCTAssertEqual(DecisionsStubProtocol.requests, 0)
            let restarted = DecisionsTrialLedger(url: ledger.url, configuration: ledger.configuration)
            XCTAssertEqual(try restarted.status().reservedRequests, 1, "expiry must not refund a committed reservation")
        }
    }
}

final class DailyDecisionsTransportTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(identifier: "UTC")!; return value
    }
    func testDailyCapSurvivesRestartAndResetsNextDay() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("spleen-daily-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DecisionsStubProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        DecisionsStubProtocol.reset()
        // 2033-05-18 03:33 UTC
        let clock = DecisionsClockFixture(date: Date(timeIntervalSince1970: 2_000_000_000), firstRead: {})
        func transport() throws -> DailyDecisionsTransport {
            try DailyDecisionsTransport(credential: "synthetic-test-only", directory: directory, consentID: "fixture",
                                        dailyLimit: 2, calendar: calendar, session: session, now: clock.read)
        }
        func send(_ transport: DailyDecisionsTransport, _ text: String) -> Result<Data, Error> {
            let done = expectation(description: text)
            var outcome: Result<Data, Error> = .failure(URLError(.unknown))
            transport.send(body: Data(text.utf8)) { outcome = $0; done.fulfill() }
            wait(for: [done], timeout: 2)
            return outcome
        }
        let first = try transport()
        XCTAssertNoThrow(try send(first, "a").get())
        XCTAssertNoThrow(try send(first, "b").get())
        // A restart keeps today's count, and the cap applies before HTTP.
        XCTAssertThrowsError(try send(try transport(), "c").get()) { XCTAssertEqual($0 as? DecisionsTrialError, .limitReached) }
        XCTAssertEqual(DecisionsStubProtocol.requests, 2)
        clock.set(Date(timeIntervalSince1970: 2_000_000_000 + 86_400))
        XCTAssertNoThrow(try send(first, "c").get())
        XCTAssertEqual(DecisionsStubProtocol.requests, 3)
    }
    func testARequestThatFailedCanBeSentAgainAndCountsAgain() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("spleen-daily-retry-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DecisionsStubProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        DecisionsStubProtocol.reset()
        defer { DecisionsStubProtocol.reset() }
        let clock = DecisionsClockFixture(date: Date(timeIntervalSince1970: 2_000_000_000), firstRead: {})
        let transport = try DailyDecisionsTransport(credential: "synthetic-test-only", directory: directory, consentID: "fixture",
            dailyLimit: 3, calendar: calendar, session: session, now: clock.read, attemptsPerRequest: 2)
        func send(_ text: String) -> Result<Data, Error> {
            let done = expectation(description: text)
            var outcome: Result<Data, Error> = .failure(URLError(.unknown))
            transport.send(body: Data(text.utf8)) { outcome = $0; done.fulfill() }
            wait(for: [done], timeout: 2)
            return outcome
        }
        DecisionsStubProtocol.status = 503
        XCTAssertThrowsError(try send("card").get()) { XCTAssertEqual($0 as? DecisionsHTTPStatusError, DecisionsHTTPStatusError(statusCode: 503)) }
        DecisionsStubProtocol.status = 200
        // The retry reaches the network instead of being refused as a duplicate.
        XCTAssertNoThrow(try send("card").get())
        XCTAssertEqual(DecisionsStubProtocol.requests, 2)
        XCTAssertThrowsError(try send("card").get()) { XCTAssertEqual($0 as? DecisionsTrialError, .duplicateRequest) }
        // Both attempts were counted: one request is left of three.
        XCTAssertNoThrow(try send("other").get())
        XCTAssertThrowsError(try send("last").get()) { XCTAssertEqual($0 as? DecisionsTrialError, .limitReached) }
        XCTAssertEqual(DecisionsStubProtocol.requests, 3)
    }
    func testDayKeysFollowTheCalendarAndInvalidSetupsAreRejected() {
        XCTAssertEqual(DailyDecisionsTransport.day(for: Date(timeIntervalSince1970: 2_000_000_000), calendar: calendar), "2033-05-18")
        let directory = FileManager.default.temporaryDirectory
        for (id, limit) in [("fixture", 0), ("fixture", 101), ("", 5), ("bad/id", 5)] {
            XCTAssertThrowsError(try DailyDecisionsTransport(credential: "synthetic-test-only", directory: directory, consentID: id, dailyLimit: limit), "\(id) \(limit)")
        }
    }
    func testPruneRemovesOnlyThisConsentsOlderLedgers() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("spleen-prune-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let names = ["fixture-2033-05-16.json", "fixture-2033-05-16.json.lock", "fixture-2033-05-17.json", "fixture-2033-05-18.json",
                     "other-2033-05-16.json", "fixture-2033-05-16.json.bak", "fixture-notes.json"]
        for name in names { try Data().write(to: directory.appendingPathComponent(name)) }
        DailyDecisionsTransport.pruneLedgers(in: directory, consentID: "fixture", keepingFrom: "2033-05-17")
        let remaining = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
        XCTAssertEqual(remaining, ["fixture-2033-05-17.json", "fixture-2033-05-18.json", "other-2033-05-16.json",
                                   "fixture-2033-05-16.json.bak", "fixture-notes.json"])
    }
}

private final class DecisionsClockFixture {
    private let lock = NSLock()
    private var date: Date
    private var firstRead: (() -> Void)?
    init(date: Date, firstRead: @escaping () -> Void) { self.date = date; self.firstRead = firstRead }
    func read() -> Date {
        lock.lock(); let result = date, notify = firstRead; firstRead = nil; lock.unlock()
        notify?()
        return result
    }
    func set(_ value: Date) { lock.lock(); date = value; lock.unlock() }
}

private final class DecisionsStubProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var count = 0, code = 200
    static var requests: Int { lock.lock(); defer { lock.unlock() }; return count }
    /// HTTP status the stub replies with; reset() restores 200.
    static var status: Int {
        get { lock.lock(); defer { lock.unlock() }; return code }
        set { lock.lock(); code = newValue; lock.unlock() }
    }
    static func reset() { lock.lock(); count = 0; code = 200; lock.unlock() }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.count += 1; Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{\"answers\":[]}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
