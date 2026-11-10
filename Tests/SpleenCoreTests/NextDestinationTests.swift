import XCTest
@testable import SpleenCore

final class NextDestinationTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 2_000_000_000)

    func testPreviousConversationBiasWithinAndAcrossProviders() {
        for previousProvider in ContextProvider.allCases {
            for currentProvider in ContextProvider.allCases {
                assertPreviousConversationBias(previousProvider: previousProvider, currentProvider: currentProvider)
            }
        }
    }

    private func assertPreviousConversationBias(previousProvider: ContextProvider, currentProvider: ContextProvider) {
        let previous = Destination(title: "Previous session",
            threadID: previousProvider == .claude ? "desktop-code:local_01234567-89ab-cdef-0123-456789abcdef" : "thr_return_previous",
            provider: previousProvider)
        let current = Destination(title: "Current work",
            threadID: currentProvider == .claude ? "desktop-code:local_11234567-89ab-cdef-0123-456789abcdef" : "thr_return_current",
            lastOpenedAt: now, provider: currentProvider)
        let other = Destination(title: "Another Codex task", threadID: "thr_return_other")
        let pin = Destination(title: "Reference", threadID: "thr_return_pin", pinned: true)
        var state = SavedState(); state.destinations = [pin, current, other]
        // Claude is discovered from an observed visit; Codex is already available.
        if previousProvider == .codex { state.destinations.append(previous) }

        for (visitAge, expected) in [(300.0, previous.conversationKey), (1200.0, other.conversationKey)] {
            var memory = ContextMemory()
            memory.record(ContextEvent(key: previous.conversationKey, topic: previous.title,
                kind: previousProvider == .claude ? .selectedConversation : .spleenDispatch,
                observedAt: now.addingTimeInterval(-visitAge),
                source: previousProvider == .claude ? "claude-desktop-accessibility" : "spleen",
                evidence: previousProvider == .claude ? .observedSelection : .spleenInteraction), now: now)
            memory.record(ContextEvent(key: current.conversationKey, kind: .spleenDispatch,
                observedAt: now, source: "spleen", evidence: .spleenInteraction), now: now)
            var attention = SessionAttention()
            attention.rememberActivity([other.conversationKey: now.addingTimeInterval(-30)], at: now)
            let prepared = PreparedContext(state: state, catalog: CatalogCache(), context: memory,
                now: now, uptime: 100, attention: attention)
            let snapshot = prepared.snapshot(now: now, uptime: 100)
            XCTAssertEqual(snapshot.currentKey, current.conversationKey)
            XCTAssertEqual(snapshot.ordered.first?.conversationKey, expected)
            XCTAssertEqual(snapshot.ordered[1], pin)
            XCTAssertNotEqual(snapshot.ordered.first, current)
            XCTAssertEqual(snapshot.results(query: "Previous session").first?.conversationKey, previous.conversationKey)
            // The preference cannot extend the actual visit's 30-minute lifetime.
            let expiry = 1800 - visitAge
            for offset in [expiry - 1, expiry, expiry + 1] {
                let date = now.addingTimeInterval(offset)
                let rebuilt = RelevanceSnapshot(state: state, catalog: CatalogCache(), context: memory, now: date, attention: attention)
                XCTAssertEqual(prepared.snapshot(now: date, uptime: 100 + offset).ordered, rebuilt.ordered)
            }
            for (activity, unread) in [(RuntimeActivity.working, false), (.idle, true), (.waitingForApproval, false), (.waitingForInput, false)] {
                var live = attention
                XCTAssertTrue(live.accept(LiveSessionState(key: other.conversationKey, source: "fixture", observedAt: now,
                    sequence: 1, activity: activity, isUnread: unread), now: now))
                let urgent = RelevanceSnapshot(state: state, catalog: CatalogCache(), context: memory, now: now, attention: live)
                XCTAssertEqual(urgent.ordered.first, other, "Fresh attention can outweigh the previous conversation")
            }
        }
    }

    func testPreviousConversationGetsStrongerFallbackWeightThanTopicMatch() {
        let current = Destination(title: "SQLite transaction contention locking database migration journal queries", threadID: "thr_bias_current", lastOpenedAt: now)
        let previous = Destination(title: "Piano practice", threadID: "thr_bias_previous")
        let related = Destination(title: current.title, threadID: "thr_bias_related")
        var state = SavedState(); state.destinations = [current, previous, related]
        var catalog = CatalogCache(); catalog.folders = ["/database"]
        catalog.entries = [current, related].map { CatalogEntry(id: $0.threadID, title: $0.title, folder: "/database", updatedAt: now) }
        var memory = ContextMemory()
        memory.record(ContextEvent(key: previous.conversationKey, kind: .spleenDispatch,
            observedAt: now.addingTimeInterval(-2100), source: "spleen", evidence: .spleenInteraction), now: now)
        memory.record(ContextEvent(key: current.conversationKey, kind: .spleenDispatch,
            observedAt: now, source: "spleen", evidence: .spleenInteraction), now: now)
        let snapshot = RelevanceSnapshot(state: state, catalog: catalog, context: memory, now: now)
        XCTAssertEqual(snapshot.ordered.first, previous, "A previous conversation remains a strong return candidate outside the recent-use window")
        XCTAssertEqual(snapshot.ordered.dropFirst().first, related)
    }

    func testCenterChangesAcrossReturnsWhileUnrelatedPinStaysNearby() {
        let pin = Destination(title: "Pinned reference", threadID: "thr_pin_fixture", pinned: true)
        let a = Destination(title: "Conversation A", threadID: "thr_a_fixture")
        let b = Destination(title: "Conversation B", threadID: "thr_b_fixture")
        var state = SavedState(); state.destinations = [pin, a, b]
        var memory = ContextMemory()
        func record(_ item: Destination, at time: Date) {
            state.recordDispatch(item.id, at: time)
            memory.record(ContextEvent(key: item.conversationKey, kind: .spleenDispatch,
                observedAt: time, source: "spleen", evidence: .spleenInteraction), now: time)
        }
        record(a, at: now.addingTimeInterval(-2))
        record(b, at: now.addingTimeInterval(-1))
        let fromB = RelevanceSnapshot(state: state, catalog: CatalogCache(), context: memory, now: now)
        XCTAssertEqual(fromB.ordered.map(\.id), [a.id, pin.id, b.id])
        record(a, at: now)
        let fromA = RelevanceSnapshot(state: state, catalog: CatalogCache(), context: memory, now: now)
        XCTAssertEqual(fromA.ordered.map(\.id), [b.id, pin.id, a.id])
        XCTAssertEqual(fromB.ordered.first?.id, a.id, "An existing invocation remains unchanged")
        XCTAssertEqual(fromA.results(query: "Conversation A").first?.id, a.id, "Current conversation remains searchable")
        XCTAssertEqual(state.destinations.first, pin, "Ranking preserves the saved pin and label")
    }

    func testCurrentPinCannotTakeCenterAndProviderIdentityIsPreserved() {
        let id = "01234567-89ab-cdef-0123-456789abcdef"
        let current = Destination(title: "Codex", threadID: id, pinned: true, lastOpenedAt: now)
        let other = Destination(title: "Claude", threadID: id, provider: .claude)
        var state = SavedState(); state.destinations = [current, other]
        let snapshot = RelevanceSnapshot(state: state, catalog: CatalogCache(), now: now)
        XCTAssertEqual(snapshot.ordered.map(\.id), [other.id, current.id])
        XCTAssertEqual(snapshot.results(query: "Codex").first?.id, current.id)
    }

    func testLastSelectedThreadStaysVisibleWhileWorkingOrUnread() {
        let current = Destination(title: "Add instrument capabilities", threadID: "thr_current_fixture", lastOpenedAt: now)
        let pins = (0..<2).map { Destination(title: "Reference \($0)", threadID: "thr_pin_fixture_\($0)", pinned: true) }
        var state = SavedState()
        state.destinations = pins + [current] + (0..<8).map {
            Destination(title: "Older conversation \($0)", threadID: "thr_other_fixture_\($0)")
        }
        var memory = ContextMemory()
        memory.record(ContextEvent(key: current.conversationKey, kind: .spleenDispatch,
            observedAt: now, source: "spleen", evidence: .spleenInteraction), now: now)
        for (activity, unread) in [(RuntimeActivity.working, false), (.idle, true), (.waitingForApproval, false), (.waitingForInput, false)] {
            var attention = SessionAttention()
            XCTAssertTrue(attention.accept(LiveSessionState(key: current.conversationKey, source: "fixture",
                observedAt: now, sequence: 1, activity: activity, isUnread: unread), now: now))
            let prepared = PreparedContext(state: state, catalog: CatalogCache(), context: memory,
                now: now, uptime: 100, attention: attention)
            let snapshot = prepared.snapshot(now: now, uptime: 100)
            XCTAssertEqual(snapshot.currentKey, current.conversationKey, "Dispatch history remains a hint, not proof of foreground selection")
            XCTAssertTrue(snapshot.ordered.prefix(5).contains(current), "Last selection must not hide fresh \(activity)/unread=\(unread) evidence")
            XCTAssertNotEqual(snapshot.ordered.first, current, "A different conversation remains the center")
            XCTAssertEqual(Array(snapshot.ordered.dropFirst().prefix(2)), pins)
            XCTAssertEqual(snapshot.results(query: current.title).first, current)
            // Live lifetimes are not scheduled into the prepared context: the app's heartbeat
            // expires lapsed samples and rebuilds.
            var lapsed = attention
            XCTAssertTrue(lapsed.expireLive(at: now.addingTimeInterval(15)))
            let rebuilt = PreparedContext(state: state, catalog: CatalogCache(), context: memory,
                now: now.addingTimeInterval(15), uptime: 115, attention: lapsed)
            let expired = rebuilt.snapshot(now: now.addingTimeInterval(15), uptime: 115)
            XCTAssertEqual(expired.ordered.last, current, "Expired live evidence alone does not manufacture interaction history")
        }
    }

    func testCatalogAndClaudeRecencyCannotDisplaceFreshLiveAttention() {
        let current = Destination(title: "Current selection", threadID: "thr_current_fixture", lastOpenedAt: now)
        let pins = (0..<2).map { Destination(title: "Reference \($0)", threadID: "thr_pin_fixture_\($0)", pinned: true) }
        let active = (0..<3).map { Destination(title: "Working conversation \($0)", threadID: "thr_working_fixture_\($0)") }
        let claude = ConversationKey(provider: .claude, id: "desktop-code:local_01234567-89ab-cdef-0123-456789abcdef")
        var state = SavedState(); state.destinations = pins + [current] + active
        var catalog = CatalogCache(); catalog.folders = ["/switcher", "/music"]
        catalog.entries = ([current] + active).map {
            CatalogEntry(id: $0.threadID, title: $0.title, folder: "/switcher", updatedAt: now.addingTimeInterval(-3600))
        }
        catalog.entries.append(CatalogEntry(id: "thr_newest_fixture", title: "Latest catalog update", folder: "/music", updatedAt: now))
        var attention = SessionAttention()
        for item in active {
            XCTAssertTrue(attention.accept(LiveSessionState(key: item.conversationKey, source: "fixture",
                observedAt: now, sequence: 1, activity: .working, isUnread: nil), now: now))
        }
        var memory = ContextMemory()
        memory.record(ContextEvent(key: claude, topic: "Visited Claude", kind: .selectedConversation,
            observedAt: now.addingTimeInterval(-3600), source: "claude-desktop-accessibility", evidence: .observedSelection), now: now)
        let snapshot = RelevanceSnapshot(state: state, catalog: catalog, context: memory, now: now, attention: attention)
        XCTAssertEqual(Set(snapshot.ordered.prefix(5).map(\.id)), Set((pins + active).map(\.id)),
            "Historical catalog/visit fallbacks must not replace fresh working threads")
        XCTAssertTrue(snapshot.results(query: "Visited Claude").contains { $0.conversationKey == claude })
        XCTAssertTrue(snapshot.results(query: "Latest catalog update").contains { $0.threadID == "thr_newest_fixture" })
    }

    func testRecentSelectionSurvivesQuietTurnAgainstOldUnansweredChats() {
        let current = Destination(title: "Current work", threadID: "thr_current_recent", lastOpenedAt: now)
        let recent = Destination(title: "Recently started experiment", threadID: "thr_recent_experiment", lastOpenedAt: now.addingTimeInterval(-10))
        let pin = Destination(title: "Pinned reference", threadID: "thr_pin_recent", pinned: true)
        let old = (0..<8).map { Destination(title: "Old unanswered chat \($0)", threadID: "thr_old_unanswered_\($0)") }
        var state = SavedState(); state.destinations = [pin, current, recent] + old
        var memory = ContextMemory()
        for (item, age) in [(recent, 10.0), (current, 0.0)] {
            memory.record(ContextEvent(key: item.conversationKey, kind: .spleenDispatch,
                observedAt: now.addingTimeInterval(-age), source: "spleen", evidence: .spleenInteraction), now: now)
        }
        var attention = SessionAttention()
        for item in old {
            attention.windows[item.conversationKey] = SessionWindow(key: item.conversationKey,
                sourceUpdatedAt: now.addingTimeInterval(-30 * 86400),
                messages: [RecentMessage(id: "old_prompt", role: .user, text: "Continue this task")])
        }
        attention.accept(LiveSessionState(key: recent.conversationKey, source: "fixture", observedAt: now,
            lifetime: 15, sequence: 1, activity: .working, isUnread: nil), now: now)
        let prepared = PreparedContext(state: state, catalog: CatalogCache(), context: memory,
            now: now, uptime: 100, attention: attention)
        let quiet = now.addingTimeInterval(16)
        let snapshot = prepared.snapshot(now: quiet, uptime: 116)
        XCTAssertTrue(snapshot.ordered.prefix(5).contains(recent), "Recent work must survive the gap between real callbacks")
        XCTAssertEqual(snapshot.ordered.first, recent, "Recent explicit interaction outranks historical unanswered text")
        XCTAssertNil(attention.liveState(for: recent.conversationKey, at: quiet), "Retention is not a fabricated spinner heartbeat")
        XCTAssertTrue(snapshot.ordered.prefix(5).contains(pin))
    }

    func testSavedRecentSelectionSurvivesMissingAuditEvent() {
        let current = Destination(title: "Current work", threadID: "thr_current_saved", lastOpenedAt: now)
        let recent = Destination(title: "Recent experiment", threadID: "thr_recent_saved", lastOpenedAt: now.addingTimeInterval(-60))
        let old = (0..<8).map { Destination(title: "Older match \($0)", threadID: "thr_older_saved_\($0)") }
        var state = SavedState(); state.destinations = [current, recent] + old
        var memory = ContextMemory()
        memory.record(ContextEvent(key: current.conversationKey, topic: "Older match", kind: .spleenDispatch,
            observedAt: now, source: "spleen", evidence: .spleenInteraction), now: now)
        let snapshot = RelevanceSnapshot(state: state, catalog: CatalogCache(), context: memory, now: now)
        XCTAssertEqual(snapshot.ordered.first, recent, "A durable selection timestamp does not depend on retaining its audit event")
    }

    func testRecentProviderWorkKeepsLastSelectedThreadNearbyUntilHistoryExpires() {
        let current = Destination(title: "Recently active work", threadID: "thr_recent_provider", lastOpenedAt: now)
        let other = (0..<8).map { Destination(title: "Alternative \($0)", threadID: "thr_recent_alternative_\($0)") }
        var state = SavedState(); state.destinations = [current] + other
        var attention = SessionAttention()
        attention.rememberActivity([current.conversationKey: now], at: now)
        let prepared = PreparedContext(state: state, catalog: CatalogCache(), now: now, uptime: 100, attention: attention)
        let quiet = prepared.snapshot(now: now.addingTimeInterval(20), uptime: 120)
        XCTAssertTrue(quiet.ordered.prefix(5).contains(current))
        XCTAssertNotEqual(quiet.ordered.first, current, "The last-selected chat still does not take the center")
        XCTAssertNil(attention.liveState(for: current.conversationKey, at: now.addingTimeInterval(20)))
        var oldState = state; oldState.destinations[0].lastOpenedAt = nil
        let expired = RelevanceSnapshot(state: oldState, catalog: CatalogCache(), now: now.addingTimeInterval(1800), attention: attention)
        XCTAssertNil(attention.recentActivityAt(for: current.conversationKey, at: now.addingTimeInterval(1800)))
        XCTAssertEqual(expired.ordered, RelevanceSnapshot(state: oldState, catalog: CatalogCache(), now: now.addingTimeInterval(1800)).ordered)
    }

    func testRelatedAlternativeBeatsUnrelatedPinWithoutPreviousInteraction() {
        let current = Destination(title: "SQLite transaction contention", threadID: "thr_current_fixture", lastOpenedAt: now)
        let pin = Destination(title: "Piano reference", threadID: "thr_pin_fixture", pinned: true)
        let related = Destination(title: "SQLite transaction investigation", threadID: "thr_related_fixture")
        var state = SavedState(); state.destinations = [pin, current, related]
        let snapshot = RelevanceSnapshot(state: state, catalog: CatalogCache(), now: now)
        XCTAssertEqual(snapshot.ordered.map(\.id), [related.id, pin.id, current.id])
    }

    func testMissingPreviousDestinationFallsBackToAvailableAlternatives() {
        let current = Destination(title: "Current", threadID: "thr_current_fixture", lastOpenedAt: now)
        let other = Destination(title: "Available", threadID: "thr_other_fixture")
        var state = SavedState(); state.destinations = [current, other]
        var memory = ContextMemory()
        for (key, time) in [(ConversationKey(provider: .codex, id: "thr_removed_fixture"), now.addingTimeInterval(-1)),
                            (current.conversationKey, now)] {
            memory.record(ContextEvent(key: key, kind: .spleenDispatch, observedAt: time,
                source: "spleen", evidence: .spleenInteraction), now: now)
        }
        let snapshot = RelevanceSnapshot(state: state, catalog: CatalogCache(), context: memory, now: now)
        XCTAssertEqual(snapshot.ordered.map(\.id), [other.id, current.id])
    }

    func testColdStartKeepsPinsOnArmsAndHandlesSingleOrEmptyCatalogs() {
        let pin = Destination(title: "Pin", threadID: "thr_pin_fixture", pinned: true)
        let other = Destination(title: "Other", threadID: "thr_other_fixture")
        var state = SavedState(); state.destinations = [pin, other]
        XCTAssertEqual(RelevanceSnapshot(state: state, catalog: CatalogCache(), now: now).ordered.map(\.id), [other.id, pin.id])
        state.destinations = [pin]; state.recordDispatch(pin.id, at: now)
        XCTAssertEqual(RelevanceSnapshot(state: state, catalog: CatalogCache(), now: now).ordered.map(\.id), [pin.id])
        state.destinations = []
        XCTAssertTrue(RelevanceSnapshot(state: state, catalog: CatalogCache(), now: now).ordered.isEmpty)
    }

    func testRecentCrossProjectActivitySurvivesCrowdedTopicSuggestions() {
        let current = Destination(title: "Switcher ranking", threadID: "thr_current_fixture", lastOpenedAt: now)
        let pins = (0..<2).map { Destination(title: "Reference \($0)", threadID: "thr_pin_fixture_\($0)", pinned: true) }
        var state = SavedState(); state.destinations = pins + [current]
        var catalog = CatalogCache(); catalog.folders = ["/switcher", "/instrument"]
        catalog.entries = [CatalogEntry(id: current.threadID, title: current.title, folder: "/switcher", updatedAt: now)]
        catalog.entries += (0..<8).map { CatalogEntry(id: "thr_related_fixture_\($0)", title: "Switcher ranking \($0)",
            folder: "/switcher", updatedAt: now.addingTimeInterval(-3600 - Double($0))) }
        catalog.entries.append(CatalogEntry(id: "thr_new_switcher_fixture", title: "New panel", folder: "/switcher",
            updatedAt: now.addingTimeInterval(-1)))
        let expected = CatalogEntry(id: "thr_instrument_fixture", title: "Open instrument", folder: "/instrument",
            updatedAt: now.addingTimeInterval(-60))
        catalog.entries.append(expected)

        let snapshot = RelevanceSnapshot(state: state, catalog: catalog, now: now)
        XCTAssertEqual(snapshot.ordered.first?.threadID, "thr_related_fixture_0", "Relevance still chooses the center")
        XCTAssertEqual(Array(snapshot.ordered.dropFirst().prefix(2)), pins, "Both pins keep their places")
        XCTAssertEqual(snapshot.ordered[4].threadID, expected.id, "New same-project chats cannot crowd out activity elsewhere")
        XCTAssertEqual(snapshot.subtitles[expected.destination.conversationKey], "Codex · Latest activity · instrument")
        XCTAssertEqual(snapshot.ordered.last?.id, current.id, "Activity never promotes the current conversation")
        XCTAssertEqual(Set(snapshot.ordered.map(\.conversationKey)).count, snapshot.ordered.count)
        XCTAssertEqual(snapshot.results(query: expected.title).first?.threadID, expected.id)
        XCTAssertEqual(snapshot.ordered.filter { $0.threadID.hasPrefix("thr_related_fixture_") }.map(\.threadID),
                       (0..<8).map { "thr_related_fixture_\($0)" }, "Remaining relevance order stays stable")
    }

    func testActivityAlreadyVisibleDoesNotDisplaceAnotherRelevantChoice() {
        let current = Destination(title: "Database locks", threadID: "thr_current_fixture", lastOpenedAt: now)
        var state = SavedState(); state.destinations = [current]
        var catalog = CatalogCache(); catalog.folders = ["/database", "/music"]
        catalog.entries = (0..<6).map { CatalogEntry(id: "thr_related_fixture_\($0)", title: "Database locks \($0)",
            folder: "/database", updatedAt: now.addingTimeInterval(-Double($0))) }
        catalog.entries.append(CatalogEntry(id: "thr_music_fixture", title: "Open instrument", folder: "/music",
            updatedAt: now.addingTimeInterval(-60)))
        let snapshot = RelevanceSnapshot(state: state, catalog: catalog, now: now)
        XCTAssertEqual(snapshot.ordered.prefix(5).map(\.threadID), (0..<5).map { "thr_related_fixture_\($0)" })
        XCTAssertFalse(snapshot.subtitles.values.contains { $0.contains("Latest activity") })
    }

    func testActivityPromotionHonorsVisibilityProviderAndTimestamp() {
        let current = Destination(title: "Database locks", threadID: "thr_current_fixture", lastOpenedAt: now)
        let sharedID = "01234567-89ab-cdef-0123-456789abcdef"
        let claude = Destination(title: "Instrument", threadID: sharedID, provider: .claude)
        var state = SavedState(); state.destinations = [current, claude]
        var catalog = CatalogCache(); catalog.folders = ["/database", "/music"]
        catalog.entries = (0..<6).map { CatalogEntry(id: "thr_related_fixture_\($0)", title: "Database locks \($0)",
            folder: "/database", updatedAt: now.addingTimeInterval(-3600 - Double($0))) }
        catalog.entries += [
            CatalogEntry(id: "thr_future_fixture", title: "Future", folder: "/music", updatedAt: now.addingTimeInterval(1)),
            CatalogEntry(id: "thr_excluded_fixture", title: "Excluded", folder: "/excluded", updatedAt: now),
            CatalogEntry(id: sharedID, title: "Hidden", folder: "/music", updatedAt: now),
            CatalogEntry(id: "thr_visible_fixture", title: "Open instrument", folder: "/music", updatedAt: now.addingTimeInterval(-60))
        ]
        catalog.hiddenIDs = [sharedID]
        let snapshot = RelevanceSnapshot(state: state, catalog: catalog, now: now)
        XCTAssertEqual(snapshot.ordered[4].threadID, "thr_visible_fixture")
        XCTAssertFalse(snapshot.ordered.prefix(5).contains { $0.provider == .claude || $0.threadID == "thr_future_fixture" })
        XCTAssertFalse(snapshot.ordered.contains { $0.threadID == "thr_excluded_fixture" || ($0.provider == .codex && $0.threadID == sharedID) })
        XCTAssertEqual(snapshot.subtitles[claude.conversationKey], "Claude · Saved chat")
    }
}
