import Foundation
import XCTest
import SpleenCore
@testable import SpleenEvaluation

final class RankingReplayTests: XCTestCase {
    let anchor = Date(timeIntervalSince1970: 2_000_000_000)
    func evidence(_ count: Int = 5, pins: Int = 0) -> ReplayEvidence {
        var state = SavedState()
        state.destinations = (0..<count).map {
            Destination(title: "Fixture task \($0)", threadID: "thr_fixture_\($0)", pinned: $0 < pins)
        }
        return ReplayEvidence(state: state, anchorDate: anchor)
    }
    func target(_ index: Int) -> ConversationKey { ConversationKey(provider: .codex, id: "thr_fixture_\(index)") }
    func suite(_ item: ReplayCase) -> ReplaySuite { ReplaySuite(evidenceKind: .synthetic, cases: [item]) }
    func item(_ recipe: ReplayResponse, evidence value: ReplayEvidence? = nil, target index: Int = 3,
              delay: Double? = 0.2, validation: Double = 0, at: Double = 1) -> ReplayCase {
        ReplayCase(evidence: value ?? evidence(), attempts: [ReplayAttempt(responseAfter: delay, validationDelay: validation, response: recipe)],
            opens: [ReplayOpen(at: at, closeAt: at + 0.1, target: target(index))])
    }
    func raw(choice: String, probabilities: [Double]) throws -> ReplayResponse {
        let rows: [[String: Any]] = probabilities.enumerated().map {
            ["value": $0.offset == probabilities.count - 1 ? "none" : "c\($0.offset)", "probability": $0.element]
        }
        let data = try JSONSerialization.data(withJSONObject: ["answers": [["type": "choice", "name": "next_chat",
            "choice": choice, "confidence": 0.9, "probabilities": rows]]])
        return ReplayResponse(.raw, rawJSON: String(decoding: data, as: UTF8.self))
    }

    func testAllLabeledDenominatorsCoverageStrataAndPairedOutcomes() throws {
        var repeated = item(ReplayResponse(.choice, choiceIndex: 3))
        repeated.opens = [ReplayOpen(at: 1, closeAt: 1.1, target: target(3)),
                          ReplayOpen(at: 2, closeAt: 2.1, target: target(2)), ReplayOpen(at: 3, closeAt: 3.1)]
        var missing = item(ReplayResponse(.missing), delay: nil)
        missing.opens[0].target = ConversationKey(provider: .codex, id: "thr_missing_target")
        let outside = item(ReplayResponse(.missing), evidence: evidence(10), target: 8, delay: nil)
        let pin = item(ReplayResponse(.missing), evidence: evidence(5, pins: 1), target: 0, delay: nil)
        let report = try RankingReplay.run(ReplaySuite(evidenceKind: .synthetic, cases: [repeated, missing, outside, pin]))
        let t = report.totals
        XCTAssertEqual(t.opens, 6); XCTAssertEqual(t.labeledOpens, 5); XCTAssertEqual(t.dismissals, 1)
        XCTAssertEqual(t.availableTargets, 4); XCTAssertEqual(t.unavailableTargets, 1)
        XCTAssertEqual(t.pinnedTargets, 1); XCTAssertEqual(t.shortlistTargets, 2); XCTAssertEqual(t.outsideShortlistTargets, 1)
        XCTAssertEqual(t.shortlistEligibleLabeledOpens, 4)
        XCTAssertEqual(t.requests, 4, "repeated opens share a request; missing responses still consume an attempt")
        XCTAssertEqual(t.responseAvailableOpens, 3); XCTAssertEqual(t.acceptedReorderReadyOpens, 3)
        XCTAssertEqual(t.labeledResponseAvailableOpens, 2)
        XCTAssertEqual(t.local.center, 0); XCTAssertEqual(t.deployed.center, 1)
        XCTAssertEqual(t.pairedWins.center, 1); XCTAssertEqual(t.pairedWins.top3, 1); XCTAssertEqual(t.pairedLosses.top3, 1)
    }

