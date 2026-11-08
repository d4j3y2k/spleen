import Foundation
import SpleenCore

func runAttentionTests() -> (passed: Int, failures: [String]) {
    var passed = 0, failures: [String] = []
    func check(_ condition: Bool, _ label: String) { if condition { passed += 1 } else { failures.append(label); print("FAIL: \(label)") } }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("spleen-attention-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    do {
        let instant = Date()
        let first = Destination(title: "Delivered feature", threadID: "thr_attention_first")
        let second = Destination(title: "Other task", threadID: "thr_attention_second")
        var state = SavedState(); state.destinations = [first, second]
        let repository = StateRepository(url: directory.appendingPathComponent("destinations.json")); try repository.save(state)
        var catalog = CatalogCache(); catalog.folders = ["/fixture"]; catalog.refreshedAt = instant
        catalog.entries = state.destinations.map { CatalogEntry(id: $0.threadID, title: $0.title, folder: "/fixture", updatedAt: instant) }
        try catalog.save(to: directory.appendingPathComponent("catalog.json"))
        let window = SessionWindow(key: first.conversationKey, sourceUpdatedAt: instant, messages: [
            RecentMessage(id: "u1", role: .user, text: "Fix the feature"), RecentMessage(id: "a1", role: .assistant, text: "Fixed and tests pass.")])
        var notes = InsightCache(); notes.entries = [ThreadInsight(id: first.threadID, folder: "/fixture", updatedAt: instant, topic: first.title,
            timing: TurnTiming(checkedAt: instant), window: window)]
        try notes.save(to: directory.appendingPathComponent("relevance.json"))
        let transport = AttentionTestTransport()
        let model = AppModel(repository: repository, catalogFetcher: { _ in (catalog.entries, false) }, insightFetcher: { _, _ in [] }, assessmentTransport: transport)
        func settle(_ predicate: () -> Bool) {
            let deadline = Date().addingTimeInterval(3)
            while predicate() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.002)) }
        }
        settle { model.indexing || transport.bodies.isEmpty }
        check(transport.bodies.count == 1, "one assessment request for changed complete message window")
        model.prepare(); let fixed = model.compassItems; let selected = model.selectedID
        model.receiveLiveState(LiveSessionState(key: second.conversationKey, source: "fixture", observedAt: instant, sequence: 1, activity: .working, isUnread: true))
        settle { model.indexing }
        check(model.compassItems == fixed && model.selectedID == selected, "live badges preserve visible card positions and selection")
        check(model.liveState(second)?.activity == .working && model.liveState(second)?.isUnread == true, "working and unread coexist on card")
        let response = try JSONSerialization.data(withJSONObject: ["answers": [["type": "choice", "name": "task_state", "choice": "appears_finished", "confidence": 0.9,
            "probabilities": TaskAssessment.allCases.map { ["value": $0.rawValue, "probability": $0 == .appearsFinished ? 0.85 : 0.05] as [String: Any] }]]])
        transport.completion?(.success(response))
        settle { model.taskLabel(first) == nil || model.indexing }
        check(model.taskLabel(first) == "Appears finished", "assessment reaches application recognition label")
        check(model.compassItems == fixed, "assessment cannot reorder open compass")
        check(transport.bodies.count == 1, "unchanged evidence is not reclassified")
        model.endPresentation(); model.prepare()
        check(model.compassItems.first?.id == second.id, "fresh attention priority applies at next opening")
        check(model.results.contains(first), "unknown read state prevents completed-task false exclusion")
        model.beginSearch("Delivered")
        check(model.results.contains(first), "finished session stays explicitly searchable")

        // Manual review path never automatically sends or reorders the visible compass.
        let manual = AttentionTestTransport()
        let body = try SessionAssessmentInput(window: window).body()
        let beforeReview = model.compassItems
        model.sendReviewedAssessment(window: window, body: body, transport: manual)
        check(manual.bodies == [body] && model.decisionReviewBusy, "manual assessment sends exact reviewed bytes once")
        model.sendReviewedAssessment(window: window, body: body, transport: manual)
        check(manual.bodies.count == 1, "manual assessment prevents concurrent duplicate click")
        manual.completion?(.success(response))
        settle { model.decisionReviewBusy }
        check(model.decisionReviewStatus.contains("appears finished"), "manual result is visible in settings")
        check(model.compassItems == beforeReview, "manual result never reorders visible picker")
        let stopped = AttentionTestTransport()
        model.sendReviewedAssessment(window: window, body: body, transport: stopped)
        model.stopReviewedAssessment()
        stopped.completion?(.success(response))
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        check(model.decisionReviewStatus.hasPrefix("Stopped") && !model.decisionReviewBusy, "stopped assessment ignores late results")
        let unavailable = AttentionTestTransport()
        model.sendReviewedAssessment(window: window, body: body, transport: unavailable)
        unavailable.completion?(.failure(DecisionsTrialError.expired))
        settle { model.decisionReviewBusy }
        check(model.decisionReviewStatus.contains("Not retried") && unavailable.bodies.count == 1, "manual failure does not retry")
        let keyFixture = directory.appendingPathComponent("credential-fixture")
        try "OPENAI_API_KEY=sk-test-not-a-real-key\n".write(to: keyFixture, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFixture.path)
        check(try attentionCredential(at: keyFixture) == "sk-test-not-a-real-key", "explicit env credential file supported")
        try "sk-test-raw-not-a-real-key\n".write(to: keyFixture, atomically: true, encoding: .utf8)
        check(try attentionCredential(at: keyFixture) == "sk-test-raw-not-a-real-key", "explicit raw credential file remains supported")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: keyFixture.path)
        check((try? attentionCredential(at: keyFixture)) == nil, "world-readable credential file rejected")
        // Assessment on open reuses a manual cached result and can be paused without another request.
        let automaticMock = AttentionTestTransport()
        let automatic = AutomaticAttentionConsent(enabled: true, id: "native-open", dailyLimit: 2, credentialPath: keyFixture.path, scope: AutomaticAttentionConsent.scopeName)
        model.activateAutomaticAssessment(consent: automatic, transport: automaticMock)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        check(automaticMock.bodies.isEmpty, "turning on assessment on open sends nothing by itself")
        model.endPresentation(); model.prepare()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        check(automaticMock.bodies.isEmpty, "a press reuses the saved label for an unchanged card")
        check(model.automaticAssessmentEnabled, "assessment on open reports enabled after explicit activation")
        model.pauseAutomaticAssessment()
        let loadedConsent = try AutomaticAttentionConsent.load(from: directory)
        check(!model.automaticAssessmentEnabled && loadedConsent == nil,
              "pause persists disabled state across restart")
        check(automaticMock.bodies.isEmpty, "pause does not send a request")
        // Launch sends nothing; a press sends a changed Codex card on screen once.
        let openDirectory = directory.appendingPathComponent("on-open", isDirectory: true)
        let openRepository = StateRepository(url: openDirectory.appendingPathComponent("destinations.json")); try openRepository.save(state)
        try catalog.save(to: openDirectory.appendingPathComponent("catalog.json"))
        try notes.save(to: openDirectory.appendingPathComponent("relevance.json"))
        let openMock = AttentionTestTransport()
        let openModel = AppModel(repository: openRepository, catalogFetcher: { _ in (catalog.entries, false) }, insightFetcher: { _, _ in [] },
                                 assessmentTransport: openMock, automaticConsent: automatic)
        settle { openModel.indexing }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        check(openMock.bodies.isEmpty, "assessment on open sends nothing at launch")
        openModel.prepare()
        settle { openMock.bodies.isEmpty }
        check(openMock.bodies.count == 1 && openModel.compassItems.contains(first), "a press sends the changed Codex card on screen")
        openMock.completion?(.success(response))
        settle { openModel.taskLabel(first) == nil }
        check(openModel.taskLabel(first) == "Appears finished", "a press's result labels that card")
        openModel.endPresentation(); openModel.prepare()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        check(openMock.bodies.count == 1, "a later press doesn't resend unchanged text")
        let claudeObservation = ClaudeDesktopObservation(url: "claude.ai/epitaxy/local_11111111-1111-4111-8111-111111111111", title: "Claude fixture - Claude Code")!
        let claude = Destination(title: claudeObservation.title, threadID: claudeObservation.key.id, provider: .claude)
        let claudeFixed = model.compassItems
        let contextBeforeStatus = model.context.events
        let status = ClaudeDesktopStatus(observation: claudeObservation,
            matchingSidebarRows: ["Claude fixture Running"], sidebarComplete: true, currentRowConfirmed: true)!
        model.receiveClaudeStatus(status.sample(at: Date(), sequence: 1, epoch: "native-fixture"))
        settle { model.indexing }
        check(model.liveState(claude)?.accessibilityText == "Working", "Claude native status reaches the working badge")
        let unread = ClaudeDesktopStatus(observation: claudeObservation,
            matchingSidebarRows: ["Claude fixture Unread response"], sidebarComplete: true, currentRowConfirmed: true)!
        model.receiveClaudeStatus(unread.sample(at: Date(), sequence: 2, epoch: "native-fixture"))
        settle { model.indexing }
        check(model.liveState(claude)?.accessibilityText == "Unread reply", "Claude finish removes spinner and native unread adds dot")
        check(model.context.events == contextBeforeStatus, "background Claude status never records a visit")
        check(model.compassItems == claudeFixed, "Claude status changes preserve visible compass targets")
        let read = ClaudeDesktopStatus(observation: claudeObservation,
            matchingSidebarRows: ["Claude fixture"], sidebarComplete: true, currentRowConfirmed: true)!
        model.receiveClaudeStatus(read.sample(at: Date(), sequence: 3, epoch: "native-fixture"))
        check(model.liveState(claude)?.isUnread == false && model.liveState(claude)?.accessibilityText == "",
              "native Claude read acknowledgement clears the unread badge")
        var work = ClaudeDesktopWorkControls(); work.backgroundTaskStops = 1
        let background = ClaudeDesktopStatus(observation: claudeObservation, matchingSidebarRows: ["Claude fixture"],
            sidebarComplete: true, currentRowConfirmed: false, workControls: work)!
        model.receiveClaudeStatus(background.sample(at: Date(), sequence: 4, epoch: "native-fixture"))
        check(model.liveState(claude)?.accessibilityText == "Working" && model.liveState(claude)?.isUnread == nil,
              "Claude background task keeps spinner after reply ends even without sidebar current marker")
        model.receiveClaudeStatus(nil)
        check(model.liveState(claude) == nil && model.liveState(second)?.activity == .working,
              "losing Claude status clears only Claude source, preserving Codex activity")
        let replyNow = Date()
        let reply = ClaudeReplyTime(label: "12 minutes ago", observedAt: replyNow)!
        model.receiveClaudeReply(reply, for: claude.conversationKey)
        check(model.timingLabel(claude) == nil, "Claude reply metadata stays frozen during the current opening")
        model.endPresentation(); model.prepare()
        check(model.timingLabel(claude) == "Last reply ≈12m ago", "observed Claude reply age reaches the next picker opening")
        check(model.timingHelp(claude).contains("Approximate"), "Claude reply tooltip explains relative source precision")
        check(model.context.events == contextBeforeStatus, "Claude reply metadata never records a visit")
        model.receiveClaudeReply(ClaudeReplyTime(label: "just now", observedAt: Date())!, for: claude.conversationKey)
        check(model.timingLabel(claude) == "Last reply ≈12m ago", "new Claude reply does not mutate frozen picker metadata")
        model.endPresentation(); model.prepare()
        check(model.timingLabel(claude) == "Last reply ≈just now", "newly observed Claude reply appears after reopening")
        model.clearRecents()
        check(model.timingLabel(claude) == nil, "clearing history removes cached Claude reply times")
    } catch { failures.append("attention fixture failed: \(error)") }
    return (passed, failures)
}
private final class AttentionTestTransport: DecisionsTransport {
    var bodies: [Data] = []
    var completion: ((Result<Data, Error>) -> Void)?
    func send(body: Data, completion: @escaping (Result<Data, Error>) -> Void) -> (() -> Void) {
        bodies.append(body); self.completion = completion; return {}
    }
}
