import Foundation
import SpleenCore

public enum ReplayEvidenceKind: String, Codable { case synthetic, recorded }
public struct ReplaySuite: Codable {
    public var version: Int
    public var evidenceKind: ReplayEvidenceKind
    public var cases: [ReplayCase]
    public init(version: Int = 1, evidenceKind: ReplayEvidenceKind, cases: [ReplayCase]) {
        self.version = version; self.evidenceKind = evidenceKind; self.cases = cases
    }
}
/// Only information available before choosing a destination belongs here.
public struct ReplayEvidence: Codable {
    public var state: SavedState
    public var catalog: CatalogCache
    public var notes: [ThreadInsight]
    public var contextEvents: [ContextEvent]
    public var anchorDate: Date
    public init(state: SavedState, catalog: CatalogCache = CatalogCache(), notes: [ThreadInsight] = [],
                contextEvents: [ContextEvent] = [], anchorDate: Date) {
        self.state = state; self.catalog = catalog; self.notes = notes
        self.contextEvents = contextEvents; self.anchorDate = anchorDate
    }
}
public enum ReplayResponseKind: String, Codable { case choice, none, tie, unchanged, refused, malformed, raw, missing }
public struct ReplayResponse: Codable {
    public var kind: ReplayResponseKind
    public var choiceIndex: Int?
    public var rawJSON: String?
    public init(_ kind: ReplayResponseKind, choiceIndex: Int? = nil, rawJSON: String? = nil) {
        self.kind = kind; self.choiceIndex = choiceIndex; self.rawJSON = rawJSON
    }
}
public struct ReplayAttempt: Codable {
    public var at: Double
    /// Arrival offset from `at`; nil only for a missing response.
    public var responseAfter: Double?
    /// Virtual validation duration; it consumes the pipeline's 750 ms deadline.
    public var validationDelay: Double
    public var response: ReplayResponse
    public var evidence: ReplayEvidence?
    public init(at: Double = 0, responseAfter: Double? = 0.2, validationDelay: Double = 0,
                response: ReplayResponse, evidence: ReplayEvidence? = nil) {
        self.at = at; self.responseAfter = responseAfter; self.validationDelay = validationDelay
        self.response = response; self.evidence = evidence
    }
}
/// Labels are deliberately separate from evidence and response recipes.
public struct ReplayOpen: Codable {
    public var at: Double
    public var closeAt: Double
    public var target: ConversationKey?
    public init(at: Double, closeAt: Double, target: ConversationKey? = nil) {
        self.at = at; self.closeAt = closeAt; self.target = target
    }
}
public struct ReplayCase: Codable {
    public var evidence: ReplayEvidence
    public var attempts: [ReplayAttempt]
    public var opens: [ReplayOpen]
    public init(evidence: ReplayEvidence, attempts: [ReplayAttempt], opens: [ReplayOpen]) {
        self.evidence = evidence; self.attempts = attempts; self.opens = opens
    }
}

