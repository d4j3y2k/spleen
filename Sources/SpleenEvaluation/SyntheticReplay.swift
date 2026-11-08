import Foundation
import SpleenCore

extension RankingReplay {
    /// Behavior fixtures only: scripted probabilities are not model predictions or quality evidence.
    public static func syntheticSuite() -> ReplaySuite {
        let anchor = Date(timeIntervalSince1970: 2_000_000_000)
        var state = SavedState()
        state.destinations = (0..<10).map { index in
            Destination(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!,
                        title: "Synthetic task \(index)", threadID: String(format: "thr_replay_%04d", index))
        }
        let evidence = ReplayEvidence(state: state, anchorDate: anchor)
        func target(_ index: Int) -> ConversationKey { state.destinations[index].conversationKey }
        func one(_ response: ReplayResponse, target index: Int, delay: Double? = 0.2,
                 open: Double = 1, validation: Double = 0) -> ReplayCase {
            ReplayCase(evidence: evidence, attempts: [ReplayAttempt(responseAfter: delay, validationDelay: validation, response: response)],
                       opens: [ReplayOpen(at: open, closeAt: open + 0.1, target: target(index))])
        }
        var cases = [one(ReplayResponse(.choice, choiceIndex: 3), target: 3),
                     one(ReplayResponse(.choice, choiceIndex: 3), target: 2),
                     one(ReplayResponse(.choice, choiceIndex: 3), target: 3, delay: 1),
                     one(ReplayResponse(.missing), target: 8, delay: nil),
                     one(ReplayResponse(.refused), target: 0), one(ReplayResponse(.malformed), target: 4),
                     one(ReplayResponse(.none), target: 0), one(ReplayResponse(.tie), target: 3),
                     one(ReplayResponse(.unchanged), target: 0),
                     one(ReplayResponse(.choice, choiceIndex: 3), target: 3, delay: 0.7, validation: 0.06),
                     one(ReplayResponse(.choice, choiceIndex: 3), target: 3, delay: 0.75, open: 0.75),
                     one(ReplayResponse(.choice, choiceIndex: 3), target: 3, delay: 0.2, open: 120.2)]
        cases.append(ReplayCase(evidence: evidence, attempts: [ReplayAttempt(response: ReplayResponse(.choice, choiceIndex: 3))],
            opens: [ReplayOpen(at: 0.1, closeAt: 0.4, target: target(3)), ReplayOpen(at: 1, closeAt: 1.1, target: target(3)),
                    ReplayOpen(at: 2, closeAt: 2.1)]))
        cases.append(ReplayCase(evidence: evidence, attempts: [ReplayAttempt(responseAfter: nil, response: ReplayResponse(.missing))],
            opens: [ReplayOpen(at: 1, closeAt: 1.1, target: ConversationKey(provider: .codex, id: "thr_replay_absent"))]))
        var replacement = evidence; replacement.state.destinations[0].title = "Synthetic revised task"
        cases.append(ReplayCase(evidence: evidence, attempts: [ReplayAttempt(responseAfter: 0.5, response: ReplayResponse(.choice, choiceIndex: 3)),
            ReplayAttempt(at: 0.1, responseAfter: 0.2, response: ReplayResponse(.choice, choiceIndex: 2), evidence: replacement)],
            opens: [ReplayOpen(at: 0.6, closeAt: 0.7, target: target(2))]))
        var pinned = evidence; pinned.state.destinations[0].pinned = true
        cases.append(ReplayCase(evidence: pinned, attempts: [ReplayAttempt(response: ReplayResponse(.choice, choiceIndex: 3))],
                                opens: [ReplayOpen(at: 1, closeAt: 1.1, target: target(0))]))
        return ReplaySuite(evidenceKind: .synthetic, cases: cases)
    }
}
