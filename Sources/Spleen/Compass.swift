import AppKit
import SwiftUI
import SpleenCore

enum CompassDirection: Int {
    case up = 1, right = 2, down = 3, left = 4
    var opposite: Int { (rawValue + 1) % 4 + 1 }
}

enum CompassSelection {
    // Slots stay fixed for the whole invocation. Moving back from an arm returns
    // to the center; a perpendicular arrow selects that arm directly.
    static func next(currentID: UUID?, items: [Destination], direction: CompassDirection) -> UUID? {
        guard let first = items.first else { return nil }
        let current = items.firstIndex { $0.id == currentID } ?? 0
        let target = current == direction.opposite ? 0 : direction.rawValue
        return items.indices.contains(target) ? items[target].id : (currentID ?? first.id)
    }
}

enum CompassKeyboardFocus: Hashable {
    case choice(UUID)
    case recent(UUID)
    case emptyAction
}

enum CompassLayout {
    static let compassWidth: CGFloat = 760
    static let recentWidth: CGFloat = 300
    static let size = NSSize(width: compassWidth + recentWidth + 28, height: 620)
    /// Card centers inside the 380pt compass area, in center/up/right/down/left order.
    /// Every neighbour keeps a 16pt gap, so glass surfaces stay distinct.
    static let positions: [CGPoint] = [
        CGPoint(x: 380, y: 190), CGPoint(x: 380, y: 58),
        CGPoint(x: 630, y: 190), CGPoint(x: 380, y: 322), CGPoint(x: 130, y: 190)
    ]
    static func cardSize(index: Int) -> CGSize {
        switch index {
        case 0: return CGSize(width: 252, height: 120)
        case 1, 3: return CGSize(width: 252, height: 112)
        default: return CGSize(width: 216, height: 112)
        }
    }
}

struct CompassView: View {
    @ObservedObject var model: AppModel
    var focusChanged: ((CompassKeyboardFocus?) -> Void)?
    @FocusState private var keyboardFocus: CompassKeyboardFocus?
    private let keys = ["↵", "↑", "→", "↓", "←"]

    var body: some View {
        SpleenGlassGroup(spacing: 10) {
            HStack(alignment: .top, spacing: 6) {
            VStack(spacing: 0) {
                SwitcherHeader {
                    DotButton(model: model)
                    Text(model.state.shortcut.label)
                        .font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
                        .padding(.horizontal, 14).frame(height: 36)
                        .spleenSurface(.chrome)
                }

                if model.compassItems.isEmpty {
                    emptyState.padding(28).spleenSurface(.preview)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ZStack(alignment: .topLeading) {
                        // The compass and its hit targets stay fixed while selection changes.
                        ForEach(Array(model.compassItems.prefix(5).enumerated()), id: \.element.id) { index, item in
                            choice(item, index: index)
                                .position(CompassLayout.positions[index])
                        }
                    }
                    .frame(height: 380)
                    if let item = model.selectedCompassPreview {
                        selectedPreview(item)
                            .padding(.horizontal, 22).padding(.top, 6).padding(.bottom, 12)
                    }
                }
                footer
            }
            .frame(width: CompassLayout.compassWidth, height: CompassLayout.size.height)
                recentPanel
                    .frame(width: CompassLayout.recentWidth, height: 522)
                    .padding(.top, 74).padding(.trailing, 22)
            }
        }
        .frame(width: CompassLayout.size.width, height: CompassLayout.size.height)
        .tint(SpleenStyle.accent)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Choose a conversation")
        .onChange(of: keyboardFocus) { focus in
            switch focus {
            case let .choice(id): model.selectCompass(id)
            case let .recent(id): model.selectRecent(id)
            default: break
            }
            focusChanged?(focus)
        }
        .onChange(of: selectionFocus) { focus in
            switch keyboardFocus {
            case .choice, .recent: keyboardFocus = focus
            default: break
            }
        }
        .onDisappear { focusChanged?(nil) }
    }

    private var selectionFocus: CompassKeyboardFocus? {
        model.selectedID.map { model.browsingRecents ? .recent($0) : .choice($0) }
    }