    func testTargetReplacementAndRemovalCannotChangeRequestsKeysOrLocalBaseline() throws {
        let original = suite(item(ReplayResponse(.choice, choiceIndex: 3)))
        var changed = original
        changed.cases[0].opens[0].target = ConversationKey(provider: .codex, id: "thr_future_secret_label")
        var unlabeled = original; unlabeled.cases[0].opens[0].target = nil
        let a = try RankingReplay.execute(original), b = try RankingReplay.execute(changed), c = try RankingReplay.execute(unlabeled)
        XCTAssertEqual(a.requests.map(\.body), b.requests.map(\.body)); XCTAssertEqual(a.requests.map(\.body), c.requests.map(\.body))
        XCTAssertEqual(a.requests.map(\.inputKey), b.requests.map(\.inputKey)); XCTAssertEqual(a.requests.map(\.inputKey), c.requests.map(\.inputKey))
        XCTAssertEqual(a.requests.map(\.baseline), b.requests.map(\.baseline)); XCTAssertEqual(a.requests.map(\.baseline), c.requests.map(\.baseline))
        XCTAssertFalse(String(decoding: try XCTUnwrap(b.requests.first).body, as: UTF8.self).contains("future_secret"))
    }

    func testOpenFreezesOrderAndNextOpenCanUseNewResponse() throws {
        var value = item(ReplayResponse(.choice, choiceIndex: 3))
        value.opens = [ReplayOpen(at: 0.1, closeAt: 0.4, target: target(3)), ReplayOpen(at: 1, closeAt: 1.1, target: target(3))]
        let report = try RankingReplay.run(suite(value))
        XCTAssertEqual(report.opens.map(\.localRank), [4, 4]); XCTAssertEqual(report.opens.map(\.deployedRank), [4, 1])
        XCTAssertEqual(report.opens[0].responsesDuringOpen, 1)
        XCTAssertFalse(report.opens[0].responseAvailable); XCTAssertTrue(report.opens[1].acceptedReorderReady)
        XCTAssertEqual(report.totals.requests, 1)
    }

    func testValidationDeadlineSameTimeOrderingAndExactCacheExpiry() throws {
        var slow = item(ReplayResponse(.choice, choiceIndex: 3), delay: 0.7, validation: 0.06, at: 0.71)
        slow.opens.append(ReplayOpen(at: 1, closeAt: 1.1, target: target(3)))
        let late = try RankingReplay.run(suite(slow))
        XCTAssertTrue(late.opens[0].responseAvailable)
        XCTAssertFalse(late.opens[0].timelyValidResponseAvailable)
        XCTAssertEqual(late.opens.map(\.deployedRank), [4, 4]); XCTAssertEqual(late.totals.lateResponses, 1)
        var boundary = item(ReplayResponse(.choice, choiceIndex: 3), delay: 0.75, at: 0.75)
        boundary.opens.append(ReplayOpen(at: 120.75, closeAt: 121, target: target(3)))
        let report = try RankingReplay.run(suite(boundary))
        XCTAssertEqual(report.opens.map(\.deployedRank), [1, 4])
        XCTAssertTrue(report.opens[0].acceptedReorderReady)
        XCTAssertTrue(report.opens[1].responseAvailable); XCTAssertFalse(report.opens[1].acceptedReorderReady)
        XCTAssertFalse(report.opens[1].timelyValidResponseAvailable)
    }

    func testNoOpAndInvalidResponsesAreAvailableWithoutAcceptedReorder() throws {
        for recipe in [ReplayResponse(.none), ReplayResponse(.tie), ReplayResponse(.unchanged),
                       try raw(choice: "c3", probabilities: [0.9, 0, 0, 0.05, 0, 0.05])] {
            let report = try RankingReplay.run(suite(item(recipe)))
            XCTAssertEqual(report.totals.acceptedValidResponses, 1)
            XCTAssertTrue(report.opens[0].responseAvailable); XCTAssertTrue(report.opens[0].timelyValidResponseAvailable)
            XCTAssertFalse(report.opens[0].acceptedReorderReady)
        }
        for recipe in [ReplayResponse(.refused), ReplayResponse(.malformed),
                       try raw(choice: "unknown", probabilities: [0.1, 0.1, 0.1, 0.5, 0.1, 0.1])] {
            let report = try RankingReplay.run(suite(item(recipe)))
            XCTAssertEqual(report.totals.invalidResponses, 1)
            XCTAssertTrue(report.opens[0].responseAvailable); XCTAssertFalse(report.opens[0].timelyValidResponseAvailable)
            XCTAssertFalse(report.opens[0].acceptedReorderReady)
        }
    }

