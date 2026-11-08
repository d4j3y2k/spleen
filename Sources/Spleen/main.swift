import AppKit
import SpleenCore

func spleenDataDirectory(_ arguments: [String] = CommandLine.arguments) -> URL {
    if let index = arguments.firstIndex(of: "--data-dir"), arguments.indices.contains(index + 1) {
        return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
    }
    return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Spleen", isDirectory: true)
}

// Read-only provider checks require an explicit scope; no personal path or chat ID is compiled in.
func diagnosticCatalogFolders(_ arguments: [String] = CommandLine.arguments) -> [String]? {
    var folders: [String] = []
    for index in arguments.indices where arguments[index] == "--catalog-folder" {
        guard arguments.indices.contains(index + 1) else { return nil }
        let folder = arguments[index + 1]
        guard folder.hasPrefix("/"), !folder.contains("\0"), folders.count < 10 else { return nil }
        if !folders.contains(folder) { folders.append(folder) }
    }
    return folders.isEmpty ? nil : folders
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: PanelController!
    var hotkey: HotKey!
    var statusItem: NSStatusItem!
    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--self-test") {
            let success = runAppTests()
            fflush(stdout)
            exit(success ? 0 : 1)
        }
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--render-preview") {
            do {
                guard arguments.indices.contains(index + 1), arguments[index + 1].hasPrefix("/") else {
                    print("Native preview requires an absolute output directory.")
                    fflush(stdout); exit(1)
                }
                let outputs = try renderNativePreviews(directory: URL(fileURLWithPath: arguments[index + 1], isDirectory: true))
                for output in outputs { print(output.path) }
                fflush(stdout); exit(0)
            } catch {
                print("Native preview failed: \(error.localizedDescription)")
                fflush(stdout); exit(1)
            }
        }
        let directory = spleenDataDirectory(arguments)
        let mainMenu = NSMenu()
        let appItem = NSMenuItem(title: "Spleen", action: nil, keyEquivalent: "")
        let appMenu = NSMenu(title: "Spleen")
        appMenu.addItem(withTitle: "Quit Spleen", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu; mainMenu.addItem(appItem)
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "Edit")
        for (title, selector, key) in [("Undo", "undo:", "z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            editMenu.addItem(withTitle: title, action: Selector(selector), keyEquivalent: key)
        }
        editItem.submenu = editMenu; mainMenu.addItem(editItem); NSApp.mainMenu = mainMenu
        let folders = arguments.firstIndex(of: "--catalog-folder").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }.map { [$0] } ?? []
        var assessmentTransport: DecisionsTransport?
        var automaticConsent: AutomaticAttentionConsent?
        do {
            if let consent = try AutomaticAttentionConsent.load(from: directory) {
                assessmentTransport = try consent.transport(in: directory); automaticConsent = consent
            } else { assessmentTransport = try attentionTrialTransport(directory: directory, arguments: arguments) }
        }
        catch { assessmentTransport = nil; automaticConsent = nil; print("Attention setup unavailable; continuing locally without API requests.") }
        let model = AppModel(repository: StateRepository(url: directory.appendingPathComponent("destinations.json")), initialFolders: folders,
                             assessmentTransport: assessmentTransport, automaticConsent: automaticConsent,
                             desktopReadFetcher: { keys, instant, sequence, epoch in
                                 guard NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == "com.openai.codex" }) else {
                                     throw CatalogError.unavailable
                                 }
                                 return try CodexDesktopReadStateClient().read(keys: keys, observedAt: instant, sequence: sequence, epoch: epoch).states
                             })
        controller = PanelController(model: model)
        hotkey = HotKey()
        hotkey.onPress = { [weak self] in trace("hotkey.received"); self?.controller.toggle() }
        model.changeShortcut = { [weak self] shortcut in try self?.hotkey.register(shortcut) }
        do { try hotkey.register(model.state.shortcut); model.shortcutStatus = "Shortcut: \(model.state.shortcut.label)" }
        catch { model.shortcutStatus = error.localizedDescription; model.error = error.localizedDescription }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = SpleenLogo.menuBarImage
        statusItem.button?.toolTip = "Spleen · \(model.state.shortcut.label)"
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Spleen", action: #selector(show), keyEquivalent: "")
        menu.addItem(withTitle: "Open Dot", action: #selector(openDot), keyEquivalent: "d")
        menu.addItem(withTitle: "Search conversations…", action: #selector(search), keyEquivalent: "")
        menu.addItem(withTitle: "Add conversation…", action: #selector(add), keyEquivalent: "")
        menu.addItem(withTitle: "Settings…", action: #selector(settings), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Spleen", action: #selector(quit), keyEquivalent: "q")
        for item in menu.items { item.target = self }
        statusItem.menu = menu
        if !CommandLine.arguments.contains("--background-launch") { controller.present() }
    }
    @objc func show() { controller.present() }
    @objc func openDot() { controller.openDot() }
    @objc func search() { controller.present(); controller.model.beginSearch() }
    @objc func add() { controller.present(); controller.model.edit() }
    @objc func settings() { controller.present(); controller.model.showSettings() }
    @objc func quit() { NSApplication.shared.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) { flushDiagnosticTrace() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        trace("application.reopen"); controller?.present(); return true
    }
}

if let index = CommandLine.arguments.firstIndex(of: "--export-attention-trial") {
    do {
        guard CommandLine.arguments.indices.contains(index + 1), CommandLine.arguments[index + 1].hasPrefix("/") else { exit(2) }
        try exportAttentionTrial(directory: spleenDataDirectory(), output: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
        exit(0)
    } catch { print("Attention export unavailable; no requests sent."); exit(1) }
}

// Lifecycle helper modes never start AppKit, read transcripts, or emit hook decisions.
if CommandLine.arguments.contains("--activity-event") || CommandLine.arguments.contains("--activity-notification") {
    do {
        let arguments = CommandLine.arguments
        let notification = arguments.contains("--activity-notification")
        let data: Data
        if notification {
            guard let raw = arguments.last else { exit(0) }
            data = Data(raw.utf8)
        } else { data = try FileHandle.standardInput.read(upToCount: ActivityHookDecoder.maximumInputBytes + 1) ?? Data() }
        let instant = Date()
        let event = notification ? ActivityHookDecoder.codexNotification(data: data, now: instant)
                                 : ActivityHookDecoder.codexEvent(data: data, now: instant)
        guard let event else { exit(0) }
        let directory = spleenDataDirectory()
        let catalog = try CatalogCache.load(from: directory.appendingPathComponent("catalog.json"))
        guard catalog.effectivePolicy.allows(folder: event.project, key: event.key), !catalog.hiddenIDs.contains(event.key.id) else { exit(0) }
        _ = try ActivityHookRepository(url: directory.appendingPathComponent("activity-hooks.json")).record(event, now: instant)
    } catch { } // Reporting must never block the originating turn.
    exit(0)
}
if CommandLine.arguments.contains("--enable-activity-reports") {
    do {
        _ = try ActivityHookRepository(url: spleenDataDirectory().appendingPathComponent("activity-hooks.json")).setEnabled(true)
        print("Activity reports enabled. Codex hooks still require normal trust review."); exit(0)
    } catch { print("Activity report store unavailable; existing file preserved."); exit(1) }
}

// Hook helpers run before NSApplication, emit no model context, and never launch a turn.
if let index = CommandLine.arguments.firstIndex(of: "--context-event") {
    do {
        guard CommandLine.arguments.indices.contains(index + 1), CommandLine.arguments[index + 1] == "codex" else { exit(0) }
        let data = try FileHandle.standardInput.read(upToCount: ContextHookDecoder.maximumInputBytes + 1) ?? Data()
        guard let event = ContextHookDecoder.codexEvent(data: data), let folder = event.project else { exit(0) }
        let directory = spleenDataDirectory()
        let catalog = try CatalogCache.load(from: directory.appendingPathComponent("catalog.json"))
        guard catalog.effectivePolicy.allows(folder: folder, key: event.key), !catalog.hiddenIDs.contains(event.key.id) else { exit(0) }
        try ContextRepository(url: directory.appendingPathComponent("context.json")).record(event)
        exit(0)
    } catch { exit(0) } // Observation must not interrupt the originating conversation.
}
if CommandLine.arguments.contains("--context-check") {
    do {
        let memory = try ContextRepository(url: spleenDataDirectory().appendingPathComponent("context.json")).load()
        print("Local context: \(memory.events.count) metadata events; recent interaction hint=\(memory.currentHint() != nil); observed selection=\(memory.latestObservedSelection() != nil). No conversation contents logged.")
        exit(0)
    } catch { print("Context store unavailable; existing file preserved."); exit(1) }
}
if CommandLine.arguments.contains("--claude-context-check") {
    print("Claude Desktop observation permission: \(ClaudeDesktopObserver.isTrusted ? "allowed" : "not granted"). No permission request or observation started.")
    exit(0)
}
if CommandLine.arguments.contains("--claude-status-probe") {
    guard ClaudeDesktopObserver.isTrusted else { print("Claude status probe unavailable: Accessibility permission is not granted."); exit(1) }
    var samples = 0
    let observer = ClaudeDesktopStatusObserver(diagnostics: { print($0); fflush(stdout) }) { sample in
        if let sample {
            samples += 1
            print("Claude status: activity=\(sample.activity?.rawValue ?? "unknown"), unread=\(sample.isUnread.map(String.init) ?? "unknown").")
        } else { print("Claude status: unknown.") }
        fflush(stdout)
    }
    observer.start()
    let deadline = Date().addingTimeInterval(6)
    while Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    observer.stop()
    print("Claude status probe: \(samples) samples. No identities, titles, or messages logged or cached.")
    exit(samples == 0 ? 1 : 0)
}
if CommandLine.arguments.contains("--claude-context-probe") {
    var probeSeconds = 15
    if let index = CommandLine.arguments.firstIndex(of: "--probe-seconds") {
        guard CommandLine.arguments.indices.contains(index + 1),
              let supplied = Int(CommandLine.arguments[index + 1]), (1...60).contains(supplied) else {
            print("Selection probe duration must be between 1 and 60 seconds."); exit(2)
        }
        probeSeconds = supplied
    }
    guard ClaudeDesktopObserver.isTrusted else {
        print("Claude selection probe unavailable: Accessibility permission is not granted. No request made.")
        exit(1)
    }
    var observations: [ClaudeDesktopObservation] = []
    let startedAt = ProcessInfo.processInfo.systemUptime
    let observer = ClaudeDesktopObserver(diagnosticsEnabled: true) {
        observations.append($0)
        if observations.count == 1 {
            print("Initial supported Claude selection observed."); fflush(stdout)
        }
    }
    guard observer.start() else { print("Claude selection probe could not start."); exit(1) }
    print("Claude selection probe armed for up to \(probeSeconds) seconds; counts-only output."); fflush(stdout)
    print("Claude foreground at probe start: \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.anthropic.claudefordesktop")."); fflush(stdout)
    let deadline = ProcessInfo.processInfo.systemUptime + TimeInterval(probeSeconds)
    func completedRoundtrip() -> Bool {
        observations.count >= 3 && observations.first?.key == observations.last?.key && Set(observations.map(\.key)).count >= 2
    }
    while !completedRoundtrip() && observations.count < 64 && ProcessInfo.processInfo.systemUptime < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(min(0.05, max(0, deadline - ProcessInfo.processInfo.systemUptime))))
    }
    observer.stop()
    let keys = Set(observations.map(\.key))
    print(String(format: "Claude selection probe: %d observations, %d distinct identities, code surface=%@, roundtrip=%@, elapsed=%.1f seconds. No identities, titles, messages, or contents logged or cached.", observations.count, keys.count,
                 observations.contains { $0.surface == .code } ? "true" : "false", completedRoundtrip() ? "true" : "false", ProcessInfo.processInfo.systemUptime - startedAt))
    let probeEncoder = JSONEncoder(); probeEncoder.outputFormatting = [.sortedKeys]
    if let data = try? probeEncoder.encode(observer.diagnosticsSnapshot()) { print(String(decoding: data, as: UTF8.self)) }
    exit(observations.isEmpty ? 1 : 0)
}
if CommandLine.arguments.contains("--navigation-compass-report") {
    do {
        let directory = spleenDataDirectory(), instant = Date(), tick = ProcessInfo.processInfo.systemUptime
        let state = try StateRepository(url: directory.appendingPathComponent("destinations.json")).load()
        let catalog = try CatalogCache.load(from: directory.appendingPathComponent("catalog.json"))
        let context = try ContextRepository(url: directory.appendingPathComponent("context.json")).load()
        let recent = RecentSessionSnapshot(state: state, catalog: catalog, context: context, now: instant, uptime: tick)
        let current = recent.entries.first(where: { $0.interaction.kind != .creation }).flatMap { instant.timeIntervalSince($0.interaction.date) < ContextMemory.hintLifetime ? $0.destination.conversationKey : nil }
        let compass = NavigationCompass(state: state, catalog: catalog, context: context, currentKey: current, now: instant, uptime: tick)
        for entry in compass.visibleEntries(now: instant, uptime: tick) {
            print(entry.destination.title + " | " + (entry.interaction?.label(at: instant) ?? "Explicit pin"))
        }
        print("Recorded history rows: \(recent.entries.count). No network, UI, or background-status inference.")
        exit(0)
    } catch { print("Local navigation metadata unavailable."); exit(1) }
}
if CommandLine.arguments.contains("--codex-exposure-check") {
    guard AXIsProcessTrusted() else { print("Existing trust unavailable; no prompt."); exit(1) }
    for app in NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex") {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.5)
        var old: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXEnhancedUserInterface" as CFString, &old) == .success,
              let old, CFGetTypeID(old) == CFBooleanGetTypeID() else { print("Original exposure unreadable; no change."); continue }
        let result = AXUIElementSetAttributeValue(element, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        print("Enhanced exposure result=\(result.rawValue); foreground=\(app.isActive)")
        defer { print("Exposure restore result=\(AXUIElementSetAttributeValue(element, "AXEnhancedUserInterface" as CFString, old).rawValue)") }
        guard result == .success else { continue }
        Thread.sleep(forTimeInterval: 0.8)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window, CFGetTypeID(window) == AXUIElementGetTypeID() else { print("No focused window metadata."); continue }
        let windowElement = window as! AXUIElement
        let selected = CodexSidebarMetadataReader.read(focusedWindow: windowElement,
            deadline: ProcessInfo.processInfo.systemUptime + 1, isCurrent: { AXIsProcessTrusted() })
        print("Exact selected sidebar identity available=\(selected != nil)")
        var nodes: [(AXUIElement, Int)] = [(windowElement,0)], index=0, roles: [String:Int]=[:], subroles: [String:Int]=[:]
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while index < nodes.count && index < 200 && ProcessInfo.processInfo.systemUptime < deadline {
            let (node,depth)=nodes[index];index += 1; AXUIElementSetMessagingTimeout(node,0.05)
            var raw:CFTypeRef?
            guard AXUIElementCopyAttributeValue(node,kAXRoleAttribute as CFString,&raw) == .success, let role=raw as? String else { continue }
            roles[role,default:0] += 1
            var sub:CFTypeRef?; _=AXUIElementCopyAttributeValue(node,kAXSubroleAttribute as CFString,&sub)
            if let sub=sub as? String { subroles[sub,default:0] += 1; if sub == "AXLandmarkMain" { continue } }
            guard depth < 14 && ["AXWindow","AXGroup","AXSplitGroup","AXWebArea","AXScrollArea"].contains(role) else { continue }
            var count:CFIndex=0
            guard AXUIElementGetAttributeValueCount(node,kAXChildrenAttribute as CFString,&count) == .success, count > 0 else { continue }
            var kids:CFArray?
            if AXUIElementCopyAttributeValues(node,kAXChildrenAttribute as CFString,0,min(count,200-nodes.count),&kids) == .success, let kids=kids as? [AXUIElement] { nodes += kids.map { ($0,depth+1) } }
        }
        print("Structure roles=\(roles); subroles=\(subroles)")
    }
    print("No text, screenshots, navigation, input or network; restoration result reported above.")
    exit(0)
}
if CommandLine.arguments.contains("--codex-accessibility-diagnostic") {
    guard AXIsProcessTrusted() else { print("Existing Accessibility trust unavailable; no prompt made."); exit(1) }
    for app in NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex") {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.5)
        print("Codex present; foreground=\(app.isActive)")
        for key in ["AXManualAccessibility", "AXEnhancedUserInterface", "AXFocusedWindow", "AXWindows"] {
            var raw: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(element, key as CFString, &raw)
            var writable = DarwinBoolean(false)
            let check = AXUIElementIsAttributeSettable(element, key as CFString, &writable)
            print("\(key): read=\(result.rawValue), settableCheck=\(check.rawValue), writable=\(writable.boolValue)")
        }
    }
    print("Metadata support only; no content, input, navigation, setting changes or network.")
    exit(0)
}
if CommandLine.arguments.contains("--codex-selection-probe") {
    guard CodexDesktopObserver.isTrusted else {
        print("Codex selection probe unavailable: Accessibility permission is not granted. No prompt made.")
        exit(1)
    }
    var count = 0
    let observer = CodexDesktopObserver(diagnosticsEnabled: true) { _ in count += 1 }
    guard observer.start() else { print("Codex observer unavailable."); exit(1) }
    let deadline = Date().addingTimeInterval(3)
    while Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    observer.stop()
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    if let data = try? encoder.encode(observer.diagnosticsSnapshot()) { print(String(decoding: data, as: UTF8.self)) }
    print("Observed local routes: \(count). Metadata only; no navigation, messages, or identities logged.")
    exit(count > 0 ? 0 : 1)
}
if CommandLine.arguments.contains("--discovery-check") {
    do {
        let value = try CodexCatalogClient().fetch(policy: DiscoveryPolicy(pageSize: 100, maxPages: 10))
        print("Automatic metadata discovery: \(value.entries.count) chats across \(Set(value.entries.map(\.folder)).count) projects; truncated=\(value.truncated). No titles, paths, notes, or contents logged or cached.")
        exit(0)
    } catch { print(error.localizedDescription); exit(1) }
}

