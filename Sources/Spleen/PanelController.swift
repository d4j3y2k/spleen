import AppKit
import SwiftUI
import Combine
import SpleenCore

final class SwitcherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class PanelController: NSObject, NSWindowDelegate {
    let model: AppModel
    let panel: SwitcherPanel
    private(set) var session = PanelSession()
    private var keyMonitor: Any?
    private var activationObserver: NSObjectProtocol?
    private var modeObserver: AnyCancellable?
    private var pendingSearchEvents: [NSEvent] = []
    private weak var searchField: NSTextField?
    private var compassKeyboardFocus: CompassKeyboardFocus?
    private var restorationTraceGeneration = 0
    private var handoffPending = false
    private var handoffGeneration = 0
    private var pendingSearchCaret = false
    var dispatchSearch: (SearchHandoff, @escaping (Bool) -> Void) -> Void = { SearchHandoffLauncher.open($0, to: .moonshine, completion: $1) }
    var dispatchURL: (URL) -> Bool = { NSWorkspace.shared.open($0) }
    var currentPID: () -> Int32? = { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    var restorePID: (Int32) -> Void = { pid in NSRunningApplication(processIdentifier: pid)?.activate(options: []) }

    init(model: AppModel) {
        self.model = model
        panel = SwitcherPanel(contentRect: NSRect(origin: .zero, size: CompassLayout.size),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.title = "Spleen"
        panel.identifier = NSUserInterfaceItemIdentifier("SpleenSwitcher")
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.delegate = self
        let hostingView = NSHostingView(rootView: SwitcherView(model: model, searchReady: { [weak self] field in
            guard let self, self.session.isPresented, self.model.mode == .search,
                  field.window === self.panel else { return }
            self.searchField = field
            self.panel.makeFirstResponder(field)
            self.placeSearchCaret()
            let pending = self.pendingSearchEvents
            self.pendingSearchEvents = []
            for event in pending {
                guard self.session.isPresented else { break }
                if let forwarded = self.handleKeyDown(event) { self.panel.sendEvent(forwarded) }
            }
        }, compassFocusChanged: { [weak self] focus in
            self?.compassKeyboardFocus = focus
        }))
        hostingView.sizingOptions = []
        panel.contentView = hostingView
        model.switchSearch = { [weak self] in self?.switchSearch() }
        model.openDestination = { [weak self] in self?.open($0) }
        model.openDot = { [weak self] in self?.openDot() }
        model.cancel = { [weak self] in self?.dismiss(.cancel) }
        modeObserver = model.$mode.removeDuplicates().sink { [weak self] mode in
            self?.resize(for: mode)
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.session.isPresented else { return event }
            guard event.window === self.panel else {
                if diagnosticTracingEnabled {
                    traceNavigation(DiagnosticNavigationKey(keyCode: event.keyCode, compass: false), "otherWindow")
                }
                return event
            }
            return self.handleKeyDown(event)
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main) { [weak self] note in
                // A consent or key-file dialog stays up while the user switches apps (to chmod
                // the key file, say); dismissing would hide its outcome, as windowDidResignKey knows.
                guard let self, self.session.isPresented, !self.model.isPresentingModal,
                      let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                      app.processIdentifier != self.session.priorPID else { return }
                self.dismiss(.focusLoss)
            }
    }
    @discardableResult func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        let diagnosticKey = diagnosticTracingEnabled ? DiagnosticNavigationKey(keyCode: event.keyCode, compass: model.mode == .compass) : nil
        traceNavigation(diagnosticKey, "received")
        guard session.isPresented else { traceNavigation(diagnosticKey, "pass.hidden"); return event }
        guard !((panel.firstResponder as? NSTextInputClient)?.hasMarkedText() ?? false) else {
            traceNavigation(diagnosticKey, "pass.composition"); return event
        }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if event.keyCode == 53, modifiers.isEmpty {
            traceNavigation(diagnosticKey, event.isARepeat ? "ignore.repeat" : "cancel")
            if !event.isARepeat { dismiss(.cancel) }
            return nil
        }
        if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "d" {
            if !event.isARepeat { openDot() }
            return nil
        }
        if model.mode == .search, !pendingSearchEvents.isEmpty {
            traceNavigation(diagnosticKey, "buffer.searchMount")
            pendingSearchEvents.append(event)
            return nil
        }
        if event.keyCode == 48, modifiers.isEmpty || modifiers == .shift,
           model.mode == .compass || model.mode == .search {
            if !event.isARepeat { switchSearch() }
            return nil
        }
        if model.mode == .compass {
            // Do not interpret the invoking shortcut's held modifiers or key repeat
            // as a confirmation of the newly displayed center choice.
            if modifiers.isEmpty {
                let navigationOrActivation = [123, 124, 125, 126, 36, 49, 76].contains(event.keyCode)
                let otherNativeControl = panel.firstResponder is NSControl && compassKeyboardFocus == nil
                if navigationOrActivation && (model.compassItems.isEmpty || compassKeyboardFocus == .emptyAction || otherNativeControl) {
                    traceNavigation(diagnosticKey, model.compassItems.isEmpty ? "pass.emptyCompass" : "pass.focusedControl")
                    return event
                }
                let direction: CompassDirection?
                switch event.keyCode {
                case 126: direction = .up
                case 124: direction = .right
                case 125: direction = .down
                case 123: direction = .left
                default: direction = nil
                }
                if let direction {
                    if !event.isARepeat || (model.browsingRecents && (direction == .up || direction == .down)) {
                        model.freezeOpening()
                        let previous = model.selectedID
                        model.navigateCompass(direction)
                        traceNavigation(diagnosticKey, previous == model.selectedID ? "compass.unchanged" : "compass.moved")
                        announceSelection(from: previous)
                    } else {
                        traceNavigation(diagnosticKey, "ignore.repeat")
                    }
                    return nil
                }
                if [36, 49, 76].contains(event.keyCode) {
                    traceNavigation(diagnosticKey, event.isARepeat ? "ignore.repeat" : "compass.confirm")
                    if !event.isARepeat { model.openSelected() }
                    return nil
                }
            }
            // Shift and Option remain available for text input and native dead keys.
            guard Self.startsSearch(event) else {
                traceNavigation(diagnosticKey, modifiers.isEmpty ? "pass.native" : "pass.modifiers")
                return event
            }
            pendingSearchEvents = [event]
            model.beginSearch()
            return nil
        }
        // The search editor owns list navigation. A focused result, Edit button,
        // or Settings button must retain its native activation/navigation keys.
        guard model.mode == .search, modifiers.isEmpty,
              let editor = searchField?.currentEditor(), panel.firstResponder === editor else {
            traceNavigation(diagnosticKey, model.mode != .search ? "pass.management" : (!modifiers.isEmpty ? "pass.modifiers" : "pass.focusedControl"))
            return event
        }
        switch event.keyCode {
        case 125, 126:
            traceNavigation(diagnosticKey, "search.navigate")
            let previous = model.selectedID
            model.move(event.keyCode == 125 ? 1 : -1)
            announceSelection(from: previous)
            return nil
        case 36, 76:
            traceNavigation(diagnosticKey, event.isARepeat ? "ignore.repeat" : "search.confirm")
            if !event.isARepeat { model.openSelected() }
            return nil
        default: traceNavigation(diagnosticKey, "pass.native"); return event
        }
    }
    /// Arrow keys move the selection without moving VoiceOver's focus, so say what is now selected.
    private func announceSelection(from previous: UUID?) {
        guard NSWorkspace.shared.isVoiceOverEnabled, model.selectedID != previous,
              let item = (model.compassItems + model.results + model.recentSessions.map(\.destination)).first(where: { $0.id == model.selectedID })
        else { return }
        NSAccessibility.post(element: panel, notification: .announcementRequested, userInfo: [
            .announcement: "\(item.title), \(item.provider.displayName)",
            .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
    static func startsSearch(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .control]).isEmpty,
              !event.isARepeat, event.keyCode != 49 else { return false }
        func printable(_ value: String) -> Bool {
            !value.isEmpty && value.unicodeScalars.allSatisfy {
                !CharacterSet.controlCharacters.contains($0) && !(0xF700...0xF8FF).contains($0.value)
            }
        }
        let characters = event.characters ?? ""
        if !characters.isEmpty { return printable(characters) }
        // A dead key can have no committed characters yet. Preserve the original
        // Option event and let the native field/input method compose it on replay.
        return event.modifierFlags.contains(.option) && printable(event.charactersIgnoringModifiers ?? "")
    }
    private func resize(for mode: AppModel.Mode) {
        // Every surface draws its own shadow on Liquid Glass; older systems keep the window shadow.
        panel.hasShadow = mode != .compass && !SpleenStyle.usesGlass
        let size = mode == .compass ? CompassLayout.size : SpleenStyle.managementSize
        guard panel.frame.size != size else { return }
        let center = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        var origin = NSPoint(x: center.x - size.width / 2, y: center.y - size.height / 2)
        if let frame = (panel.screen ?? NSScreen.main)?.visibleFrame { origin = Self.clamp(origin, size: size, in: frame) }
        panel.setFrame(NSRect(origin: origin, size: size), display: session.isPresented, animate: false)
    }
    /// Keeps the panel inside the screen's visible frame. A panel larger than the screen
    /// keeps its top-left corner visible, so the header and first choices stay reachable.
    static func clamp(_ origin: NSPoint, size: NSSize, in frame: NSRect) -> NSPoint {
        NSPoint(x: min(max(origin.x, frame.minX), max(frame.minX, frame.maxX - size.width)),
                y: min(max(origin.y, frame.minY), frame.maxY - size.height))
    }
    func receiveSearch(_ request: SearchHandoff, orderFront: Bool = true) {
        handoffGeneration += 1; handoffPending = false
        pendingSearchEvents = []
        present(orderFront: orderFront, assessOnOpen: false, searchQuery: request.query)
        if let pid = request.returnPID,
           let app = NSRunningApplication(processIdentifier: pid),
           ![SearchHandoff.App.spleen.bundleID, SearchHandoff.App.moonshine.bundleID].contains(app.bundleIdentifier ?? "") {
            session.present(priorPID: pid)
        }
        model.beginHandoffSearch(request.query)
        pendingSearchCaret = true
        placeSearchCaret()
    }
    private func placeSearchCaret() {
        guard pendingSearchCaret, let searchField, searchField.window === panel else { return }
        searchField.stringValue = model.query
        panel.makeFirstResponder(searchField)
        if let editor = searchField.currentEditor() {
            editor.selectedRange = NSRange(location: (model.query as NSString).length, length: 0)
            pendingSearchCaret = false
        }
    }
    func switchSearch() {
        guard session.isPresented, !handoffPending, model.mode == .compass || model.mode == .search else { return }
        let priorPID = session.priorPID
        let wasKey = panel.isKeyWindow
        let request = SearchHandoff(query: model.query, returnPID: priorPID)
        handoffGeneration += 1
        let generation = handoffGeneration
        handoffPending = true
        dismiss(.dispatch, endingPresentation: false)
        dispatchSearch(request) { [weak self] accepted in
            guard let self, self.handoffGeneration == generation else { return }
            self.handoffPending = false
            if accepted { self.model.endPresentation() }
            else {
                self.model.reportTransientError("Couldn’t open Moonshine. Open or install Moonshine, then try Tab again.")
                self.present(reset: false, orderFront: wasKey, assessOnOpen: false)
                self.session.present(priorPID: priorPID)
                self.pendingSearchCaret = self.model.mode == .search
                self.placeSearchCaret()
            }
        }
    }
    func toggle() { session.isPresented ? dismiss(.cancel) : present() }
    /// Menu-bar entry points that open something other than the compass. Its cards are
    /// never on screen there, so these never assess them.
    func presentSearch() { present(assessOnOpen: false, searchQuery: ""); model.beginSearch() }
    func presentEditor() { present(assessOnOpen: false); model.edit() }
    func presentSettings() { present(assessOnOpen: false); model.showSettings() }
    func present(reset: Bool = true, orderFront: Bool = true, assessOnOpen: Bool = true, searchQuery: String? = nil) {
        // Reopening is a new intent even if the outgoing launch has not replied.
        // Its delayed success/failure must not close or restore this presentation.
        handoffGeneration += 1; handoffPending = false

        guard !session.isPresented else {
            if orderFront && !panel.isKeyWindow {
                panel.makeKeyAndOrderFront(nil)
                trace(panel.isKeyWindow ? "panel.represent.key" : "panel.represent.notKey")
            }
            return
        }
        restorationTraceGeneration &+= 1
        if reset { model.prepare(assessOnOpen: assessOnOpen, searchQuery: searchQuery) }
        resize(for: model.mode)
        session.present(priorPID: currentPID())
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(Self.clamp(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.midY - panel.frame.height / 2 + 50),
                                            size: panel.frame.size, in: frame))
        }
        if orderFront { panel.makeKeyAndOrderFront(nil) }
        trace("panel.presented")
        trace(panel.isKeyWindow ? "panel.present.key" : "panel.present.notKey")
    }
    func dismiss(_ reason: DismissReason, endingPresentation: Bool = true) {
        let wasPresented = session.isPresented
        if wasPresented { trace("panel.dismiss.\(reason)") }
        restorationTraceGeneration &+= 1
        let restore = session.dismiss(reason, currentPID: currentPID(), ownPID: ProcessInfo.processInfo.processIdentifier)
        pendingSearchEvents = []
        // SwiftUI removes the previous mode's native editor on a later update.
        // End composition now, so an immediate reopen cannot route its first key
        // into that stale editor before the compass has finished mounting.
        (panel.firstResponder as? NSTextView)?.unmarkText()
        panel.makeFirstResponder(nil)
        compassKeyboardFocus = nil
        panel.orderOut(nil)
        if endingPresentation {
            handoffGeneration += 1; handoffPending = false; pendingSearchCaret = false
            model.endPresentation()
        }
        if let restore {
            trace("focus.restore.requested")
            restorePID(restore)
            if diagnosticTracingEnabled {
                let generation = restorationTraceGeneration
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                    guard let self else { return }
                    guard self.restorationTraceGeneration == generation else {
                        trace("focus.restore.observationSuperseded"); return
                    }
                    guard let current = self.currentPID() else {
                        trace("focus.restore.observedUnavailable"); return
                    }
                    trace(current == restore ? "focus.restore.observedMatch" : "focus.restore.observedOther")
                }
            }
        } else if wasPresented && reason == .cancel {
            trace("focus.restore.notRequested")
        }
    }
    func windowDidBecomeKey(_ notification: Notification) { trace("panel.key.became") }
    func windowDidResignKey(_ notification: Notification) {
        trace("panel.key.resigned")
        if session.isPresented && panel.attachedSheet == nil && !model.isPresentingModal { dismiss(.focusLoss) }
    }
    func open(_ item: Destination) {
        guard session.isPresented else { return }
        do {
            let target = try item.navigationURL
            let priorPID = session.priorPID
            dismiss(.dispatch, endingPresentation: false)
            if dispatchURL(target) {
                trace("dispatch.accepted")
                model.endPresentation()
                model.acceptedDispatch(item.id)
            }
            else {
                trace("dispatch.rejected")
                model.reportTransientError("Couldn’t open this conversation. Check the app or edit its saved link.")
                present(reset: false)
                // A rejected open is the same invocation, including cancellation's
                // original focus target and the exact visible choice order.
                session.present(priorPID: priorPID)
            }
        } catch { model.reportTransientError(error.localizedDescription) }
    }
    func openDot() {
        guard let target = model.dotURL else {
            if !session.isPresented { present(assessOnOpen: false) } // Shows Settings, not cards.
            model.showSettings()
            return
        }
        let priorPID = session.priorPID ?? currentPID()
        dismiss(.dispatch, endingPresentation: false)
        if dispatchURL(target) {
            trace("dot.dispatch.accepted")
            model.endPresentation()
        } else {
            trace("dot.dispatch.rejected")
            model.reportTransientError("Couldn’t open your Dot. Check its link in Settings.")
            present(reset: false)
            session.present(priorPID: priorPID)
        }
    }
    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
    }
}
