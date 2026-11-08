import XCTest
@testable import SpleenCore

final class AccessibilityExposureRetryTests: XCTestCase {
    func testBoundedBackoff() {
        var retry = AccessibilityExposureRetry()
        for time in [0.0, 0.5, 1.5, 3.5] {
            XCTAssertTrue(retry.shouldAttempt(at: time))
            retry.record(.transientFailure, at: time)
            XCTAssertFalse(retry.shouldAttempt(at: time))
        }
        XCTAssertEqual(retry.attempts, 4)
        XCTAssertFalse(retry.shouldAttempt(at: 1_000))
    }
    func testSuccessAndUnsupportedAreTerminal() {
        for outcome in [AccessibilityExposureRetry.Outcome.succeeded, .unsupported] {
            var retry = AccessibilityExposureRetry()
            retry.record(outcome, at: 0)
            XCTAssertFalse(retry.shouldAttempt(at: 100))
            retry.record(.transientFailure, at: 100)
            XCTAssertEqual(retry.attempts, 1)
        }
    }
    func testEarlyCallsDoNotConsumeBudget() {
        var retry = AccessibilityExposureRetry()
        retry.record(.transientFailure, at: 10)
        retry.record(.transientFailure, at: 10.2)
        XCTAssertEqual(retry.attempts, 1)
        XCTAssertFalse(retry.shouldAttempt(at: 10.49))
        XCTAssertTrue(retry.shouldAttempt(at: 10.5))
    }
}