    func testSupersededResponseCannotOverwriteNewGeneration() throws {
        let initial = evidence()
        var revised = initial; revised.state.destinations[0].title = "Revised pre-choice evidence"
        let value = ReplayCase(evidence: initial,
            attempts: [ReplayAttempt(responseAfter: 0.5, response: ReplayResponse(.choice, choiceIndex: 3)),
                       ReplayAttempt(at: 0.1, responseAfter: 0.2, response: ReplayResponse(.choice, choiceIndex: 2), evidence: revised)],
            opens: [ReplayOpen(at: 0.6, closeAt: 0.7, target: target(2)), ReplayOpen(at: 0.8, closeAt: 0.9, target: target(3))])
        let report = try RankingReplay.run(suite(value))
        XCTAssertEqual(report.totals.requests, 2); XCTAssertEqual(report.totals.supersededRequests, 1)
        XCTAssertEqual(report.totals.staleResponses, 1); XCTAssertEqual(report.totals.lateResponses, 0)
        XCTAssertEqual(report.opens.map(\.deployedRank), [1, 4])
    }

    func testPinsAndCrossProviderIdentity() throws {
        let twoPins = try RankingReplay.run(suite(item(ReplayResponse(.choice, choiceIndex: 3), evidence: evidence(7, pins: 2), target: 2)))
        XCTAssertEqual(twoPins.opens[0].localRank, 1); XCTAssertEqual(twoPins.opens[0].deployedRank, 4)
        XCTAssertEqual(twoPins.totals.pairedLosses.top3, 1)
        let tooSmall = try RankingReplay.run(suite(item(ReplayResponse(.choice, choiceIndex: 0), evidence: evidence(3, pins: 2), target: 0)))
        XCTAssertEqual(tooSmall.totals.requests, 0); XCTAssertEqual(tooSmall.totals.responses, 0)
        XCTAssertEqual(tooSmall.totals.pinnedTargets, 1); XCTAssertEqual(tooSmall.totals.shortlistEligibleLabeledOpens, 0)

        let shared = "01234567-89ab-cdef-0123-456789abcdef"
        var mixed = evidence(0); mixed.state.version = 2
        mixed.state.destinations = [Destination(title: "Codex", threadID: shared), Destination(title: "Claude", threadID: shared, provider: .claude)]
        var value = item(ReplayResponse(.choice, choiceIndex: 1), evidence: mixed)
        value.opens[0].target = ConversationKey(provider: .claude, id: shared)
        let report = try RankingReplay.run(suite(value))
        XCTAssertEqual(report.opens[0].localRank, 2); XCTAssertEqual(report.opens[0].deployedRank, 1)
        XCTAssertEqual(report.totals.shortlistTargets, 1)
    }

    func testReturningToOldInputAndContextExpiryDoNotResurrectResponseAvailability() throws {
        let initial = evidence()
        var revised = initial; revised.state.destinations[0].title = "Different evidence"
        let returning = ReplayCase(evidence: initial, attempts: [
            ReplayAttempt(response: ReplayResponse(.choice, choiceIndex: 3)),
            ReplayAttempt(at: 0.3, responseAfter: nil, response: ReplayResponse(.missing), evidence: revised),
            ReplayAttempt(at: 0.6, responseAfter: nil, response: ReplayResponse(.missing), evidence: initial)
        ], opens: [ReplayOpen(at: 0.7, closeAt: 0.8, target: target(3))])
        let report = try RankingReplay.run(suite(returning))
        XCTAssertEqual(report.totals.requests, 2, "same input is not automatically retried")
        XCTAssertFalse(report.opens[0].responseAvailable)
        XCTAssertFalse(report.opens[0].timelyValidResponseAvailable)
        XCTAssertFalse(report.opens[0].acceptedReorderReady)

        var staleSoon = initial
        staleSoon.contextEvents = [ContextEvent(key: ConversationKey(provider: .codex, id: "thr_external_fixture"), topic: "Fixture task",
            kind: .selectedConversation, observedAt: anchor.addingTimeInterval(-1799), source: "fixture", evidence: .observedSelection)]
        var expiry = item(ReplayResponse(.choice, choiceIndex: 3), evidence: staleSoon, at: 0.9)
        expiry.opens = [ReplayOpen(at: 0.9, closeAt: 1, target: target(3)), ReplayOpen(at: 1.1, closeAt: 1.2, target: target(3))]
        let contextReport = try RankingReplay.run(suite(expiry))
        XCTAssertTrue(contextReport.opens[0].timelyValidResponseAvailable)
        XCTAssertFalse(contextReport.opens[1].timelyValidResponseAvailable)
        XCTAssertFalse(contextReport.opens[1].acceptedReorderReady)
    }