public struct ReplayHits: Codable, Equatable {
    public var center = 0
    public var top3 = 0
    public var compass = 0
    public init() {}
    mutating func add(rank: Int?) {
        guard let rank else { return }
        if rank == 1 { center += 1 }; if rank <= 3 { top3 += 1 }; if rank <= 5 { compass += 1 }
    }
}
public struct ReplayTotals: Codable, Equatable {
    public var opens = 0, labeledOpens = 0, dismissals = 0
    public var availableTargets = 0, pinnedTargets = 0, shortlistTargets = 0, outsideShortlistTargets = 0, unavailableTargets = 0
    /// Every labeled open except a pinned target, including unavailable targets.
    public var shortlistEligibleLabeledOpens = 0
    public var responseAvailableOpens = 0, timelyValidResponseAvailableOpens = 0, acceptedReorderReadyOpens = 0
    public var labeledResponseAvailableOpens = 0, labeledAcceptedReorderReadyOpens = 0
    public var requests = 0, responses = 0, acceptedValidResponses = 0, invalidResponses = 0, lateResponses = 0, staleResponses = 0, supersededRequests = 0
    public var local = ReplayHits(), deployed = ReplayHits(), pairedWins = ReplayHits(), pairedLosses = ReplayHits()
    public init() {}
}
/// Numeric strata: 0 dismissal, 1 pinned, 2 unpinned shortlist, 3 available outside shortlist, 4 unavailable.
public struct ReplayOpenReport: Codable, Equatable {
    public let caseIndex: Int
    public let openIndex: Int
    public let stratum: Int
    /// A raw response has arrived for this generation; it may be invalid, late, or expired.
    public let responseAvailable: Bool
    public let timelyValidResponseAvailable: Bool
    public let acceptedReorderReady: Bool
    public let localRank: Int?
    public let deployedRank: Int?
    public let responsesDuringOpen: Int
}
public struct ReplayReport: Codable, Equatable {
    public let version: Int
    public let evidenceKind: ReplayEvidenceKind
    public let totals: ReplayTotals
    public let opens: [ReplayOpenReport]
}
public enum ReplayError: String, Error, CustomStringConvertible {
    case invalidFixture, unsupportedVersion, limitExceeded, invalidEvidence, invalidTimeline, invalidResponseRecipe
    public var description: String { "Replay rejected: " + rawValue }
}

