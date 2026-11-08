import AppKit
import SwiftUI
import SpleenCore

final class AppModel: ObservableObject {
    typealias SnapshotBuilder = (SavedState, CatalogCache, [ThreadInsight], ContextMemory, Date, TimeInterval, SessionAttention) -> PreparedContext
    @Published private(set) var state = SavedState()
    @Published var query = "" { didSet { if !preparingInvocation && query != oldValue { freezeOpening(); refreshResults() } } }
    private var preparingInvocation = false
    private(set) var resultRefreshCount = 0
    @Published private(set) var results: [Destination] = []
    @Published var selectedID: UUID? {
        didSet { if !preparingInvocation && selectedID != oldValue { freezeOpening() } }
    }
    @Published var error: String?
    @Published var mode: Mode = .compass
    @Published var editorID: UUID?
    @Published private(set) var editorCanRemove = false
    private var editorConversationKey: ConversationKey?
    @Published var editorTitle = ""
    @Published var editorLink = ""
    @Published var editorPinned = false
    @Published var shortcutDraft = Shortcut()
    @Published var dotLinkDraft = ""
    var dotURL: URL? { state.dotLink.flatMap { try? DotTarget($0).url } }
    var openDot: (() -> Void)?
    @Published var rememberDraft = true
    @Published var navigationFirstDraft = false
    private var navigationFirst = false
    var usesNavigationCompass: Bool { navigationFirst }
    private var readyNavigation = NavigationCompass(state: SavedState(), catalog: CatalogCache(), now: Date(), uptime: 0)
    private var readyNavigationNeutral = NavigationCompass(state: SavedState(), catalog: CatalogCache(), now: Date(), uptime: 0)
    @Published var automaticDiscoveryDraft = false
    @Published var observeCodexDraft = false
    @Published private(set) var codexContextStatus = "Off · Codex navigation observation is optional."
    private var observesCodex = false
    private var codexObserver: CodexDesktopObserver?
    @Published var observeClaudeDraft = false
    @Published private(set) var claudeContextStatus = "Off · Claude Desktop context is optional."
    private var observesClaude = false
    private var claudeObserver: ClaudeDesktopObserver?
    private var claudeStatusObserver: ClaudeDesktopStatusObserver?
    private var claudeReplyTimes = ClaudeReplyTimes()
    private var visibleClaudeReplyTimes: ClaudeReplyTimes?
    private var claudeReplyURL: URL { repository.url.deletingLastPathComponent().appendingPathComponent("claude-reply-times.json") }
    private var contextSettingsURL: URL { repository.url.deletingLastPathComponent().appendingPathComponent("context-settings.json") }
    @Published var shortcutStatus = ""
    enum Mode { case compass, search, editor, settings }
    @Published private(set) var compassItems: [Destination] = []
    @Published private(set) var recentSessions: [RecentSession] = []
    @Published private(set) var browsingRecents = false
    private var recentReturnID: UUID?
    private var pendingRecentEntry = false
    private var readyRecents = PreparedContext.empty.recentSessions
    @Published private(set) var catalog = CatalogCache()
    @Published private(set) var catalogStatus = "Saved chats"
    @Published private(set) var refreshing = false
    @Published private(set) var updateReady = false
    @Published private(set) var prepareMilliseconds = 0.0
    private var visibleSnapshot: RelevanceSnapshot?
    private var visibleOrder: [Destination]?
    private var readyOrder: [Destination] = []
    private var readyRankingExpiresAt = 0.0
    private var preparedContext = PreparedContext.empty
    /// Constructed on interaction/publication, never by scanning during hotkey opening.
    private struct ImmediateReturn {
        let order: [Destination]
        let builtAt: Date
        let builtUptime: TimeInterval
        let expiresAt: Date
        let expiresUptime: TimeInterval
        func isFresh(now: Date, uptime: TimeInterval) -> Bool {
            now >= builtAt && uptime >= builtUptime && now < expiresAt && uptime < expiresUptime
        }
    }
    private var immediateReturn: ImmediateReturn?
    private var openingRefinementGeneration: Int?
    private var visibleInitialReturnKey: ConversationKey?
    private let now: () -> Date
    private let uptime: () -> TimeInterval
    private var preparedSnapshot: RelevanceSnapshot { preparedContext.snapshot(now: now(), uptime: uptime()) }
    private var preparedOrder: [Destination] {
        if navigationFirst {
            let instant = now()
            let newest = readyRecents.visibleEntries(now: instant, uptime: uptime()).first
            let hasFreshSelection = newest.map { instant.timeIntervalSince($0.interaction.date) < ContextMemory.hintLifetime } ?? false
            let navigation = hasFreshSelection ? readyNavigation : readyNavigationNeutral
            return navigation.visibleEntries(now: now(), uptime: uptime(), limit: ContextMemory.maximumEvents).map(\.destination)
        }
        return preparedContext.isFresh(now: now(), uptime: uptime()) && uptime() < readyRankingExpiresAt
            ? readyOrder : preparedSnapshot.ordered
    }
    private(set) var context = ContextMemory()
    private var contextFingerprint: Data?
    private var contextReadGeneration = 0
    private var contextSignature: ContextRelevanceSignature?
    private let contextQueue = DispatchQueue(label: "spleen.context", qos: .utility)
    private let contextReader: (URL) throws -> ContextMemory
    private var contextMonitor: ContextMonitor?
    private var contextURL: URL { repository.url.deletingLastPathComponent().appendingPathComponent("context.json") }
    private var ranking = RankingPipeline()
    private let rankingTransport: DecisionsTransport?
    private var rankingInput: RankingInput?
    private var cancelRanking: (() -> Void)?
    private var rankingTimeout: DispatchWorkItem?
    private var activeRankingJobID: UUID?
    private let rankingResponseQueue = DispatchQueue(label: "spleen.prediction-response", qos: .utility)
    private var relevance = RelevancePipeline()
    private var presentationGeneration = 0
    private var pendingVisibleAdoption: Int?
    @Published private(set) var indexing = false
    private var insights = InsightCache()
    @Published private(set) var attention = SessionAttention()
    private var assessmentTransport: DecisionsTransport?
    @Published private(set) var automaticAssessmentEnabled = false
    @Published private(set) var automaticAssessmentStatus = "Off · nothing is sent when you open Spleen."
    private var automaticConsent: AutomaticAttentionConsent?
    /// Codex cards shown by the latest press. Assessment on open only sends these, briefly.
    private var openTargets = Set<ConversationKey>()
    private var openTargetsUntil = -Double.infinity
    private var dailyLimitDay: String?
    private var openAssessmentsSent = 0
    @Published var decisionReviewStatus = "Off · Review a conversation before sending it."
    @Published var decisionReviewBusy = false
    private var cancelReviewedAssessment: (() -> Void)?
    private var reviewedTransport: DecisionsTransport?
    private var reviewedJob: UUID?
    private var assessmentAttempts = Set<String>()
    private var assessmentActive: UUID?
    private var assessmentSelecting = false
    private var assessmentEpoch = UUID()
    private var cancelAssessment: (() -> Void)?
    private var assessmentTimeout: DispatchWorkItem?
    private var assessmentCache: [String: AssessedSession] = [:]
    private var attentionTimer: Timer?
    private var activityMonitor: ContextMonitor?
    private let desktopReadFetcher: (([ConversationKey], Date, UInt64, String) throws -> [LiveSessionState])?
    private let desktopReadQueue = DispatchQueue(label: "spleen.desktop-read-state", qos: .utility)
    private let desktopReadEpoch = UUID().uuidString
    private var desktopReadSequence: UInt64 = 0
    private var desktopReadBusy = false
    private var lastDesktopReadPoll = -Double.infinity
    @Published private(set) var unreadIndicatorStatus = "Desktop unread indicators off."
    private var activityReadGeneration = 0
    private var lastCompletionReportID: UUID?
    private var lastDiscoveryReportID: UUID?
    private var activityURL: URL { repository.url.deletingLastPathComponent().appendingPathComponent("activity-hooks.json") }
    @Published private(set) var liveIndicatorStatus = "Live indicators: checking sources…"
    private var assessmentURL: URL { repository.url.deletingLastPathComponent().appendingPathComponent("assessments.json") }
    private var pendingTimingBackfill = false
    private var enriching = false
    private var enrichmentRevision = 0
    private let snapshotScheduler = LatestSnapshotScheduler()
    private let snapshotBuilder: SnapshotBuilder
    private let insightSaveQueue = DispatchQueue(label: "spleen.insight-cache", qos: .utility)
    private var insightURL: URL { repository.url.deletingLastPathComponent().appendingPathComponent("relevance.json") }
    private var isPresented = false
    private var catalogRevision = 0
    private var lastRefreshAttempt = Date.distantPast
    private var catalogLoadFailed = false
    private let catalogSaveQueue = DispatchQueue(label: "spleen.catalog-cache", qos: .utility)
    private let catalogWriter: (CatalogCache, URL) throws -> Void
    private var catalogWriteRevision = 0
    private(set) var catalogPersistencePending = 0
    private(set) var snapshotBuildCount = 0
    private let catalogFetcher: (DiscoveryPolicy) throws -> (entries: [CatalogEntry], truncated: Bool)
    private let insightFetcher: ([CatalogEntry], DiscoveryPolicy) throws -> [ThreadInsight]
    private var catalogURL: URL { repository.url.deletingLastPathComponent().appendingPathComponent("catalog.json") }
    let repository: StateRepository
    private var loadFailed = false
    var openDestination: ((Destination) -> Void)?
    var changeShortcut: ((Shortcut) throws -> Void)?
    var cancel: (() -> Void)?
    var catalogDiscoveryEnabled: Bool { catalog.effectivePolicy.scope == .automaticProjects || !catalog.folders.isEmpty }
    var hasHiddenChats: Bool {
        !catalog.hiddenIDs.isEmpty || catalog.effectivePolicy.excludedConversationIDs.contains {
            $0.provider == .claude && (try? ClaudeDesktopCodeTarget(conversationID: $0.id)) != nil
        }
    }

