import AppKit
import SwiftUI
import SpleenCore

private enum NativePreviewError: LocalizedError {
    case snapshotTimeout, bitmapUnavailable
    var errorDescription: String? {
        switch self {
        case .snapshotTimeout: return "The isolated preview snapshot did not become ready."
        case .bitmapUnavailable: return "AppKit could not encode the native preview bitmap."
        }
    }
}

/// Renders actual native views using synthetic data, without showing windows or
/// capturing the desktop. Materials use a neutral backing, not a compositor capture.
func renderNativePreviews(directory: URL) throws -> [URL] {
    precondition(Thread.isMainThread)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("spleen-native-preview-\(UUID())")
    defer { try? FileManager.default.removeItem(at: fixture) }
    let repository = StateRepository(url: fixture.appendingPathComponent("state.json"))
    var state = SavedState()
    state.dotLink = "codex://threads/thr_preview_dot?hostId=durable"
    state.version = 2
    state.destinations = [
        Destination(title: "Spleen interaction", threadID: "thr_preview_interaction"),
        Destination(title: "Decisions experiment", threadID: "thr_preview_decisions"),
        Destination(title: "Product direction", threadID: "01234567-89ab-cdef-0123-456789abcdef", provider: .claude),
        Destination(title: "Keyboard and focus", threadID: "thr_preview_keyboard"),
        Destination(title: "Music workspace", threadID: "11234567-89ab-cdef-0123-456789abcdef", provider: .claude),
        Destination(title: "Spleen accessibility and long conversation labels", threadID: "thr_preview_accessibility")
    ]
    let instant = Date()
    state.destinations[2].lastOpenedAt = instant.addingTimeInterval(-120)
    state.destinations[0].lastOpenedAt = instant.addingTimeInterval(-60)
    state.destinations[1].lastOpenedAt = instant.addingTimeInterval(-300)
    state.destinations[4].lastOpenedAt = instant.addingTimeInterval(-600)
    state.destinations[3].lastOpenedAt = instant
    state.destinations[5].lastOpenedAt = instant.addingTimeInterval(-900)
    try repository.save(state)
    try Data("{\"navigationFirstCompass\":true}".utf8).write(to: fixture.appendingPathComponent("context-settings.json"))
    var catalog = CatalogCache(); catalog.folders = ["/fixture/Spleen"]
    catalog.refreshedAt = instant
    catalog.entries = state.destinations.filter { $0.provider == .codex }.map {
        CatalogEntry(id: $0.threadID, title: $0.title, folder: "/fixture/Spleen", updatedAt: instant)
    }
    try catalog.save(to: fixture.appendingPathComponent("catalog.json"))
    var notes = InsightCache()
    notes.entries = [ThreadInsight(id: "thr_preview_interaction", folder: "/fixture/Spleen", updatedAt: instant,
        topic: "The jumping is working well, but I’m vaguely guessing which conversation to choose. Could we make the different options easier to recognize?",
        timing: TurnTiming(lastStartedAt: instant.addingTimeInterval(-420), lastCompletedAt: instant.addingTimeInterval(-120), checkedAt: instant)),
        ThreadInsight(id: "thr_preview_decisions", folder: "/fixture/Spleen", updatedAt: instant, topic: "Compare useful returns.",
            timing: TurnTiming(lastCompletedAt: instant.addingTimeInterval(-7200), checkedAt: instant)),
        ThreadInsight(id: "thr_preview_accessibility", folder: "/fixture/Spleen", updatedAt: instant, topic: "Long titles keep both timestamps visible.",
            timing: TurnTiming(lastCompletedAt: instant.addingTimeInterval(-300), checkedAt: instant))]
    try notes.save(to: fixture.appendingPathComponent("relevance.json"))
    let populatedModel = AppModel(repository: repository, catalogFetcher: { _ in ([], false) }, insightFetcher: { _, _ in [] }, now: { instant })
    let emptyRepository = StateRepository(url: fixture.appendingPathComponent("empty/state.json"))
    try emptyRepository.save(SavedState())
    let emptyModel = AppModel(repository: emptyRepository, catalogFetcher: { _ in ([], false) }, insightFetcher: { _, _ in [] }, now: { instant })
    let deadline = Date().addingTimeInterval(3)
    while (populatedModel.indexing || emptyModel.indexing) && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.002))
    }
    guard !populatedModel.indexing && !emptyModel.indexing else { throw NativePreviewError.snapshotTimeout }
    for (index, item) in state.destinations.prefix(3).enumerated() {
        populatedModel.receiveLiveState(LiveSessionState(key: item.conversationKey, source: "synthetic-preview", observedAt: instant,
            sequence: 1, activity: index == 1 ? .waitingForApproval : .working, isUnread: index != 1))
    }
    populatedModel.receiveLiveState(LiveSessionState(key: state.destinations[5].conversationKey, source: "synthetic-preview",
        observedAt: instant, sequence: 1, activity: .working, isUnread: false))
    while populatedModel.indexing && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.002)) }
    var outputs: [URL] = []
    for (appearanceName, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
        let scenarios: [(String, AppModel.Mode, String?)] = [
            ("compass", .compass, "thr_preview_interaction"),
            ("compass-claude", .compass, "01234567-89ab-cdef-0123-456789abcdef"),
            ("compass-long", .compass, "thr_preview_accessibility"),
            ("compass-recents", .compass, "thr_preview_accessibility"),
            ("compass-high-contrast", .compass, "thr_preview_interaction"),
            ("compass-empty", .compass, nil),
            ("search", .search, nil), ("search-empty", .search, nil),
            ("settings", .settings, nil), ("editor", .editor, nil)
        ]
        for (name, mode, selectedThread) in scenarios {
            let model = name == "compass-empty" ? emptyModel : populatedModel
            model.prepare()
            let size: NSSize
            switch mode {
            case .compass:
                size = CompassLayout.size
                if let selectedThread { model.selectedID = model.compassItems.first { $0.threadID == selectedThread }?.id }
                if name == "compass-recents", let entry = model.recentSessions.last { model.selectRecent(entry.id) }
            case .search:
                size = SpleenStyle.managementSize
                model.beginSearch(name == "search-empty" ? "No matching conversation" : "")
            case .settings: size = SpleenStyle.managementSize; model.showSettings()
            case .editor:
                size = SpleenStyle.managementSize
                model.edit(state.destinations[5])
            }
            let canvasSize = NSSize(width: size.width + 48, height: size.height + 48)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: canvasSize),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: name == "compass-high-contrast"
                ? (appearanceName == "dark" ? .accessibilityHighContrastDarkAqua : .accessibilityHighContrastAqua)
                : appearance)
            window.animationBehavior = .none
            let canvas = NativePreviewBacking(frame: NSRect(origin: .zero, size: canvasSize))
            canvas.dark = appearanceName == "dark"
            // Liquid Glass is composited by the window server, so snapshots use the material fallback.
            let hosting = NSHostingView(rootView: SwitcherView(model: model).environment(\.spleenSnapshot, true))
            hosting.sizingOptions = []
            hosting.frame = NSRect(x: 24, y: 24, width: size.width, height: size.height)
            canvas.addSubview(hosting)
            window.contentView = canvas
            defer { window.contentView = nil; window.close() }
            canvas.layoutSubtreeIfNeeded()
            // Allow SwiftUI's native controls and text layout to finish mounting.
            RunLoop.current.run(until: Date().addingTimeInterval(0.04))
            canvas.layoutSubtreeIfNeeded()
            let scale = 2
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                pixelsWide: Int(canvasSize.width) * scale, pixelsHigh: Int(canvasSize.height) * scale,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
                throw NativePreviewError.bitmapUnavailable
            }
            bitmap.size = canvasSize
            canvas.cacheDisplay(in: canvas.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else {
                throw NativePreviewError.bitmapUnavailable
            }
            let output = directory.appendingPathComponent("native-fixture-\(name)-\(appearanceName)@2x.png")
            try data.write(to: output, options: .atomic)
            outputs.append(output)
            model.endPresentation()
        }
    }
    return outputs
}

private final class NativePreviewBacking: NSView {
    var dark = false
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: dark ? 0.15 : 0.88, alpha: 1).setFill()
        dirtyRect.fill()
    }
}