public enum RankingReplay {
    public static let maximumInputBytes = 1_048_576
    public static let maximumResponseBytes = 100_000
    public static func decodeSuite(_ data: Data) throws -> ReplaySuite {
        guard data.count <= maximumInputBytes else { throw ReplayError.limitExceeded }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: text) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = formatter.date(from: text) else { throw ReplayError.invalidFixture }
            return date
        }
        let suite: ReplaySuite
        do { suite = try decoder.decode(ReplaySuite.self, from: data) }
        catch { throw ReplayError.invalidFixture }
        try validate(suite)
        return suite
    }
    public static func run(_ suite: ReplaySuite) throws -> ReplayReport { try execute(suite).report }
    /// LOCAL review only: exported request bodies can include approved titles/topics/short notes.
    /// Labels never enter request preparation. No transport is constructed by this module.
    public static func requests(_ suite: ReplaySuite) throws -> [Data] { try execute(suite).requests.map(\.body) }

    struct CapturedRequest { let body: Data; let inputKey: String; let baseline: [ConversationKey] }
    struct Execution { let report: ReplayReport; let requests: [CapturedRequest] }
    private struct Ready {
        let prepared: PreparedContext
        let input: RankingInput
    }
    private struct Event { let at: Double; let priority: Int; let index: Int }

    static func execute(_ suite: ReplaySuite) throws -> Execution {
        try validate(suite)
        var totals = ReplayTotals(), reports: [ReplayOpenReport] = [], captured: [CapturedRequest] = []
        for (caseIndex, item) in suite.cases.enumerated() {
            var activeEvidence = item.evidence
            var ready = prepare(activeEvidence, at: 0)
            var pipeline = RankingPipeline(requestCap: 8)
            var jobs: [Int: RankingPipeline.Job] = [:], responses: [Int: Data] = [:]
            var jobGenerations: [Int: Int] = [:], generation = 0
            var activeJobID: UUID?, acceptedAt: Double?
            var responseReceived = false, arrivals: [Double] = []
            var events: [Event] = []
            for (index, attempt) in item.attempts.enumerated() {
                events.append(Event(at: attempt.at, priority: 0, index: index))
                if let delay = attempt.responseAfter {
                    events.append(Event(at: attempt.at + delay, priority: 1, index: index))
                    events.append(Event(at: attempt.at + delay + attempt.validationDelay, priority: 2, index: index))
                }
            }
            events += item.opens.enumerated().map { Event(at: $0.element.at, priority: 3, index: $0.offset) }
            // Same-time order is deterministic: replacement/attempt, arrival, validation, opening.
            events.sort { ($0.at, $0.priority, $0.index) < ($1.at, $1.priority, $1.index) }
            var caseReports: [ReplayOpenReport] = []
            for event in events {
                switch event.priority {
                case 0:
                    let attempt = item.attempts[event.index]
                    if let replacement = attempt.evidence { activeEvidence = replacement }
                    let next = prepare(activeEvidence, at: event.at)
                    if next.input.key != ready.input.key {
                        pipeline.invalidate(); generation += 1; activeJobID = nil
                        acceptedAt = nil; responseReceived = false
                    }
                    ready = next
                    guard let job = pipeline.begin(ready.input, now: event.at) else { continue }
                    jobs[event.index] = job
                    jobGenerations[event.index] = generation; activeJobID = job.id
                    let body = try ready.input.body(now: item.evidence.anchorDate.addingTimeInterval(event.at))
                    captured.append(CapturedRequest(body: body, inputKey: ready.input.key,
                                                    baseline: ready.prepared.contextual.ordered.map(\.conversationKey)))
                case 1:
                    guard let job = jobs[event.index] else { continue }
                    responses[event.index] = try response(item.attempts[event.index].response, input: job.input)
                    if jobGenerations[event.index] == generation { responseReceived = true }
                    arrivals.append(event.at); totals.responses += 1
                case 2:
                    guard let job = jobs[event.index], let data = responses[event.index] else { continue }
                    let before = pipeline.metrics.valid
                    let current = jobGenerations[event.index] == generation && activeJobID == job.id
                    if !current { totals.staleResponses += 1 }
                    else {
                        activeJobID = nil
                        if event.at > job.deadline { totals.lateResponses += 1 }
                    }
                    pipeline.finish(job, response: .success(data), now: event.at)
                    if current && pipeline.metrics.valid > before { acceptedAt = event.at }
                default:
                    let opening = item.opens[event.index]
                    let date = item.evidence.anchorDate.addingTimeInterval(event.at)
                    let local = ready.prepared.snapshot(now: date, uptime: event.at).ordered
                    let deployed = ready.prepared.isFresh(now: date, uptime: event.at)
                        ? pipeline.snapshot(baseline: local, input: ready.input, now: event.at) : local
                    // Capture once at opening. Later validation cannot change this invocation's order.
                    let localRank = opening.target.flatMap { target in local.firstIndex { $0.conversationKey == target }.map { $0 + 1 } }
                    let deployedRank = opening.target.flatMap { target in deployed.firstIndex { $0.conversationKey == target }.map { $0 + 1 } }
                    let pinned = opening.target.map { target in local.contains { $0.conversationKey == target && $0.pinned } } ?? false
                    let shortlisted = opening.target.map { target in ready.input.candidates.contains { $0.conversationKey == target } } ?? false
                    let stratum = opening.target == nil ? 0 : pinned ? 1 : shortlisted ? 2 : localRank != nil ? 3 : 4
                    let available = responseReceived
                    let valid = acceptedAt.map { event.at >= $0 && event.at < $0 + 120 } == true &&
                        ready.prepared.isFresh(now: date, uptime: event.at)
                    let reordered = local.map(\.conversationKey) != deployed.map(\.conversationKey)
                    caseReports.append(ReplayOpenReport(caseIndex: caseIndex, openIndex: event.index, stratum: stratum,
                        responseAvailable: available, timelyValidResponseAvailable: valid, acceptedReorderReady: reordered,
                        localRank: localRank, deployedRank: deployedRank, responsesDuringOpen: 0))
                }
            }
            for row in caseReports {
                let opening = item.opens[row.openIndex]
                let final = ReplayOpenReport(caseIndex: row.caseIndex, openIndex: row.openIndex, stratum: row.stratum,
                    responseAvailable: row.responseAvailable, timelyValidResponseAvailable: row.timelyValidResponseAvailable,
                    acceptedReorderReady: row.acceptedReorderReady, localRank: row.localRank, deployedRank: row.deployedRank,
                    responsesDuringOpen: arrivals.filter { $0 > opening.at && $0 < opening.closeAt }.count)
                reports.append(final); accumulate(final, into: &totals)
            }
            totals.requests += pipeline.metrics.calls; totals.acceptedValidResponses += pipeline.metrics.valid
            totals.invalidResponses += pipeline.metrics.failed
            totals.supersededRequests += pipeline.metrics.superseded
        }
        return Execution(report: ReplayReport(version: 1, evidenceKind: suite.evidenceKind, totals: totals, opens: reports), requests: captured)
    }
    private static func prepare(_ evidence: ReplayEvidence, at time: Double) -> Ready {
        let instant = evidence.anchorDate.addingTimeInterval(time)
        var memory = ContextMemory(recentsEnabled: evidence.state.rememberRecents)
        for event in evidence.contextEvents { memory.record(event, now: instant) }
        let prepared = PreparedContext(state: evidence.state, catalog: evidence.catalog, insights: evidence.notes,
                                       context: memory, now: instant, uptime: time)
        let input = RankingInput(baseline: prepared.contextual.ordered, context: memory, catalog: evidence.catalog,
                                 insights: evidence.notes, now: instant)
        return Ready(prepared: prepared, input: input)
    }
    private static func response(_ recipe: ReplayResponse, input: RankingInput) throws -> Data {
        switch recipe.kind {
        case .raw: return Data((recipe.rawJSON ?? "").utf8)
        case .malformed: return Data("{malformed".utf8)
        case .refused: return Data(#"{"answers":[{"type":"refusal","name":"next_chat"}]}"#.utf8)
        case .missing: return Data()
        default: break
        }
        let count = input.candidates.count
        if recipe.kind == .choice, let index = recipe.choiceIndex, index >= count { throw ReplayError.invalidResponseRecipe }
        let choice = recipe.kind == .none ? "none" : "c\(recipe.kind == .choice ? recipe.choiceIndex ?? 0 : 0)"
        let aliases = (0..<count).map { "c\($0)" } + ["none"]
        let rows: [[String: Any]] = aliases.map { alias in
            let probability: Double
            if recipe.kind == .tie { probability = 1 / Double(aliases.count) }
            else if recipe.kind == .none { probability = alias == "none" ? 1 : 0 }
            else { probability = alias == choice ? 0.9 : alias == "none" ? 0.1 : 0 }
            return ["value": alias, "probability": probability]
        }
        return try JSONSerialization.data(withJSONObject: ["answers": [["type": "choice", "name": "next_chat",
            "choice": choice, "confidence": 0.9, "probabilities": rows]]], options: [.sortedKeys])
    }
    private static func accumulate(_ row: ReplayOpenReport, into totals: inout ReplayTotals) {
        totals.opens += 1
        if row.responseAvailable { totals.responseAvailableOpens += 1 }
        if row.timelyValidResponseAvailable { totals.timelyValidResponseAvailableOpens += 1 }
        if row.acceptedReorderReady { totals.acceptedReorderReadyOpens += 1 }
        guard row.stratum != 0 else { totals.dismissals += 1; return }
        totals.labeledOpens += 1
        if row.responseAvailable { totals.labeledResponseAvailableOpens += 1 }
        if row.acceptedReorderReady { totals.labeledAcceptedReorderReadyOpens += 1 }
        if row.stratum == 4 { totals.unavailableTargets += 1 } else { totals.availableTargets += 1 }
        if row.stratum == 1 { totals.pinnedTargets += 1 } else { totals.shortlistEligibleLabeledOpens += 1 }
        if row.stratum == 2 { totals.shortlistTargets += 1 }
        if row.stratum == 3 { totals.outsideShortlistTargets += 1 }
        totals.local.add(rank: row.localRank); totals.deployed.add(rank: row.deployedRank)
        for (limit, path) in [(1, \ReplayHits.center), (3, \ReplayHits.top3), (5, \ReplayHits.compass)] {
            let local = row.localRank.map { $0 <= limit } ?? false, deployed = row.deployedRank.map { $0 <= limit } ?? false
            if deployed && !local { totals.pairedWins[keyPath: path] += 1 }
            if local && !deployed { totals.pairedLosses[keyPath: path] += 1 }
        }
    }
}
