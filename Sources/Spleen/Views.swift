import SwiftUI
import AppKit
import SpleenCore

struct DotButton: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Button { model.openDot?() } label: {
            HStack(spacing: 7) {
                Image(systemName: "circle.inset.filled").foregroundStyle(SpleenStyle.accent)
                Text("Dot").font(.system(size: 12, weight: .medium))
                Text("⌘D").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).frame(height: 36)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain).spleenSurface(.chrome)
        .help(model.dotURL == nil ? "Set up your Dot link · ⌘D" : "Open your Dot · ⌘D")
        .accessibilityLabel(model.dotURL == nil ? "Set up your Dot" : "Open your Dot")
    }
}

struct SwitcherView: View {
    @ObservedObject var model: AppModel
    var searchReady: ((NSTextField) -> Void)?
    var compassFocusChanged: ((CompassKeyboardFocus?) -> Void)?
    @FocusState private var titleFocused: Bool
    @State private var confirmRemoval = false
    var body: some View {
        Group {
            if model.mode == .compass {
                CompassView(model: model, focusChanged: compassFocusChanged)
            } else {
                management
            }
        }
        .onChange(of: model.mode) { mode in
            if mode == .editor { titleFocused = true }
        }
        .confirmationDialog("Remove this destination?", isPresented: $confirmRemoval) {
            Button("Remove destination", role: .destructive) { model.removeEdited() }
        } message: { Text("The conversation itself won’t be changed.") }
    }

    // Same structure as the compass: header controls, one glass reading panel,
    // and a footer capsule. Content inside the panel uses plain fills, never nested glass.
    private var management: some View {
        SpleenGlassGroup(spacing: 10) {
            VStack(spacing: 0) {
                SwitcherHeader(title: model.mode == .search ? "All conversations" : (model.mode == .settings ? "Settings" : "Save a conversation")) {
                    if model.mode == .search { DotButton(model: model) }
                    QuietIconButton(symbol: "xmark", label: "Dismiss · Escape") { model.cancel?() }
                        .padding(4).spleenSurface(.chrome)
                }
                if model.mode == .search { search }
                else if model.mode == .editor { editor }
                else { settings }
            }
        }
        .frame(width: SpleenStyle.managementSize.width, height: SpleenStyle.managementSize.height)
        .tint(SpleenStyle.accent)
    }