    init(repository: StateRepository, initialFolders: [String] = [],
         catalogFetcher: (([String]) throws -> (entries: [CatalogEntry], truncated: Bool))? = nil,
         insightFetcher: (([CatalogEntry], [String]) throws -> [ThreadInsight])? = nil,
         discoveryFetcher: ((DiscoveryPolicy) throws -> (entries: [CatalogEntry], truncated: Bool))? = nil,
         rankingTransport: DecisionsTransport? = nil,
         assessmentTransport: DecisionsTransport? = nil,
         automaticConsent: AutomaticAttentionConsent? = nil,
         desktopReadFetcher: (([ConversationKey], Date, UInt64, String) throws -> [LiveSessionState])? = nil,
         now: @escaping () -> Date = Date.init,
         uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         contextReader: @escaping (URL) throws -> ContextMemory = { try ContextRepository(url: $0).load() },
         catalogWriter: @escaping (CatalogCache, URL) throws -> Void = CatalogPersistence.write,
         snapshotBuilder: @escaping SnapshotBuilder = { state, catalog, notes, memory, instant, tick, attention in
             PreparedContext(state: state, catalog: catalog, insights: notes, context: memory, now: instant, uptime: tick, attention: attention)
         }) {
        self.now = now; self.uptime = uptime; self.catalogWriter = catalogWriter; self.contextReader = contextReader
        self.snapshotBuilder = snapshotBuilder
        self.catalogFetcher = discoveryFetcher ?? { policy in
            if let catalogFetcher { return try catalogFetcher(policy.folders) }
            return try CodexCatalogClient().fetch(policy: policy)
        }
        self.insightFetcher = { entries, policy in
            if let insightFetcher { return try insightFetcher(entries, policy.folders) }
            return try CodexCatalogClient().insights(entries: entries, policy: policy)
        }
        self.rankingTransport = rankingTransport
        self.assessmentTransport = assessmentTransport
        self.automaticConsent = automaticConsent
        self.automaticAssessmentEnabled = automaticConsent != nil && assessmentTransport != nil
        if let automaticConsent { automaticAssessmentStatus = Self.openAssessmentOnStatus(automaticConsent) }
        self.desktopReadFetcher = desktopReadFetcher
        self.repository = repository
        do { state = try repository.load() }
        catch { loadFailed = true; state.rememberRecents = false; self.error = "Couldn't load saved destinations: \(error.localizedDescription) The file was left untouched: \(repository.url.path)" }
        if FileManager.default.fileExists(atPath: catalogURL.path) {
            do { catalog = try CatalogCache.load(from: catalogURL) }
            catch { catalogLoadFailed = true; catalogStatus = "Catalog cache needs repair; saved chats available" }
        } else if !loadFailed && !initialFolders.isEmpty {
            catalog.folders = Array(initialFolders.prefix(10)); saveCatalog()
        } else if !loadFailed && !FileManager.default.fileExists(atPath: repository.url.path) {
            catalog.version = 2; catalog.policy = DiscoveryPolicy(pageSize: 100, maxPages: 10)
            saveCatalog()
        }
        if catalogDiscoveryEnabled && !catalogLoadFailed { catalogStatus = "Cached chats · ready" }
        insights = (try? InsightCache.load(from: insightURL)) ?? InsightCache()
        insights.retain(catalog: catalog)
        pendingTimingBackfill = insights.entries.contains { $0.timing == nil || $0.window == nil }
        if let data = try? Data(contentsOf: assessmentURL), data.count <= 500_000,
           let cache = try? JSONDecoder().decode([String: AssessedSession].self, from: data), cache.count <= 2000 {
            assessmentCache = cache
        }
        attentionTimer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.attention.expireLive(at: self.now()) { self.rebuildSnapshot() }
            self.pollDesktopReadState()
        }
        if let attentionTimer { RunLoop.main.add(attentionTimer, forMode: .common) }
        context = loadFailed ? ContextMemory(recentsEnabled: false) : (try? ContextRepository(url: contextURL).load()) ?? ContextMemory()
        let storedRecentsEnabled = context.recentsEnabled
        context.setRecentsEnabled(state.rememberRecents)
        context.prune(now: now())
        contextFingerprint = Self.contextData(context)
        if !loadFailed && storedRecentsEnabled != state.rememberRecents {
            let enabled = state.rememberRecents, url = contextURL
            contextQueue.async { _ = try? ContextRepository(url: url).setRecentsEnabled(enabled, clear: !enabled) }
        }
        if !loadFailed { contextMonitor = ContextMonitor(directory: repository.url.deletingLastPathComponent(), changed: { [weak self] in
            DispatchQueue.main.async { self?.reloadContext() }
        }) }
        if !loadFailed, let data = try? Data(contentsOf: contextSettingsURL), data.count <= 4096,
           let settings = try? JSONDecoder().decode([String: Bool].self, from: data) {
            observesClaude = settings["observeClaudeDesktop"] ?? false
            observesCodex = settings["observeCodexDesktop"] ?? false
            navigationFirst = settings["navigationFirstCompass"] ?? false
        }
        if !loadFailed && state.rememberRecents {
            claudeReplyTimes = (try? ClaudeReplyTimes.load(from: claudeReplyURL)) ?? ClaudeReplyTimes()
        }
        DispatchQueue.main.async { [weak self] in self?.configureClaudeObserver(promptForPermission: false); self?.configureCodexObserver(promptForPermission: false) }
        if !loadFailed {
            activityMonitor = ContextMonitor(directory: repository.url.deletingLastPathComponent(), fileName: "activity-hooks.json") { [weak self] in
                DispatchQueue.main.async { self?.reloadActivityReports() }
            }
        }
        rebuildSnapshot()
    }
    func refreshResults() {
        resultRefreshCount += 1
        results = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (visibleOrder ?? preparedOrder) : (visibleSnapshot ?? preparedSnapshot).results(query: query)
        if !results.contains(where: { $0.id == selectedID }) { selectedID = results.first?.id }
    }
    func prepare() {
        let start = ProcessInfo.processInfo.systemUptime
        let instant = now(), tick = uptime()
        let fresh = preparedContext.isFresh(now: instant, uptime: tick)
        let snapshot = preparedContext.snapshot(now: instant, uptime: tick)
        visibleSnapshot = snapshot
        visibleClaudeReplyTimes = claudeReplyTimes
        let ranked = navigationFirst ? preparedOrder : (fresh && tick < readyRankingExpiresAt ? readyOrder : snapshot.ordered)
        let immediate = immediateReturn.flatMap { $0.isFresh(now: instant, uptime: tick) ? $0.order : nil }
        let order = immediate ?? ranked
        visibleInitialReturnKey = immediate?.first?.conversationKey
        visibleOrder = order
        presentationGeneration += 1
        isPresented = true; updateReady = false
        mode = .compass
        preparingInvocation = true; query = ""
        results = order; compassItems = Array(order.prefix(5)); selectedID = order.first?.id
        recentSessions = readyRecents.visibleEntries(now: instant, uptime: tick)
        browsingRecents = false; recentReturnID = nil; pendingRecentEntry = false
        preparingInvocation = false
        openingRefinementGeneration = immediate != nil && (indexing || order != ranked) ? presentationGeneration : nil
        let invocation = presentationGeneration
        prepareMilliseconds = (ProcessInfo.processInfo.systemUptime - start) * 1000
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.presentationGeneration == invocation { self.refineOpeningIfReady() }
            self.refreshCatalog()
            self.pollDesktopReadState(force: true)
            if self.automaticConsent != nil {
                // Finish this press's cards even if the panel closes; nothing after 30 seconds.
                self.openTargets = Set(self.compassItems.filter { $0.provider == .codex }.map(\.conversationKey))
                self.openTargetsUntil = self.uptime() + 30
                self.assessChangedSessions()
            }
            if !self.indexing && (!self.preparedContext.isFresh(now: self.now(), uptime: self.uptime()) ||
                !self.readyRecents.isFresh(now: self.now(), uptime: self.uptime())) { self.rebuildSnapshot() }
        }
    }
    func endPresentation() { freezeOpening(); visibleInitialReturnKey = nil; presentationGeneration += 1; isPresented = false; visibleSnapshot = nil; visibleOrder = nil; visibleClaudeReplyTimes = nil }
    func beginSearch(_ text: String = "") {
        freezeOpening(); browsingRecents = false; pendingRecentEntry = false; mode = .search; query = text
        if !results.contains(where: { $0.id == selectedID }) { selectedID = results.first?.id }
    }
    func freezeOpening() { openingRefinementGeneration = nil }
    @discardableResult private func refineOpeningIfReady() -> Bool {
        guard isPresented, openingRefinementGeneration == presentationGeneration,
              !indexing, mode == .compass, query.isEmpty else { return false }
        freezeOpening()
        visibleInitialReturnKey = nil
        let snapshot = preparedSnapshot, order = preparedOrder
        visibleSnapshot = snapshot; visibleOrder = order
        preparingInvocation = true
        results = order; compassItems = Array(order.prefix(5)); selectedID = order.first?.id
        recentSessions = readyRecents.visibleEntries(now: now(), uptime: uptime())
        preparingInvocation = false
        updateReady = false
        return true
    }
    private func prepareImmediateReturn(order: [Destination], current: ConversationKey?, previous: ConversationKey?, at instant: Date) {
        immediateReturn = nil
        guard state.rememberRecents, let current, let previous, previous != current,
              let target = order.first(where: { $0.conversationKey == previous }) else { return }
        let currentAt = context.currentHint(at: instant)?.observedAt ??
            state.destinations.first(where: { $0.conversationKey == current })?.lastOpenedAt
        guard let currentAt, currentAt <= instant,
              instant.timeIntervalSince(currentAt) < ContextMemory.hintLifetime else { return }
        // Keep all other choices in their prepared order, with the just-opened
        // conversation last. This is a navigation default, not a ranking result.
        let remaining = order.filter { $0.conversationKey != previous && $0.conversationKey != current }
        let currentItems = order.filter { $0.conversationKey == current }
        let previousExpiry = context.previousDistinct(at: instant).flatMap {
            $0.key == previous ? $0.observedAt.addingTimeInterval(ContextMemory.retention) : nil
        } ?? .distantFuture
        let tick = uptime(), expiry = min(currentAt.addingTimeInterval(ContextMemory.hintLifetime), previousExpiry)
        immediateReturn = ImmediateReturn(order: [target] + remaining + currentItems, builtAt: instant, builtUptime: tick,
            expiresAt: expiry, expiresUptime: tick + expiry.timeIntervalSince(instant))
    }
    func applyCatalogUpdate() { prepare() }
    func saveCatalog() {
        guard !catalogLoadFailed else { return }
        let value = catalog, url = catalogURL, writer = catalogWriter
        catalogWriteRevision += 1
        let revision = catalogWriteRevision
        catalogPersistencePending += 1
        catalogSaveQueue.async { [weak self] in
            let result = Result { try writer(value, url) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.catalogPersistencePending -= 1
                if case .failure(let error) = result {
                    if case CatalogPersistenceError.corruptExisting = error { self.catalogLoadFailed = true }
                    if revision == self.catalogWriteRevision {
                        self.catalogStatus = "Catalog couldn't be saved; existing cache preserved"
                    }
                }
            }
        }
    }
    func addCatalogFolder(_ path: String) {
        guard !catalogLoadFailed, !catalog.folders.contains(path), catalog.folders.count < 10 else { return }
        catalog.folders.append(path)
        if catalog.policy != nil { catalog.policy?.folders = catalog.folders }
        catalogRevision += 1; saveCatalog(); refreshCatalog(force: true)
    }
    func removeCatalogFolder(_ path: String) {
        catalog.folders.removeAll { $0 == path }; catalog.entries.removeAll { $0.folder == path }
        if catalog.policy != nil { catalog.policy?.folders = catalog.folders }
        catalogRevision += 1; enrichmentRevision += 1; saveCatalog()
        insights.retain(catalog: catalog); saveInsights(); rebuildSnapshot(adoptVisible: true)
        catalogStatus = catalog.folders.isEmpty ? "Saved chats" : "Folder removed"
    }
    func restoreHiddenChats() {
        catalog.hiddenIDs = []
        catalog.policy?.excludedConversationIDs.removeAll {
            $0.provider == .claude && (try? ClaudeDesktopCodeTarget(conversationID: $0.id)) != nil
        }
        saveCatalog(); rebuildSnapshot(adoptVisible: true)
    }
    func refreshCatalog(force: Bool = false) {
        let instant = now(), policy = catalog.effectivePolicy
        let sinceAttempt = instant.timeIntervalSince(lastRefreshAttempt)
        guard !refreshing, !catalogLoadFailed, catalogDiscoveryEnabled,
              force || (policy.shouldRefresh(lastRefreshedAt: catalog.refreshedAt, now: instant) &&
                        (sinceAttempt < 0 || sinceAttempt >= 60)) else { return }
        lastRefreshAttempt = instant; refreshing = true; catalogStatus = "Refreshing chats…"
        let revision = catalogRevision
        let fetcher = catalogFetcher
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Result { try fetcher(policy) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.refreshing = false
                guard revision == self.catalogRevision else { self.refreshCatalog(force: true); return }
                switch result {
                case .success(let value):
                    self.acceptCatalog(entries: value.entries, truncated: value.truncated)
                case .failure:
                    self.catalogStatus = "Refresh unavailable · using saved/cached chats"
                }
            }
        }
    }
    func acceptCatalog(entries: [CatalogEntry], truncated: Bool) {
        let included = entries.filter { catalog.includes($0) }
        let changed = catalog.entries != included
        catalog.entries = included; catalog.truncated = truncated; catalog.refreshedAt = now()
        saveCatalog()
        let count = catalog.effectivePolicy.scope == .automaticProjects ? Set(catalog.entries.map(\.folder)).count : catalog.folders.count
        catalogStatus = "\(catalog.entries.count) discovered · \(count) project\(count == 1 ? "" : "s")" + (truncated ? " · more available" : "")
        if changed { enrichmentRevision += 1 }
        insights.retain(catalog: catalog)
        saveInsights()
        if changed { rebuildSnapshot() }
        enrichCatalog()
    }
    private func saveInsights() {
        let value = insights, url = insightURL
        insightSaveQueue.async { try? value.save(to: url) }
    }
    private func rebuildSnapshot(adoptVisible: Bool = false) {
        if adoptVisible && isPresented { pendingVisibleAdoption = presentationGeneration }
        let valid = Dictionary(uniqueKeysWithValues: self.catalog.entries.filter { self.catalog.includes($0) }.map { ($0.id, $0) })
        self.attention.windows = Dictionary(uniqueKeysWithValues: insights.entries.compactMap { note -> (ConversationKey, SessionWindow)? in
            guard valid[note.id]?.updatedAt == note.updatedAt, valid[note.id]?.folder == note.folder,
                  let window = note.window, window.key == ConversationKey(provider: .codex, id: note.id), window.host == "local",
                  window.sourceUpdatedAt == note.updatedAt else { return nil }
            return (window.key, window)
        })
        self.attention.assessments = Dictionary(uniqueKeysWithValues: self.attention.windows.values.compactMap { window in
            assessmentCache[window.contentVersion].map { (window.key, $0) }
        })
        let generation = relevance.begin(), state = state, catalog = catalog, notes = insights.entries, memory = context, attention = attention
        let builtAt = now(), builtUptime = uptime()
        contextSignature = ContextRelevanceSignature(memory, now: builtAt)
        let usesRanking = rankingTransport != nil && !navigationFirst
        indexing = true
        let builder = snapshotBuilder
        snapshotScheduler.submit { [weak self] isCurrent in
            guard isCurrent() else { return }
            DispatchQueue.main.async { [weak self] in self?.snapshotBuildCount += 1 }
            let prepared = builder(state, catalog, notes, memory, builtAt, builtUptime, attention)
            guard isCurrent() else { return }
            let snapshot = prepared.contextual
            let navigationCurrent = prepared.recentSessions.entries.first(where: { $0.interaction.kind != .creation }).flatMap { entry in
                builtAt.timeIntervalSince(entry.interaction.date) < ContextMemory.hintLifetime ? entry.destination.conversationKey : nil
            }
            let navigation = NavigationCompass(state: state, catalog: catalog, context: memory, currentKey: navigationCurrent, now: builtAt, uptime: builtUptime)
            let neutralNavigation = NavigationCompass(state: state, catalog: catalog, context: memory, now: builtAt, uptime: builtUptime)
            let input = usesRanking ? RankingInput(baseline: snapshot.ordered, context: memory, catalog: catalog, insights: notes, now: builtAt, excludingCurrent: snapshot.currentKey) : nil
            guard isCurrent() else { return }
            let body = input.flatMap { try? $0.body(now: builtAt) }.flatMap { $0.count <= 6000 ? $0 : nil }
            guard isCurrent() else { return }
            DispatchQueue.main.async {
                guard let self, self.relevance.finish(snapshot, generation: generation) else { return }
                self.indexing = false
                self.preparedContext = prepared
                self.readyRecents = prepared.recentSessions
                self.readyNavigation = navigation; self.readyNavigationNeutral = neutralNavigation
                if self.rankingInput?.key != input?.key { self.invalidateRanking(); self.readyRankingExpiresAt = 0 }
                self.rankingInput = input
                self.readyOrder = input.map { self.ranking.snapshot(baseline: snapshot.ordered, input: $0, now: self.uptime()) } ?? snapshot.ordered
                let openingSnapshot = self.preparedSnapshot
                self.prepareImmediateReturn(order: self.preparedOrder, current: openingSnapshot.currentKey,
                    previous: openingSnapshot.previousKey, at: self.now())
                // First discovery may arrive after an empty cached index has already completed.
                // Filling an untouched empty invocation cannot move an existing choice or typed search.
                let emptyPresentation = self.isPresented && self.visibleOrder?.isEmpty == true && self.results.isEmpty &&
                    self.query.isEmpty && self.selectedID == nil && (self.mode == .search || self.mode == .compass)
                let adopt = self.pendingVisibleAdoption == self.presentationGeneration || emptyPresentation
                self.pendingVisibleAdoption = nil
                if adopt { self.freezeOpening(); self.visibleInitialReturnKey = nil }
                if !adopt && self.refineOpeningIfReady() { /* One untouched opening refinement. */ }
                else if self.isPresented && !adopt { self.updateReady = self.visibleSnapshot != snapshot }
                else {
                    if self.isPresented {
                        self.visibleSnapshot = self.preparedSnapshot; self.visibleOrder = self.preparedOrder
                        self.compassItems = Array(self.preparedOrder.prefix(5))
                        self.recentSessions = self.readyRecents.visibleEntries(now: self.now(), uptime: self.uptime())
                    }
                    self.updateReady = false
                    self.refreshResults()
                }
                if let input, let body { self.precomputeRanking(input, body: body) }
                self.assessChangedSessions()
                if self.pendingTimingBackfill {
                    self.pendingTimingBackfill = false
                    self.enrichCatalog()
                }
            }
        }
    }
    private func enrichCatalog() {
        guard !enriching else { return }
        // Backfill older excerpts once; a checked result can legitimately have no timestamps.
        let cached = Set(insights.entries.filter { $0.timing != nil && $0.window != nil }.map(\.id))
        let recent = state.rememberRecents ? state.destinations.max { ($0.lastOpenedAt ?? .distantPast) < ($1.lastOpenedAt ?? .distantPast) }?.threadID : nil
        let suggested = Set((visibleOrder ?? preparedOrder).prefix(5).filter { $0.provider == .codex }.map(\.threadID))
        let candidates = catalog.entries.filter { catalog.includes($0) && !cached.contains($0.id) && !catalog.hiddenIDs.contains($0.id) }
            .sorted { a, b in
                if (a.id == recent) != (b.id == recent) { return a.id == recent }
                if suggested.contains(a.id) != suggested.contains(b.id) { return suggested.contains(a.id) }
                return a.updatedAt == b.updatedAt ? a.id < b.id : a.updatedAt > b.updatedAt
            }
        // Reserve half the batch for recent catalog changes, independent of the shortlist.
        let newOrUpdated = candidates.sorted { $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt }
        var batch = Array(newOrUpdated.prefix(4))
        let chosen = Set(batch.map(\.id))
        batch += candidates.filter { !chosen.contains($0.id) }.prefix(8 - batch.count)
        guard !batch.isEmpty else { return }
        enriching = true
        let revision = enrichmentRevision, policy = catalog.effectivePolicy, fetcher = insightFetcher
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let notes = (try? fetcher(batch, policy)) ?? []
            DispatchQueue.main.async {
                guard let self else { return }
                self.enriching = false
                guard revision == self.enrichmentRevision else { self.enrichCatalog(); return }
                let allowed = Dictionary(uniqueKeysWithValues: batch.map { ($0.id, $0) })
                var replacements: [String: ThreadInsight] = [:]
                for note in notes where allowed[note.id]?.folder == note.folder && allowed[note.id]?.updatedAt == note.updatedAt {
                    if replacements[note.id] == nil { replacements[note.id] = note }
                }
                guard !replacements.isEmpty else { return }
                self.insights.entries.removeAll { replacements[$0.id] != nil }
                self.insights.entries += replacements.values.sorted { $0.id < $1.id }
                self.saveInsights(); self.rebuildSnapshot()
            }
        }
    }

    private func pollDesktopReadState(force: Bool = false) {
        guard let fetch = desktopReadFetcher, !desktopReadBusy, !loadFailed else { return }
        let tick = uptime()
        guard force || tick < lastDesktopReadPoll || tick - lastDesktopReadPoll >= (isPresented ? 2 : 10) else { return }
        let allowed = Set(catalog.entries.filter { catalog.includes($0) }.map { ConversationKey(provider: .codex, id: $0.id) })
        var seen = Set<ConversationKey>()
        let recentCandidates = browsingRecents ? recentSessions.filter { $0.id == selectedID }.map(\.destination) + recentSessions.prefix(8).map(\.destination) : []
        let candidates = (recentCandidates + compassItems + Array(results.prefix(12)) + Array(preparedOrder.prefix(5))).map(\.conversationKey)
        let keys = Array(candidates.filter { allowed.contains($0) && seen.insert($0).inserted }.prefix(16))
        guard !keys.isEmpty else { return }
        desktopReadBusy = true; lastDesktopReadPoll = tick; desktopReadSequence += 1
        let sequence = desktopReadSequence, epoch = desktopReadEpoch, instant = now()
        desktopReadQueue.async { [weak self] in
            let result = Result { try fetch(keys, instant, sequence, epoch) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.desktopReadBusy = false
                var changed = false
                switch result {
                case .success(let samples):
                    for sample in samples where keys.contains(sample.key) {
                        let before = self.attention.liveState(for: sample.key, at: self.now())
                        if self.attention.accept(sample, now: self.now()) {
                            let after = self.attention.liveState(for: sample.key, at: self.now())
                            changed = changed || before?.isUnread != after?.isUnread
                        }
                    }
                    self.unreadIndicatorStatus = "Reading desktop unread markers · updates every 2 seconds while open."
                case .failure:
                    changed = self.attention.disconnect(source: CodexDesktopReadStateClient.source, at: self.now())
                    self.unreadIndicatorStatus = "Desktop unread source unavailable or ambiguous · state unknown."
                }
                if changed || !self.preparedContext.isFresh(now: self.now(), uptime: self.uptime()) { self.rebuildSnapshot() }
            }
        }
    }

    private func reloadActivityReports() {
        activityReadGeneration += 1
        let generation = activityReadGeneration, url = activityURL
        contextQueue.async { [weak self] in
            let result = Result { try ActivityHookRepository(url: url).load() }
            DispatchQueue.main.async {
                guard let self, self.activityReadGeneration == generation else { return }
                switch result {
                case .success(let snapshot):
                    if !snapshot.enabled {
                        let cleared = self.attention.clearRecentActivity()
                        if self.attention.disconnect(source: ActivityHookSnapshot.source, at: self.now()) || cleared { self.rebuildSnapshot() }
                        self.liveIndicatorStatus = "Working reports off · Codex hooks need setup."
                    } else {
                        // Fetch new thread metadata when work starts, rather
                        // than waiting for its first assistant reply to finish.
                        if let started = snapshot.events.last(where: { $0.kind == .sessionStarted || $0.kind == .promptSubmitted }),
                           started.id != self.lastDiscoveryReportID {
                            self.lastDiscoveryReportID = started.id
                            if !self.catalog.entries.contains(where: { $0.id == started.key.id }) {
                                self.refreshCatalog(force: true)
                            }
                        }
                        if let completion = snapshot.events.last(where: { $0.kind == .turnCompleted }), completion.id != self.lastCompletionReportID {
                            self.lastCompletionReportID = completion.id
                            self.refreshCatalog(force: true)
                        }
                        var changed = self.attention.rememberActivity(snapshot.recentActivity(at: self.now()), at: self.now())
                        for sample in snapshot.samples(at: self.now()) { changed = self.attention.accept(sample, now: self.now()) || changed }
                        self.liveIndicatorStatus = snapshot.events.isEmpty ? "Waiting for Codex activity reports · review hooks in Codex." : "Receiving Codex activity reports."
                        if changed { self.rebuildSnapshot() }
                    }
                case .failure:
                    let cleared = self.attention.clearRecentActivity()
                    if self.attention.disconnect(source: ActivityHookSnapshot.source, at: self.now()) || cleared { self.rebuildSnapshot() }
                    self.liveIndicatorStatus = "Activity source unavailable · indicators unknown."
                }
            }
        }
    }

    /// Adapter entry point; no timer or prose can fabricate a provider sample.
    func receiveLiveState(_ sample: LiveSessionState) {
        guard attention.accept(sample, now: now()) else { return }
        rebuildSnapshot() // Does not replace the visible card identities.
    }
    func liveState(_ item: Destination) -> LiveSessionState? {
        attention.liveState(for: item.conversationKey, at: now())
    }
    func taskLabel(_ item: Destination) -> String? {
        switch attention.assessment(for: item.conversationKey, at: now()) {
        case .ongoing: return "Work ongoing"
        case .waitingForUser: return "May need your answer"
        case .appearsFinished: return "Appears finished"
        case .unclear: return nil
        }
    }
    private static func openAssessmentOnStatus(_ consent: AutomaticAttentionConsent) -> String {
        "On · assesses changed Codex cards each time you open Spleen · up to \(consent.dailyLimit) requests a day."
    }
    func requestAutomaticAssessment() {
        let alert = NSAlert()
        alert.messageText = "Assess Codex cards each time you open Spleen?"
        alert.informativeText = "Each time you press the Spleen shortcut, Spleen sends OpenAI the latest messages from any Codex card on screen whose text changed since it was last assessed: up to 6 recent user/assistant messages, 6,000 bytes per request. Text may include private topics and paths. No screenshots, tool output or full history, and nothing from Claude. Cards you don't see are never sent. Known secret-like text is skipped, but this is not a guarantee of anonymization. At most \(AutomaticAttentionConsent.defaultDailyLimit) requests a day, well under a cent; the cap is not a billing guarantee. Opening never waits for an answer. Stays on until you pause it; no actions or approvals are automated."
        alert.addButton(withTitle: "Turn on"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let picker = NSOpenPanel(); picker.title = "Choose approved Spleen .env.local"
        picker.canChooseDirectories = false; picker.allowsMultipleSelection = false; picker.showsHiddenFiles = true
        picker.directoryURL = repository.url.deletingLastPathComponent().deletingLastPathComponent()
        guard picker.runModal() == .OK, let url = picker.url else { return }
        do {
            let consent = AutomaticAttentionConsent(enabled: true, id: "open-" + UUID().uuidString,
                dailyLimit: AutomaticAttentionConsent.defaultDailyLimit, credentialPath: url.path, scope: AutomaticAttentionConsent.scopeName)
            let directory = repository.url.deletingLastPathComponent()
            let transport = try consent.transport(in: directory)
            try consent.save(in: directory)
            activateAutomaticAssessment(consent: consent, transport: transport)
        } catch { automaticAssessmentStatus = "Setup failed; no requests started." }
    }
    /// Sends nothing by itself: the next shortcut press starts assessment.
    func activateAutomaticAssessment(consent: AutomaticAttentionConsent, transport: DecisionsTransport) {
        assessmentTimeout?.cancel(); cancelAssessment?()
        assessmentEpoch = UUID(); assessmentSelecting = false
        assessmentActive = nil; cancelAssessment = nil
        automaticConsent = consent; assessmentTransport = transport; automaticAssessmentEnabled = true
        automaticAssessmentStatus = Self.openAssessmentOnStatus(consent)
        assessmentAttempts.removeAll(); openTargets.removeAll(); dailyLimitDay = nil; openAssessmentsSent = 0
    }
    func pauseAutomaticAssessment(status: String = "Paused. Saved labels remain; no further calls.") {
        assessmentTimeout?.cancel(); assessmentTimeout = nil; openTargets.removeAll()
        assessmentEpoch = UUID(); assessmentSelecting = false
        assessmentActive = nil; cancelAssessment?(); cancelAssessment = nil; assessmentTransport = nil
        automaticAssessmentEnabled = false; automaticAssessmentStatus = status
        if var consent = automaticConsent { consent.enabled = false; try? consent.save(in: repository.url.deletingLastPathComponent()) }
        automaticConsent = nil
    }
    /// User-triggered only. Snapshot the exact evidence and review it before any HTTP.
    func reviewSelectedAssessment() {
        guard !decisionReviewBusy else { return }
        let destination = results.first(where: { $0.id == selectedID }) ?? compassItems.first(where: { $0.id == selectedID }) ?? recentSessions.first(where: { $0.id == selectedID })?.destination
        guard let item = destination, let window = attention.windows[item.conversationKey] else {
            decisionReviewStatus = "Select a Codex conversation with recent messages first."; return
        }
        guard !window.unansweredUser, !window.incomplete, !window.messages.isEmpty else {
            decisionReviewStatus = window.unansweredUser ? "Latest input is unanswered: ongoing, no API call needed." : "Evidence is incomplete; nothing sent."
            return
        }
        guard !attention.hasNewerActivity(item.conversationKey, at: now()) else {
            decisionReviewStatus = "Codex is working on newer messages: ongoing, nothing sent."; return
        }
        let input = SessionAssessmentInput(window: window)
        do {
            let body = try input.body()
            let object = try JSONSerialization.jsonObject(with: body)
            let pretty = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            let alert = NSAlert()
            alert.messageText = "Assess \(item.title)?"
            alert.informativeText = "Send exactly the text below to OpenAI Decisions once. It can contain private conversation details and paths. Estimated cost is under $0.01. No automatic or recurring requests. The result labels this conversation; it never hides it or approves an action."
            alert.addButton(withTitle: "Send this excerpt")
            alert.addButton(withTitle: "Cancel")
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 560, height: 280))
            let text = NSTextView(frame: scroll.bounds)
            text.isEditable = false; text.isSelectable = true
            text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            text.string = String(decoding: pretty, as: UTF8.self)
            text.isVerticallyResizable = true; text.autoresizingMask = [.width]
            scroll.documentView = text; scroll.hasVerticalScroller = true
            alert.accessoryView = scroll
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            let panel = NSOpenPanel()
            panel.title = "Choose Spleen’s approved .env.local or API-key file"
            panel.message = "Used only for this request. The key is never displayed or copied to another file."
            panel.canChooseDirectories = false; panel.allowsMultipleSelection = false; panel.showsHiddenFiles = true
            panel.directoryURL = repository.url.deletingLastPathComponent().deletingLastPathComponent()
            guard panel.runModal() == .OK, let url = panel.url else { return }
            let key = try attentionCredential(at: url)
            let configuration = try DecisionsTrialConfiguration(id: "review-" + UUID().uuidString, maximumRequests: 1,
                expiresAt: now().addingTimeInterval(60))
            let ledger = DecisionsTrialLedger(url: repository.url.deletingLastPathComponent().appendingPathComponent("decision-reviews/\(configuration.id).json"), configuration: configuration)
            let transport = ReviewedAttentionTransport(manifest: AttentionTrialManifest(configuration: configuration, bodies: [body]),
                underlying: DecisionsHTTPTransport(approvedCredential: key, ledger: ledger, requestTimeout: 5))
            sendReviewedAssessment(window: window, body: body, transport: transport)
        } catch {
            decisionReviewStatus = "Could not prepare request or read the credential. Nothing sent."
        }
    }
    /// Injectable transport permits native tests without credentials or network access.
    func sendReviewedAssessment(window: SessionWindow, body: Data, transport: DecisionsTransport) {
        guard !decisionReviewBusy else { return }
        let job = UUID(), started = uptime(), input = SessionAssessmentInput(window: window)
        reviewedJob = job; reviewedTransport = transport; decisionReviewBusy = true
        decisionReviewStatus = "Assessing reviewed excerpt…"
        cancelReviewedAssessment = transport.send(body: body) { [weak self] response in
            DispatchQueue.main.async {
                guard let self, self.reviewedJob == job else { return }
                self.reviewedJob = nil; self.decisionReviewBusy = false
                self.cancelReviewedAssessment = nil; self.reviewedTransport = nil
                switch response.flatMap({ data in Result { try input.result(data) } }) {
                case .success(let result):
                    guard self.attention.apply(result, for: window) else {
                        self.decisionReviewStatus = "Conversation changed; ignored the stale assessment."; return
                    }
                    self.assessmentCache[window.contentVersion] = result
                    let cache = self.assessmentCache, url = self.assessmentURL
                    self.insightSaveQueue.async { if let data = try? JSONEncoder().encode(cache) { try? data.write(to: url, options: .atomic) } }
                    self.rebuildSnapshot()
                    self.decisionReviewStatus = "Result: \(result.assessment.rawValue.replacingOccurrences(of: "_", with: " ")) · \(String(format: "%.2f", self.uptime() - started))s · no further calls."
                case .failure:
                    self.decisionReviewStatus = "Assessment unavailable. Not retried; local ranking unchanged."
                }
            }
        }
    }
    func stopReviewedAssessment() {
        reviewedJob = nil; cancelReviewedAssessment?(); cancelReviewedAssessment = nil
        reviewedTransport = nil; decisionReviewBusy = false
        decisionReviewStatus = "Stopped. A request already sent may still be billed; no retry."
    }
    private func assessChangedSessions() {
        guard let transport = assessmentTransport, assessmentActive == nil, !assessmentSelecting else { return }
        // Assessment on open sends only the latest press's cards; the reviewed CLI trial keeps its per-launch cap.
        let onOpen = automaticConsent != nil
        if onOpen {
            guard !openTargets.isEmpty, uptime() <= openTargetsUntil,
                  dailyLimitDay != DailyDecisionsTransport.day(for: now()) else { return }
        } else if assessmentAttempts.count >= 20 { return }
        let targets = openTargets, instant = now()
        let candidates = attention.windows.values.filter { window in
            if onOpen && !targets.contains(window.key) { return false }
            // Retained messages predate newer Codex work; wait for that turn to finish.
            if attention.hasNewerActivity(window.key, at: instant) { return false }
            guard let live = attention.liveState(for: window.key, at: instant) else { return true }
            return live.activity != .working && live.activity != .waitingForApproval && live.activity != .waitingForInput
        }
        let snapshot = Array(candidates), cached = Set(assessmentCache.keys), attempted = assessmentAttempts
        let epoch = assessmentEpoch, responseQueue = rankingResponseQueue
        assessmentSelecting = true
        responseQueue.async { [weak self] in
            let selected = AutomaticAttention.nextWindow(windows: snapshot, cachedVersions: cached, attemptedVersions: attempted)
            let body = selected.flatMap { try? SessionAssessmentInput(window: $0).body() }
            DispatchQueue.main.async {
                guard let self, self.assessmentEpoch == epoch else { return }
                self.assessmentSelecting = false
                guard let window = selected, let body, self.attention.windows[window.key] == window else { return }
                // Compaction makes evidence incomplete; never pay to classify a window we must discard.
                guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                      let inputs = object["input"] as? [[String: Any]],
                      let contents = inputs.first?["content"] as? [[String: Any]],
                      let evidence = contents.first?["data"] as? [String: Any], evidence["incomplete"] as? Bool == false else {
                    self.assessmentAttempts.insert(window.contentVersion); self.assessChangedSessions(); return
                }
                let input = SessionAssessmentInput(window: window), job = UUID(), started = self.uptime()
                self.assessmentAttempts.insert(window.contentVersion); self.assessmentActive = job
                if onOpen { self.openAssessmentsSent += 1 }
                self.cancelAssessment = transport.send(body: body) { [weak self] response in
                    responseQueue.async {
                        let result = response.flatMap { data in Result { try input.result(data) } }
                        DispatchQueue.main.async {
                            guard let self, self.assessmentActive == job else { return }
                            self.assessmentActive = nil; self.cancelAssessment = nil
                            self.assessmentTimeout?.cancel(); self.assessmentTimeout = nil
                            if self.uptime() - started <= 6, case .success(let result) = result,
                               self.attention.apply(result, for: window) {
                                self.assessmentCache[window.contentVersion] = result
                                // Preserve finished results during metadata refresh gaps; only content changes invalidate them.
                                if self.assessmentCache.count > 2000 {
                                    let current = Set(self.attention.windows.values.map(\.contentVersion))
                                    let extra = self.assessmentCache.keys.filter { !current.contains($0) }.sorted().prefix(max(0, 2000-current.count))
                                    let retained = current.union(extra)
                                    self.assessmentCache = self.assessmentCache.filter { retained.contains($0.key) }
                                }
                                let cache = self.assessmentCache, url = self.assessmentURL
                                self.insightSaveQueue.async { if let data = try? JSONEncoder().encode(cache) { try? data.write(to: url, options: .atomic) } }
                                self.rebuildSnapshot()
                            }
                            if let consent = self.automaticConsent {
                                var limited = false
                                if case .failure(let error) = response, let trial = error as? DecisionsTrialError {
                                    switch trial {
                                    case .limitReached:
                                        // Nothing was sent; this text can be assessed again tomorrow.
                                        self.openAssessmentsSent -= 1; limited = true
                                        self.assessmentAttempts.remove(window.contentVersion)
                                        self.dailyLimitDay = DailyDecisionsTransport.day(for: self.now())
                                    case .duplicateRequest: self.openAssessmentsSent -= 1 // Already sent today; not resent.
                                    case .configurationMismatch, .corruptLedger, .invalidConfiguration:
                                        self.pauseAutomaticAssessment(status: "Request log unavailable; paused with no further calls.")
                                    default: break
                                    }
                                }
                                if self.automaticAssessmentEnabled {
                                    self.automaticAssessmentStatus = limited
                                        ? "Today's \(consent.dailyLimit) requests are used · resumes tomorrow. Saved labels remain."
                                        : "On · \(self.openAssessmentsSent) sent since launch · unchanged cards reuse saved labels."
                                }
                            }
                            self.assessChangedSessions()
                        }
                    }
                }
                let timeout = DispatchWorkItem { [weak self] in
                    guard let self, self.assessmentActive == job else { return }
                    self.assessmentActive = nil; self.cancelAssessment?(); self.cancelAssessment = nil
                    self.assessChangedSessions()
                }
                self.assessmentTimeout = timeout
                DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: timeout)
            }
        }
    }

    func subtitle(_ item: Destination) -> String {
        if item.conversationKey == visibleInitialReturnKey {
            let provider = item.provider == .claude && (try? ClaudeDesktopCodeTarget(conversationID: item.threadID)) != nil
                ? "Claude Code · Experimental" : item.provider.displayName
            return ([provider, "Previous conversation"] + (preview(item).project.map { [$0] } ?? [])).joined(separator: " · ")
        }
        if navigationFirst {
            return item.provider.displayName + (item.pinned ? " · Pinned" : " · Recent session")
        }
        return (visibleSnapshot ?? preparedSnapshot).subtitles[item.conversationKey] ?? item.provider.displayName
    }
    func preview(_ item: Destination) -> ConversationPreview {
        let base = (visibleSnapshot ?? preparedSnapshot).previews[item.conversationKey] ?? ConversationPreview()
        guard item.provider == .claude, let reply = (visibleClaudeReplyTimes ?? claudeReplyTimes).time(for: item.conversationKey, at: now()) else { return base }
        return ConversationPreview(project: base.project, excerpt: base.excerpt, timing: base.timing,
            lastVisitedAt: base.lastVisitedAt, lastSelectedAt: base.lastSelectedAt, observedReplyAt: reply.date)
    }
    private func timestamps(_ item: Destination) -> [ConversationTimestamp] {
        let instant = now()
        let details = preview(item)
        // Reply completion and navigation are independent facts. The visible
        // recent entry also includes accepted opens made before a snapshot rebuild.
        let interaction = recentSessions.first { $0.destination.conversationKey == item.conversationKey }?.interaction
            ?? details.interactionTimestamp(at: instant)
        return [details.replyTimestamp(at: instant), interaction].compactMap { $0 }.filter { $0.date <= instant }
    }
    func timingLabel(_ item: Destination, separator: String = "\n") -> String? {
        let instant = now()
        let labels = timestamps(item).compactMap { $0.label(at: instant) }
        return labels.isEmpty ? nil : labels.joined(separator: separator)
    }
    /// The first available timestamp only: a reply when one is known, otherwise the
    /// navigation time. Cards show this line; `timingHelp` keeps every exact time.
    func primaryTimingLabel(_ item: Destination) -> String? {
        let instant = now()
        return timestamps(item).lazy.compactMap { $0.label(at: instant) }.first
    }
    func timingHelp(_ item: Destination) -> String {
        timestamps(item).map(\.help).joined(separator: "\n")
    }
    @discardableResult func commit(_ updated: SavedState) -> Bool {
        guard !loadFailed else { error = "Saving is disabled because the existing file couldn't be loaded. Repair or move it, then restart Spleen.\n\(repository.url.path)"; return false }
        do { try repository.save(updated); state = updated; context.setRecentsEnabled(state.rememberRecents)
            immediateReturn = nil
            readyRecents = RecentSessionSnapshot(state: state, catalog: catalog, context: context, now: now(), uptime: uptime())
            rebuildSnapshot(adoptVisible: true); return true }
        catch { self.error = "Couldn't save: \(error.localizedDescription)"; return false }
    }
    func move(_ delta: Int) {
        freezeOpening()
        guard !results.isEmpty else { return }
        let current = results.firstIndex { $0.id == selectedID } ?? 0
        selectedID = results[min(max(current + delta, 0), results.count - 1)].id
    }
    func openSelected() {
        let item = mode == .compass && browsingRecents
            ? recentSessions.first(where: { $0.id == selectedID })?.destination
            : results.first(where: { $0.id == selectedID })
        if let item { openDestination?(item) }
    }
    var selectedCompassPreview: Destination? {
        if browsingRecents { return recentSessions.first { $0.id == selectedID }?.destination }
        return compassItems.first { $0.id == selectedID } ?? compassItems.first
    }
    func recentLabel(_ entry: RecentSession) -> String { entry.interaction.label(at: now()) ?? "Recently used" }
    func selectCompass(_ id: UUID) {
        guard compassItems.contains(where: { $0.id == id }) else { return }
        freezeOpening(); browsingRecents = false; pendingRecentEntry = false; selectedID = id
    }
    func selectRecent(_ id: UUID) {
        guard recentSessions.contains(where: { $0.id == id }) else { return }
        freezeOpening()
        if !browsingRecents { recentReturnID = selectedID }
        browsingRecents = true; pendingRecentEntry = false; selectedID = id
    }
    func navigateCompass(_ direction: CompassDirection) {
        freezeOpening()
        if browsingRecents {
            if direction == .left {
                let target = compassItems.first { $0.id == recentReturnID } ?? compassItems.first
                if let target { selectCompass(target.id) }
            } else if direction == .up || direction == .down, !recentSessions.isEmpty {
                let current = recentSessions.firstIndex { $0.id == selectedID } ?? 0
                let next = min(max(current + (direction == .down ? 1 : -1), 0), recentSessions.count - 1)
                selectedID = recentSessions[next].id
            }
            return
        }
        if direction == .right, !recentSessions.isEmpty,
           pendingRecentEntry || (compassItems.indices.contains(2) && compassItems[2].id == selectedID) {
            selectRecent(recentSessions[0].id)
            return
        }
        let next = CompassSelection.next(currentID: selectedID, items: compassItems, direction: direction)
        // A sparse compass still supports two Right presses from its center.
        pendingRecentEntry = direction == .right && next == selectedID && !recentSessions.isEmpty
        selectedID = next
    }
    func edit(_ item: Destination? = nil) {
        freezeOpening()
        editorID = item.flatMap { candidate in state.destinations.contains(where: { $0.id == candidate.id }) ? candidate.id : nil }; editorTitle = item?.title ?? ""; editorLink = item.flatMap { try? $0.navigationURL.absoluteString } ?? ""
        editorConversationKey = item?.conversationKey
        editorCanRemove = editorID != nil || (item?.provider == .claude && item.flatMap { try? ClaudeDesktopCodeTarget(conversationID: $0.threadID) } != nil)
        editorPinned = item?.pinned ?? false; error = nil; mode = .editor
    }
    func saveEditor() {
        do {
            var next = state
            try next.upsert(id: editorID, title: editorTitle, link: editorLink, pinned: editorPinned)
            if commit(next) { mode = .search; error = nil }
        } catch { self.error = error.localizedDescription }
    }
    func removeEdited() {
        guard editorCanRemove else { return }
        var next = state
        if let key = editorConversationKey, key.provider == .claude,
           (try? ClaudeDesktopCodeTarget(conversationID: key.id)) != nil {
            guard !catalogLoadFailed else { error = "Repair the catalog cache before hiding this recent session."; return }
            var policy = catalog.effectivePolicy
            if !policy.excludedConversationIDs.contains(key) {
                guard policy.excludedConversationIDs.count < 10_000 else { error = "Restore removed chats before hiding more sessions."; return }
                policy.excludedConversationIDs.append(key)
            }
            catalog.version = 2; catalog.policy = policy; saveCatalog()
        }
        if let editorID, let item = next.destinations.first(where: { $0.id == editorID }), item.provider == .codex, catalog.entries.contains(where: { $0.id == item.threadID }) {
            catalog.hiddenIDs.append(item.threadID); enrichmentRevision += 1; saveCatalog()
            insights.retain(catalog: catalog); saveInsights()
        }
        if let editorID { next.remove(editorID) }
        if commit(next) { mode = .search; error = nil }
    }
    func showSettings() {
        freezeOpening()
        dotLinkDraft = state.dotLink ?? ""
        shortcutDraft = state.shortcut; rememberDraft = state.rememberRecents; navigationFirstDraft = navigationFirst; automaticDiscoveryDraft = catalog.effectivePolicy.scope == .automaticProjects; observeClaudeDraft = observesClaude; observeCodexDraft = observesCodex; mode = .settings; error = nil
    }
    func saveSettings() {
        guard shortcutDraft.isValid else { error = SpleenError.invalidSettings.localizedDescription; return }
        let old = state.shortcut
        do {
            let dotLink = dotLinkDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            let dotURL = dotLink.isEmpty ? nil : try DotTarget(dotLink).url
            try changeShortcut?(shortcutDraft)
            var next = state; next.shortcut = shortcutDraft; next.rememberRecents = rememberDraft
            next.dotLink = dotURL?.absoluteString
            if !rememberDraft || rememberDraft != state.rememberRecents { next.clearRecents(at: now()) }
            if commit(next) {
                contextReadGeneration += 1
                context.setRecentsEnabled(next.rememberRecents)
                let enabled = next.rememberRecents, url = contextURL
                contextQueue.async { _ = try? ContextRepository(url: url).setRecentsEnabled(enabled, clear: !enabled) }
                if !enabled { clearClaudeReplyTimes() }
                let newlyEnabledClaude = observeClaudeDraft && !observesClaude
                navigationFirst = navigationFirstDraft
                immediateReturn = nil
                let newlyEnabledCodex = observeCodexDraft && !observesCodex
                observesCodex = observeCodexDraft
                observesClaude = observeClaudeDraft
                do {
                    let settings = try JSONEncoder().encode(["observeClaudeDesktop": observesClaude, "observeCodexDesktop": observesCodex, "navigationFirstCompass": navigationFirst])
                    try settings.write(to: contextSettingsURL, options: .atomic)
                } catch { self.error = "Context preference could not be saved." }
                configureClaudeObserver(promptForPermission: newlyEnabledClaude)
                configureCodexObserver(promptForPermission: newlyEnabledCodex)
                rebuildSnapshot(adoptVisible: true)
                if automaticDiscoveryDraft != (catalog.effectivePolicy.scope == .automaticProjects) {
                    catalog.version = 2
                    var updatedPolicy = catalog.effectivePolicy
                    updatedPolicy.scope = automaticDiscoveryDraft ? .automaticProjects : .exactFolders
                    updatedPolicy.folders = catalog.folders
                    if automaticDiscoveryDraft { updatedPolicy.pageSize = 100; updatedPolicy.maxPages = 10 }
                    catalog.policy = updatedPolicy
                    let policy = catalog.effectivePolicy
                    catalog.entries.removeAll { !policy.allows(folder: $0.folder, key: ConversationKey(provider: .codex, id: $0.id)) }
                    catalogRevision += 1; enrichmentRevision += 1
                    insights.retain(catalog: catalog); saveCatalog(); saveInsights(); rebuildSnapshot(adoptVisible: true)
                    refreshCatalog(force: true)
                }
                shortcutStatus = "Shortcut: \(next.shortcut.label)"; mode = .search
            }
            else if old != shortcutDraft {
                do { try changeShortcut?(old) }
                catch { shortcutStatus = error.localizedDescription }
            }
        } catch { self.error = error.localizedDescription }
    }
    func clearRecents() {
        guard !loadFailed else { return }
        contextReadGeneration += 1
        context.clear()
        clearClaudeReplyTimes()
        let url = contextURL, enabled = state.rememberRecents
        contextQueue.async { _ = try? ContextRepository(url: url).setRecentsEnabled(enabled, clear: true) }
        var next = state; next.clearRecents(at: now()); _ = commit(next)
    }
    func acceptedDispatch(_ id: UUID) {
        // A context read already in flight must not restore an older Claude (or
        // Codex) selection over this accepted local navigation.
        contextReadGeneration += 1
        let before = preparedSnapshot
        let priorCurrent = context.currentHint(at: now())?.key ?? before.currentKey
        var seen = Set<ConversationKey>()
        let available = ((immediateReturn?.order ?? preparedOrder) + results + recentSessions.map(\.destination)).filter { seen.insert($0.conversationKey).inserted }
        var next = state
        // PanelController ends presentation immediately before this callback. Results
        // still hold the dispatched invocation, even if its prepared index changed.
        let target = recentSessions.first { $0.id == id }?.destination ?? results.first { $0.id == id } ?? (visibleOrder ?? preparedOrder).first { $0.id == id }
            ?? catalog.merged(with: state).destinations.first { $0.id == id }
        if !next.destinations.contains(where: { $0.id == id }), next.rememberRecents,
           let item = target, item.provider == .codex { next.destinations.append(item) }
        next.recordDispatch(id, at: now())
        if next.rememberRecents, let item = next.destinations.first(where: { $0.id == id }) ?? target {
            // A saved dispatch can establish the prior selection even when its
            // bounded context event was evicted. Preserve that recorded time.
            if context.currentHint(at: now()) == nil, let priorCurrent,
               let prior = state.destinations.first(where: { $0.conversationKey == priorCurrent }),
               let at = prior.lastOpenedAt, at < now(), now().timeIntervalSince(at) < ContextMemory.hintLifetime {
                let priorEvent = ContextEvent(key: priorCurrent, kind: .spleenDispatch, observedAt: at,
                    source: "spleen", evidence: .spleenInteraction)
                context.record(priorEvent, now: now())
                let url = contextURL, instant = now()
                contextQueue.async { _ = try? ContextRepository(url: url).record(priorEvent, now: instant) }
            }
            let project = item.provider == .codex ? catalog.entries.first { $0.id == item.threadID }?.folder : nil
            let instant = now()
            let event = ContextEvent(key: item.conversationKey, project: project, kind: .spleenDispatch, observedAt: instant, source: "spleen", evidence: .spleenInteraction)
            context.record(event, now: instant)
            let url = contextURL
            contextQueue.async { _ = try? ContextRepository(url: url).record(event, now: instant) }
        }
        _ = commit(next)
        if let target {
            let previous = context.previousDistinct(at: now())?.key ?? priorCurrent
            prepareImmediateReturn(order: available, current: target.conversationKey, previous: previous, at: now())
        }
    }

    private func reloadContext() {
        guard !loadFailed else { return }
        let url = contextURL, generation = contextReadGeneration, reader = contextReader
        contextQueue.async { [weak self] in
            guard let memory = try? reader(url), let data = Self.contextData(memory) else { return }
            DispatchQueue.main.async {
                guard let self, self.contextReadGeneration == generation, self.contextFingerprint != data else { return }
                self.contextFingerprint = data
                let oldMemory = self.context, instant = self.now()
                self.context = memory; self.context.setRecentsEnabled(self.state.rememberRecents); self.context.prune(now: self.now())
                let signature = ContextRelevanceSignature(self.context, now: instant)
                let observedAuditEvicted = oldMemory.latestObservedSelection(at: instant) != nil && self.context.latestObservedSelection(at: instant) == nil
                let receivedInteraction = self.context.events.contains { $0.contributesInteraction && !oldMemory.events.contains($0) }
                let auditOnly = observedAuditEvicted && !receivedInteraction && self.contextSignature?.hasSameInteractions(as: signature) == true
                if self.contextSignature != signature && !auditOnly {
                    self.prepareImmediateReturn(order: self.preparedOrder, current: self.context.currentHint(at: instant)?.key,
                        previous: self.context.previousDistinct(at: instant)?.key, at: instant)
                    self.rebuildSnapshot()
                }
                else if auditOnly { self.contextSignature = signature }
            }
        }
    }
    private static func contextData(_ memory: ContextMemory) -> Data? {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(memory)
    }
    private func configureCodexObserver(promptForPermission: Bool) {
        guard !loadFailed, observesCodex, state.rememberRecents else {
            codexObserver?.stop(); codexObserver = nil
            codexContextStatus = observesCodex ? "Paused while recent selections are off." : "Off · Codex navigation observation is optional."
            return
        }
        if codexObserver == nil {
            codexObserver = CodexDesktopObserver { [weak self] observation in
                guard let self, !self.loadFailed, self.observesCodex, self.state.rememberRecents else { return }
                // An exact route establishes a visit, not working/finished/read status.
                let event = ContextEvent(key: observation.key, topic: observation.title, kind: .selectedConversation,
                    observedAt: self.now(), source: "codex-desktop-accessibility", evidence: .observedSelection)
                self.contextReadGeneration += 1
                self.context.record(event, now: event.observedAt)
                self.prepareImmediateReturn(order: self.preparedOrder, current: event.key,
                    previous: self.context.previousDistinct(at: event.observedAt)?.key, at: event.observedAt)
                let url = self.contextURL
                self.contextQueue.async { _ = try? ContextRepository(url: url).record(event) }
                self.rebuildSnapshot()
                self.codexContextStatus = "Codex selection observed · local navigation only."
            }
        }
        let started = codexObserver?.start(promptForPermission: promptForPermission) ?? false
        codexContextStatus = started ? "Ready · waiting for an exposed local Codex route."
            : "Unavailable · Spleen needs existing Accessibility access to observe navigation."
    }

    private func configureClaudeObserver(promptForPermission: Bool) {
        guard !loadFailed && observesClaude && state.rememberRecents else {
            claudeObserver?.stop(); claudeObserver = nil
            claudeStatusObserver?.stop(); claudeStatusObserver = nil
            receiveClaudeStatus(nil)
            claudeContextStatus = loadFailed ? "Paused · repair saved destinations before enabling context observation." : (observesClaude ? "Paused while recent selections are off." : "Off · Claude Desktop context is optional.")
            return
        }
        if claudeObserver == nil {
            claudeObserver = ClaudeDesktopObserver { [weak self] observation in
                guard let self, !self.loadFailed, self.observesClaude, self.state.rememberRecents else { return }
                self.contextReadGeneration += 1
                let event = ContextEvent(key: observation.key, topic: observation.title, kind: .selectedConversation,
                                         source: "claude-desktop-accessibility", evidence: .observedSelection)
                self.context.record(event)
                self.prepareImmediateReturn(order: self.preparedOrder, current: event.key,
                    previous: self.context.previousDistinct()?.key, at: event.observedAt)
                let url = self.contextURL
                self.contextQueue.async { _ = try? ContextRepository(url: url).record(event) }
                self.rebuildSnapshot()
                self.claudeContextStatus = observation.surface == .code
                    ? "Claude Code selection observed · experimental switching is available for retained visits."
                    : "Claude chat selection observed."
            }
        }
        let started = claudeObserver?.start(promptForPermission: promptForPermission) ?? false
        if started {
            if claudeStatusObserver == nil {
                claudeStatusObserver = ClaudeDesktopStatusObserver(onReply: { [weak self] key, time in
                    guard let self, self.observesClaude, self.state.rememberRecents, !self.loadFailed else { return }
                    self.receiveClaudeReply(time, for: key)
                }) { [weak self] sample in
                    guard let self, self.observesClaude, self.state.rememberRecents, !self.loadFailed else { return }
                    self.receiveClaudeStatus(sample)
                }
            }
            claudeStatusObserver?.start()
        } else {
            claudeStatusObserver?.stop()
            receiveClaudeStatus(nil)
        }
        claudeContextStatus = started ? "Ready · waiting for a supported Claude selection."
            : (ClaudeDesktopObserver.isTrusted ? "Ready · open Claude Desktop to observe a supported conversation." : "Allow Spleen in macOS Privacy & Security → Accessibility, then save settings again.")
    }
    /// Status never records a visit or acknowledges a reply. The adapter reports
    /// only the Code route displayed in Claude; replace its previous route's sample.
    func receiveClaudeStatus(_ sample: LiveSessionState?) {
        let instant = now()
        var changed = attention.disconnect(source: ClaudeDesktopStatus.source, at: sample?.observedAt ?? instant)
        if let sample { changed = attention.accept(sample, now: instant) || changed }
        if changed { rebuildSnapshot() }
    }
    func receiveClaudeReply(_ time: ClaudeReplyTime, for key: ConversationKey) {
        guard !loadFailed, state.rememberRecents, claudeReplyTimes.record(time, for: key, now: now()) else { return }
        let cache = claudeReplyTimes, url = claudeReplyURL
        contextQueue.async { try? cache.save(to: url) }
        if !isPresented { objectWillChange.send() }
    }
    private func clearClaudeReplyTimes() {
        claudeReplyTimes = ClaudeReplyTimes(); visibleClaudeReplyTimes = nil
        let cache = claudeReplyTimes, url = claudeReplyURL
        contextQueue.async { try? cache.save(to: url) }
    }
    private func invalidateRanking() {
        activeRankingJobID = nil
        cancelRanking?(); cancelRanking = nil; rankingTimeout?.cancel(); rankingTimeout = nil; ranking.invalidate()
    }
    private func precomputeRanking(_ input: RankingInput, body: Data) {
        guard let rankingTransport, let job = ranking.begin(input, now: uptime()) else { return }
        activeRankingJobID = job.id
        cancelRanking?(); rankingTimeout?.cancel()
        let responseQueue = rankingResponseQueue
        cancelRanking = rankingTransport.send(body: body) { [weak self] result in
            responseQueue.async { [weak self] in
                let order: Result<[String]?, Error> = result.flatMap { data in Result { try input.order(response: data) } }
                DispatchQueue.main.async {
                    guard let self, self.activeRankingJobID == job.id, self.rankingInput?.key == input.key else { return }
                    self.activeRankingJobID = nil
                    self.rankingTimeout?.cancel(); self.rankingTimeout = nil; self.cancelRanking = nil
                    self.ranking.finishValidated(job, response: order, now: self.uptime())
                    self.readyOrder = self.ranking.snapshot(baseline: self.relevance.ready.ordered, input: input, now: self.uptime())
                    self.readyRankingExpiresAt = self.readyOrder == self.relevance.ready.ordered ? 0 : self.uptime() + 120
                    if !self.isPresented { self.refreshResults() }
                }
            }
        }
        let cancel = cancelRanking
        let timeout = DispatchWorkItem { cancel?() }; rankingTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75, execute: timeout)
    }
    deinit {
        attentionTimer?.invalidate()
        assessmentTimeout?.cancel(); cancelAssessment?(); cancelReviewedAssessment?()
    }

}