    func testSyntheticRoundTripDeterminismAndPrivateAggregateReport() throws {
        let fixture = RankingReplay.syntheticSuite()
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoded = try RankingReplay.decodeSuite(encoder.encode(fixture))
        let first = try RankingReplay.run(fixture), second = try RankingReplay.run(decoded)
        XCTAssertEqual(first, second); XCTAssertEqual(first.evidenceKind, .synthetic)
        XCTAssertGreaterThan(first.totals.lateResponses, 0); XCTAssertGreaterThan(first.totals.invalidResponses, 0)
        let reportText = String(decoding: try JSONEncoder().encode(first), as: UTF8.self)
        for forbidden in ["thr_replay", "Synthetic task", "Synthetic revised", "anchorDate", "rawJSON", "catalog", "contextEvents"] {
            XCTAssertFalse(reportText.contains(forbidden))
        }
    }

    func testBoundsInvalidKeysAndOverlappingInvocationsFailWithDataFreeErrors() throws {
        let valid = suite(item(ReplayResponse(.missing), delay: nil))
        var tooMany = valid; tooMany.cases = Array(repeating: valid.cases[0], count: 33)
        XCTAssertThrowsError(try RankingReplay.run(tooMany))
        var tooLarge = valid; tooLarge.cases[0].evidence = evidence(1001)
        XCTAssertThrowsError(try RankingReplay.run(tooLarge))
        var tooManyOpens = valid
        tooManyOpens.cases[0].opens = (0..<33).map { ReplayOpen(at: Double($0), closeAt: Double($0) + 0.1) }
        XCTAssertThrowsError(try RankingReplay.run(tooManyOpens))
        var tooManyAttempts = valid; tooManyAttempts.cases[0].attempts = Array(repeating: valid.cases[0].attempts[0], count: 9)
        XCTAssertThrowsError(try RankingReplay.run(tooManyAttempts))
        var raw = valid; raw.cases[0].attempts = [ReplayAttempt(response: ReplayResponse(.raw, rawJSON: String(repeating: "x", count: 100_001)))]
        XCTAssertThrowsError(try RankingReplay.run(raw))
        var overlapping = valid; overlapping.cases[0].opens.append(ReplayOpen(at: 1.01, closeAt: 2, target: target(0)))
        XCTAssertThrowsError(try RankingReplay.run(overlapping))
        var invalid = valid; invalid.cases[0].opens[0].target = ConversationKey(provider: .codex, id: "/private/secret")
        XCTAssertThrowsError(try RankingReplay.run(invalid)) { error in XCTAssertFalse(String(describing: error).contains("secret")) }
        var future = valid
        future.cases[0].evidence.contextEvents = [ContextEvent(key: target(0), kind: .selectedConversation,
            observedAt: anchor.addingTimeInterval(1), source: "fixture", evidence: .observedSelection)]
        XCTAssertThrowsError(try RankingReplay.run(future))
        XCTAssertThrowsError(try RankingReplay.decodeSuite(Data(repeating: 32, count: RankingReplay.maximumInputBytes + 1)))
        var nonfinite = valid; nonfinite.cases[0].opens[0].at = .infinity
        XCTAssertThrowsError(try RankingReplay.run(nonfinite))
    }
}