if CommandLine.arguments.contains("--relevance-check") {
    guard let folders = diagnosticCatalogFolders() else {
        print("Supply 1–10 absolute project folders with --catalog-folder for this read-only check.")
        exit(2)
    }
    do {
        let start = ProcessInfo.processInfo.systemUptime
        let client = CodexCatalogClient(), value = try client.fetch(folders: folders)
        let notes = try client.insights(entries: Array(value.entries.prefix(8)), folders: folders)
        var catalog = CatalogCache(); catalog.folders = folders; catalog.entries = value.entries
        let snapshot = RelevanceSnapshot(state: SavedState(), catalog: catalog, insights: notes)
        print(String(format: "Local relevance: %d catalog entries, %d bounded notes (%d nonempty), %d indexed destinations, %.1f ms total; no text logged", value.entries.count, notes.count, notes.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }.count, snapshot.ordered.count, (ProcessInfo.processInfo.systemUptime - start) * 1000))
        exit(notes.isEmpty && !value.entries.isEmpty ? 1 : 0)
    } catch { print(error.localizedDescription); exit(1) }
}
if CommandLine.arguments.contains("--catalog-check") {
    guard let folders = diagnosticCatalogFolders() else {
        print("Supply 1–10 absolute project folders with --catalog-folder for this read-only check.")
        exit(2)
    }
    do {
        let value = try CodexCatalogClient().fetch(folders: folders)
        print("Swift catalog adapter: \(value.entries.count) entries, truncated=\(value.truncated). No identities, titles, paths, or contents logged or cached.")
        exit(0)
    } catch { print(error.localizedDescription); exit(1) }
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