    private var recentPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Recent sessions").font(.system(size: 15, weight: .semibold))
                    Text("Recently opened or created").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                KeyCap(text: model.browsingRecents ? "↑ ↓" : "→ →", emphasized: model.browsingRecents)
            }.padding(.horizontal, 18).padding(.top, 18).padding(.bottom, 14)
            if model.recentSessions.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 25, weight: .light)).foregroundStyle(SpleenStyle.accent)
                    Text(model.state.rememberRecents ? "Your next return starts here." : "Recent history is off.")
                        .font(.system(size: 13, weight: .medium))
                    Text(model.state.rememberRecents ? "New sessions, sessions you open with Spleen, and observed Claude visits appear here." : "Enable recent selections in Settings to keep your sessions here.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.padding(22).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { reader in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(model.recentSessions) { entry in recentRow(entry).id(entry.id) }
                        }.padding(.horizontal, 8).padding(.bottom, 8)
                    }
                    .onChange(of: selectionFocus) { focus in
                        if case let .recent(id) = focus { reader.scrollTo(id) }
                    }
                    .onAppear {
                        if model.browsingRecents, let id = model.selectedID { reader.scrollTo(id) }
                    }
                }
            }
            HStack(spacing: 12) {
                KeyboardHint(key: model.browsingRecents ? "←" : "→ →", label: model.browsingRecents ? "compass" : "browse")
                Spacer(minLength: 0)
                if !model.recentSessions.isEmpty {
                    Text("\(model.recentSessions.count) sessions").font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }.padding(.horizontal, 18).frame(height: 38)
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .spleenSurface(.panel)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recent sessions, most recently opened or created first")
    }

    private func recentRow(_ entry: RecentSession) -> some View {
        let item = entry.destination
        let selected = model.browsingRecents && model.selectedID == item.id
        let live = model.liveState(item)
        return Button {
            model.selectRecent(item.id); model.openSelected()
        } label: {
            HStack(alignment: .top, spacing: 10) {
                ProviderMark(provider: item.provider, size: 24, candy: selected).padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title).font(.system(size: 12.5, weight: .medium))
                        .lineLimit(2).multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    // The list is ordered by navigation, so its row shows that time;
                    // the reply time stays in the tooltip.
                    HStack(spacing: 6) {
                        Text(model.recentLabel(entry)).font(.system(size: 10.5))
                            .foregroundStyle(.secondary).lineLimit(1).help(model.timingHelp(item))
                        Spacer(minLength: 0)
                        AttentionBadges(sample: live)
                    }
                    .frame(height: 20)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .candyText(selected, palette: SpleenStyle.candy(for: item.provider))
        .background(SpleenRowHighlight(selected: selected, palette: SpleenStyle.candy(for: item.provider)))
        .workingAccent(live?.activity == .working, compact: true)
        .focused($keyboardFocus, equals: .recent(item.id))
        .accessibilityLabel([item.title, item.provider.displayName, model.timingLabel(item, separator: ", "), model.liveState(item)?.accessibilityText].compactMap { $0 }.joined(separator: ", "))
        .accessibilityValue(selected ? "Selected" : "")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint("Open conversation")
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 32, weight: .light)).foregroundStyle(SpleenStyle.accent)
                .padding(.bottom, 4)
            Text(model.indexing || model.refreshing ? "Finding your conversations…" : "A place to pick up where you left off.")
                .font(.system(size: 19, weight: .medium))
            Text("Your conversations will be one shortcut away.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            Button("Add a conversation") { model.edit() }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .focused($keyboardFocus, equals: .emptyAction)
                .padding(.top, 6)
        }
    }

    private func choice(_ item: Destination, index: Int) -> some View {
        let selected = !model.browsingRecents && item.id == model.selectedID
        let center = index == 0
        let size = CompassLayout.cardSize(index: index)
        let project = model.preview(item).project
        let hint = keyHint(for: index)
        let live = model.liveState(item)
        return Button {
            model.selectCompass(item.id)
            model.openSelected()
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    ProviderMark(provider: item.provider, size: 18, candy: selected)
                    Text(item.provider.displayName).font(.system(size: 11, weight: .medium))
                        .foregroundStyle(selected ? Color.primary.opacity(0.85) : Color.secondary)
                    if item.pinned {
                        Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 2)
                    AttentionBadges(sample: live, showsWorking: false)
                    // Browsing recents leaves no key for a card; keep the cap's space, not an empty cap.
                    KeyCap(text: hint.isEmpty ? "↵" : hint, candy: selected).opacity(hint.isEmpty ? 0 : 1)
                }
                Text(item.title)
                    .font(.system(size: center ? 15 : 13.5, weight: .semibold))
                    .lineLimit(2).multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    if live?.activity == .working { WorkingBadge() }
                    Text(model.primaryTimingLabel(item) ?? project ?? "Saved conversation")
                        .font(.system(size: 10.5)).foregroundStyle(selected ? Color.primary.opacity(0.85) : Color.secondary)
                        .lineLimit(1)
                        .help(model.timingHelp(item))
                }
                .frame(height: 20, alignment: .leading)
            }
            .padding(.horizontal, 15).padding(.vertical, 11)
            .frame(width: size.width, height: size.height)
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(ConversationButtonStyle(selected: selected, provider: item.provider, working: live?.activity == .working))
        .focused($keyboardFocus, equals: .choice(item.id))
        .accessibilityLabel([item.title, item.provider.displayName, project, model.timingLabel(item, separator: ", "), model.liveState(item)?.accessibilityText].compactMap { $0 }.joined(separator: ", "))
        .accessibilityValue(selected ? "Selected" : "")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint("Open conversation")
    }

    private func keyHint(for index: Int) -> String {
        if model.browsingRecents { return "" }
        let current = model.compassItems.firstIndex { $0.id == model.selectedID } ?? 0
        if index == current { return "↵" }
        if index == 0 { return keys[(current + 1) % 4 + 1] }
        // From the opposite arm, the first press returns to the center.
        if current > 0 && index == (current + 1) % 4 + 1 { return keys[index] + keys[index] }
        return keys[index]
    }

    private func selectedPreview(_ item: Destination) -> some View {
        let preview = model.preview(item)
        return VStack(alignment: .leading, spacing: 8) {
            // The selected card already shows the title; this row carries what the card leaves out.
            HStack(spacing: 8) {
                Text(model.subtitle(item))
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
                if let task = model.taskLabel(item) {
                    Text("·").foregroundStyle(.tertiary)
                    Text(task).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                if let timing = model.timingLabel(item, separator: " · ") {
                    Text(timing).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            Text(preview.excerpt ?? "Open this conversation to pick up where you left off.")
                .font(.system(size: 12)).foregroundStyle(.primary.opacity(0.85)).lineSpacing(2).lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 22).padding(.vertical, 15)
        .frame(height: 112, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .spleenSurface(.preview)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview: \(item.title)")
        .accessibilityValue([model.subtitle(item), model.timingLabel(item, separator: ", "), preview.excerpt ?? "No recent conversation excerpt available"].compactMap { $0 }.joined(separator: ". "))
        .allowsHitTesting(false)
    }

    private var footer: some View {
        SpleenBar {
            if let error = model.error {
                Text(error).font(.system(size: 11)).foregroundStyle(.red).lineLimit(2)
            } else {
                KeyboardHint(key: model.browsingRecents ? "↑ ↓" : "↑ ↓ ← →", label: model.browsingRecents ? "browse" : "choose")
                KeyboardHint(key: "↵", label: "open")
                KeyboardHint(key: "esc", label: "close")
            }
            Spacer(minLength: 8)
            Button { model.beginSearch() } label: {
                Label("Type to search", systemImage: "magnifyingglass")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }.buttonStyle(.plain).help("Search all conversations")
            QuietIconButton(symbol: "gearshape", label: "Settings") { model.showSettings() }
        }
    }
}

// An AppKit field preserves native input methods, dead keys, and text commands.
// The controller replays the first typing event once this field joins the window.
struct NativeSearchField: NSViewRepresentable {
    @Binding var text: String
    var onReady: ((NSTextField) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> SearchTextField {
        let field = SearchTextField()
        field.placeholderString = "Find a conversation…"
        field.font = .systemFont(ofSize: 18, weight: .regular)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = context.coordinator
        field.ready = onReady
        field.stringValue = text
        return field
    }
    func updateNSView(_ field: SearchTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text, !((field.currentEditor() as? NSTextView)?.hasMarkedText() ?? false) {
            field.stringValue = text
        }
    }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: NativeSearchField
        init(_ parent: NativeSearchField) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }
    }
}

final class SearchTextField: NSTextField {
    var ready: ((NSTextField) -> Void)?
    private var attachmentGeneration = 0
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        attachmentGeneration &+= 1
        guard let attachedWindow = window else { return }
        let generation = attachmentGeneration
        DispatchQueue.main.async { [weak self, weak attachedWindow] in
            guard let self, let attachedWindow, self.window === attachedWindow,
                  self.attachmentGeneration == generation else { return }
            self.ready?(self)
        }
    }
}