    /// The glass reading surface for each management view. Errors stay inside it,
    /// so red text is never drawn straight over the desktop.
    private func panel<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) {
            content()
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20).padding(.vertical, 10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .spleenSurface(.panel)
        .padding(.horizontal, 22).padding(.top, 4).padding(.bottom, 12)
    }

    private var search: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.system(size: 16, weight: .medium)).foregroundStyle(SpleenStyle.accent)
                NativeSearchField(text: $model.query, onReady: searchReady)
                    .frame(height: 26).accessibilityLabel("Search conversations")
                if !model.query.isEmpty {
                    QuietIconButton(symbol: "xmark.circle.fill", label: "Clear search") { model.query = "" }
                }
            }
            .padding(.leading, 18).padding(.trailing, 10).frame(height: 48)
            .spleenSurface(.chrome)
            .padding(.horizontal, 22).padding(.top, 4)
            panel {
                HStack(spacing: 8) {
                    Text(model.query.isEmpty ? "CONVERSATIONS" : "\(model.results.count) RESULTS")
                        .font(.system(size: 9, weight: .semibold)).tracking(1.2).foregroundStyle(.secondary)
                    Spacer()
                    if model.updateReady {
                        Button("New chats ready") { model.applyCatalogUpdate() }.font(.system(size: 11))
                    } else {
                        Text(model.catalogStatus).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
                    }
                    QuietIconButton(symbol: "arrow.clockwise", label: "Refresh conversations") { model.refreshCatalog(force: true) }
                        .disabled(model.refreshing || !model.catalogDiscoveryEnabled)
                }.buttonStyle(.plain).padding(.leading, 20).padding(.trailing, 10).frame(height: 40)
                if model.results.isEmpty {
                    searchEmptyState
                } else {
                    ScrollViewReader { reader in
                        ScrollView {
                            LazyVStack(spacing: 2) {
                                ForEach(model.results) { item in
                                    searchRow(item).id(item.id)
                                }
                            }.padding(.horizontal, 8).padding(.bottom, 8)
                        }
                        .onChange(of: model.selectedID) { id in if let id { reader.scrollTo(id) } }
                    }
                }
            }
            .padding(.top, 6)
            SpleenBar {
                KeyboardHint(key: "↑ ↓", label: "select")
                KeyboardHint(key: "↵", label: "open")
                KeyboardHint(key: "esc", label: "close")
                Spacer()
                HStack(spacing: 2) {
                    QuietIconButton(symbol: "plus", label: "Add conversation") { model.edit() }
                    QuietIconButton(symbol: "gearshape", label: "Settings") { model.showSettings() }
                }
            }
        }
    }

    private func searchRow(_ item: Destination) -> some View {
        let selected = model.selectedID == item.id
        let live = model.liveState(item)
        return HStack(spacing: 0) {
            Button {
                model.selectedID = item.id; model.openSelected()
            } label: {
                HStack(spacing: 12) {
                    ProviderMark(provider: item.provider, size: 30, candy: selected)
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            Text(item.title).font(.system(size: 14, weight: .medium)).lineLimit(1)
                            if item.pinned { Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(.secondary) }
                            AttentionBadges(sample: live)
                        }
                        HStack(spacing: 8) {
                            Text(model.subtitle(item)).lineLimit(1).layoutPriority(-1)
                            if let timing = model.timingLabel(item, separator: " · ") {
                                Text("·").foregroundStyle(.tertiary)
                                Text(timing).lineLimit(1).help(model.timingHelp(item))
                            }
                        }.font(.system(size: 10.5)).foregroundStyle(selected ? Color.primary.opacity(0.85) : Color.secondary)
                    }
                    Spacer(minLength: 8)
                    KeyCap(text: "↵", candy: true).opacity(selected ? 1 : 0)
                }
                .padding(.leading, 12).padding(.trailing, 8).frame(height: 60)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(["Open \(item.title)", item.provider.displayName, model.timingLabel(item, separator: ", "), model.liveState(item)?.accessibilityText].compactMap { $0 }.joined(separator: ", "))
            .accessibilityValue(selected ? "Selected" : "")
            .accessibilityAddTraits(selected ? .isSelected : [])
            QuietIconButton(symbol: "ellipsis", label: "Edit \(item.title)") { model.edit(item) }
                .padding(.trailing, 8)
        }
        .candyText(selected, palette: SpleenStyle.candy(for: item.provider))
        .background(SpleenRowHighlight(selected: selected, palette: SpleenStyle.candy(for: item.provider)))
        .workingAccent(live?.activity == .working, compact: true)
    }

    private var searchEmptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: model.query.isEmpty ? "bubble.left.and.bubble.right" : "magnifyingglass")
                .font(.system(size: 30, weight: .light)).foregroundStyle(SpleenStyle.accent).padding(.bottom, 4)
            Text(model.indexing && model.query.isEmpty ? "Preparing your conversations…" : (model.query.isEmpty ? (model.usesNavigationCompass ? "No recorded navigation yet" : "Keep your next move close.") : "No matching conversations"))
                .font(.system(size: 17, weight: .medium))
            Text(model.indexing && model.query.isEmpty ? "Your cached list will be ready shortly." : (model.query.isEmpty ? (model.usesNavigationCompass ? "Type a title to search all conversations. Opening one starts your history." : "Save a Codex or Claude conversation to get started.") : "Try a different title, topic, or project."))
                .font(.system(size: 12)).foregroundStyle(.secondary)
            if model.query.isEmpty {
                Button("Add conversation") { model.edit() }.buttonStyle(.borderedProminent).padding(.top, 6)
            } else {
                Button("Clear search") { model.query = "" }.buttonStyle(.bordered).padding(.top, 6)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var editor: some View {
        VStack(spacing: 0) {
            panel {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(model.editorID == nil ? "Keep a conversation close." : "Make it easy to recognize.")
                            .font(.system(size: 22, weight: .semibold))
                        Text("Give it a name you’ll remember, then add its link.")
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                    }.padding(.bottom, 4)
                    editorField("NAME") {
                        TextField("Conversation name", text: $model.editorTitle)
                            .focused($titleFocused)
                            .onAppear { DispatchQueue.main.async { titleFocused = true } }
                            .accessibilityLabel("Conversation name")
                    }
                    editorField("CONVERSATION LINK") {
                        TextField("Paste a Codex or Claude link", text: $model.editorLink)
                            .accessibilityLabel("Codex or Claude conversation link")
                    }
                    Text("Codex and Claude chat links are supported. Claude Code links are experimental. A thread ID opens in Codex.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Divider()
                    Toggle(isOn: $model.editorPinned) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Pin to your compass").font(.system(size: 13, weight: .medium))
                            Text("Keep up to two conversations nearby.").font(.system(size: 11)).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.toggleStyle(.switch).controlSize(.small)
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            SpleenBar(height: 44, trailingInset: 8) {
                if model.editorCanRemove {
                    Button("Remove…", role: .destructive) { confirmRemoval = true }
                }
                Spacer()
                HStack(spacing: 8) {
                    Button("Back") { model.mode = .search; model.error = nil }
                    Button("Save conversation") { model.saveEditor() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }
            }
            .controlSize(.large)
        }
    }

    private func editorField<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 9, weight: .semibold)).tracking(1).foregroundStyle(.secondary)
            content().textFieldStyle(.plain).font(.system(size: 14))
                .padding(11)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(SpleenStyle.line))
        }
    }

    private var settings: some View {
        VStack(spacing: 0) {
            panel {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        SettingsSection(title: "Keyboard shortcut", symbol: "keyboard") {
                            HStack {
                                Text("Open Spleen").font(.system(size: 13, weight: .medium))
                                Spacer()
                                KeyCap(text: model.shortcutDraft.label, emphasized: true)
                            }
                            HStack(spacing: 16) {
                                Toggle("⌃ Control", isOn: $model.shortcutDraft.control)
                                Toggle("⌥ Option", isOn: $model.shortcutDraft.option)
                                Toggle("⌘ Command", isOn: $model.shortcutDraft.command)
                                Toggle("⇧ Shift", isOn: $model.shortcutDraft.shift)
                            }.toggleStyle(.checkbox).font(.system(size: 12))
                            HStack {
                                Picker("Key", selection: $model.shortcutDraft.key) {
                                    ForEach(Shortcut.keys, id: \.self) { Text($0).tag($0) }
                                }.frame(width: 155)
                                Spacer()
                                Text("Letter keys use US keyboard positions.")
                                    .font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                            Text(model.shortcutStatus).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        SettingsSection(title: "Dot", symbol: "circle.inset.filled") {
                            TextField("Paste your Dot’s Codex chat link", text: $model.dotLinkDraft)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityLabel("Dot conversation link")
                            Text("Open your Dot with ⌘D while Spleen is open, or choose Open Dot from the menu bar.")
                                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        SettingsSection(title: "Recent conversations", symbol: "clock.arrow.circlepath") {
                            settingsToggle("Remember recent selections on this Mac", isOn: $model.rememberDraft)
                            settingsToggle("Build compass from recent navigation", isOn: $model.navigationFirstDraft)
                            Text("Uses recorded selections and visits, not old task text or background activity. All conversations remain searchable.")
                                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            HStack {
                                Text("Return quickly to the conversations you’ve used.")
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                                Spacer()
                                Button("Clear history") { model.clearRecents() }.controlSize(.small)
                            }
                        }
                        SettingsSection(title: "Codex navigation", symbol: "arrow.triangle.branch") {
                            settingsToggle("Remember visited Codex Desktop sessions", isOn: $model.observeCodexDraft)
                            Text("Records exact foreground local thread routes for 30 days. No messages, screenshots, or API requests. Missing routes remain unknown; activity is not a visit.")
                                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            settingsStatus(model.codexContextStatus)
                        }
                        SettingsSection(title: "Claude", symbol: "sun.max") {
                            settingsToggle("Remember visited Claude Desktop sessions", isOn: $model.observeClaudeDraft)
                            Text("Keeps titles, identities, and available reply times for 30 days. Checks the open Code session for working and unread indicators, including in the background. Message bodies are not read.")
                                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            settingsStatus(model.claudeContextStatus)
                        }
                        SettingsSection(title: "Decisions assessment", symbol: "checkmark.bubble") {
                            Text("Select a conversation, then review its exact excerpt before one API request. Nothing is sent in the background.")
                                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            HStack {
                                Button("Review selected conversation…") { model.reviewSelectedAssessment() }
                                    .disabled(model.decisionReviewBusy)
                                if model.decisionReviewBusy { Button("Stop") { model.stopReviewedAssessment() } }
                            }
                            settingsStatus(model.decisionReviewStatus)
                            Divider()
                            Text("Or assess Codex cards on screen each time you open Spleen. Only cards whose text changed are sent.")
                                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            HStack {
                                if model.automaticAssessmentEnabled {
                                    Button("Pause assessment on open") { model.pauseAutomaticAssessment() }
                                } else {
                                    Button("Assess cards on open…") { model.requestAutomaticAssessment() }
                                }
                            }
                            settingsStatus(model.automaticAssessmentStatus)
                        }
                        SettingsSection(title: "Codex", symbol: "chevron.left.forwardslash.chevron.right") {
                            settingsToggle("Discover Codex projects automatically", isOn: $model.automaticDiscoveryDraft)
                            if !model.automaticDiscoveryDraft { folderSettings }
                            settingsStatus(model.unreadIndicatorStatus)
                            settingsStatus(model.liveIndicatorStatus)
                            if model.hasHiddenChats {
                                Button("Restore removed discovered chats") { model.restoreHiddenChats() }.controlSize(.small)
                            }
                        }
                    }.padding(10)
                }
            }
            SpleenBar(height: 44, trailingInset: 8) {
                Button("Quit Spleen") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                Spacer()
                HStack(spacing: 8) {
                    Button("Back") { model.mode = .search; model.error = nil }
                    Button("Save settings") { model.saveSettings() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }
            }
            .controlSize(.large)
        }.font(.system(size: 13))
    }

    private func settingsStatus(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func settingsToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(title).frame(maxWidth: .infinity, alignment: .leading)
        }.toggleStyle(.switch).controlSize(.small)
    }

    private var folderSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Included folders").font(.system(size: 12, weight: .medium))
                Spacer()
                Button("Add folder…") {
                    let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
                    panel.allowsMultipleSelection = false; panel.prompt = "Include folder"
                    if let window = NSApp.keyWindow {
                        panel.beginSheetModal(for: window) { response in
                            if response == .OK, let url = panel.url { model.addCatalogFolder(url.path) }
                        }
                    }
                }.disabled(model.catalog.folders.count >= 10).controlSize(.small)
            }
            ForEach(model.catalog.folders, id: \.self) { folder in
                HStack {
                    Label(folder, systemImage: "folder").font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    QuietIconButton(symbol: "minus.circle", label: "Stop discovering in \(folder)") { model.removeCatalogFolder(folder) }
                }
            }
            Text("Exact folders only. Titles and short excerpts stay on this Mac.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}
