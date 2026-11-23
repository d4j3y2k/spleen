import SwiftUI
import AppKit
import SpleenCore

/// The scrolling body of the Usage Limits view. It observes the usage model directly, so each
/// provider's arrival re-renders only these rows.
struct UsageLimitsList: View {
    @ObservedObject var usage: UsageLimitsModel
    var openPage: (ContextProvider) -> Void
    var format = UsageTimeFormat()
    @Environment(\.usageScrollAnchorBottom) private var anchorBottom

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(UsageLimitsModel.providers, id: \.self) { provider in
                    UsageProviderSection(provider: provider, state: usage.state(provider), status: usage.status(provider),
                                         now: usage.now, openedAt: usage.openedAt, format: format) { openPage(provider) }
                }
            }
            .padding(10).padding(.bottom, 6)
            .onAppear { UsageDisplayMarker.mark("usage.content.displayed") }
            .onChange(of: usage.openingID) { _ in UsageDisplayMarker.mark("usage.content.displayed") }
        }
        .modifier(UsageScrollAnchor(bottom: anchorBottom))
    }
}

/// Previews render the end of a long list, to show the last recovery button is reachable.
private struct UsageScrollAnchorKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var usageScrollAnchorBottom: Bool {
        get { self[UsageScrollAnchorKey.self] }
        set { self[UsageScrollAnchorKey.self] = newValue }
    }
}
private struct UsageScrollAnchor: ViewModifier {
    let bottom: Bool
    func body(content: Content) -> some View {
        if #available(macOS 14, *), bottom { content.defaultScrollAnchor(.bottom) } else { content }
    }
}

/// Refresh both providers; coalesced, so it is disabled while both are already checking.
struct UsageRefreshButton: View {
    @ObservedObject var usage: UsageLimitsModel
    var body: some View {
        QuietIconButton(symbol: "arrow.clockwise", label: "Refresh usage limits · ⌘R") { usage.refreshAll() }
            .disabled(!usage.canRefresh)
            .padding(4).spleenSurface(.chrome)
    }
}

struct UsageProviderSection: View {
    let provider: ContextProvider
    let state: UsageLimitsModel.ProviderState
    let status: UsageLimitsModel.Status
    let now: Date
    let openedAt: Date?
    let format: UsageTimeFormat
    let openPage: () -> Void

    private var hue: Color { provider == .claude ? SpleenStyle.claude : SpleenStyle.accent }
    /// A row read during this opening is a fresh row.
    private func markFresh(_ reading: UsageReading) {
        if let openedAt, reading.checkedAt >= openedAt { UsageDisplayMarker.mark("usage.\(provider.rawValue).row") }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ProviderMark(provider: provider, size: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.displayName).font(.system(size: 13, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text(UsageText.status(status, provider: provider, retryAfter: state.retryAfter, now: now, format: format))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if state.inFlight { ProgressView().controlSize(.small).accessibilityLabel("Checking \(provider.displayName)") }
            }
            if let reading = state.reading {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(reading.windows) { window in
                        UsageWindowRow(provider: provider, window: window, hue: hue, now: now, format: format)
                    }
                }
                .onAppear { markFresh(reading) }
                .onChange(of: reading.checkedAt) { _ in markFresh(reading) }
            }
            HStack {
                Spacer()
                Button(action: openPage) {
                    Label("Open usage page", systemImage: "arrow.up.right.square")
                }
                .controlSize(.small)
                .help(UsageLimitsModel.usagePages[provider]?.absoluteString ?? "")
                .accessibilityLabel("Open \(provider.displayName) usage page")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct UsageWindowRow: View {
    let provider: ContextProvider
    let window: UsageWindow
    let hue: Color
    let now: Date
    let format: UsageTimeFormat

    var body: some View {
        let expired = window.isExpired(at: now)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.label).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Spacer(minLength: 8)
                Text(expired ? "was \(window.percentLeft)% left" : "\(window.percentLeft)% left")
                    .font(.system(size: expired ? 12 : 13, weight: expired ? .regular : .semibold)).monospacedDigit()
            }
            UsageMeter(fraction: Double(window.percentLeft) / 100, tint: expired ? Color.secondary : hue)
            HStack(alignment: .firstTextBaseline) {
                Text(UsageText.reset(window, now: now, format: format))
                Spacer(minLength: 8)
                if let countdown = UsageText.countdown(window, now: now, format: format) { Text(countdown).monospacedDigit() }
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .help(window.resetsAt.map { format.precise($0) } ?? "")
        }
        .opacity(expired ? 0.55 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(UsageText.spoken(window, provider: provider, now: now, format: format))
        .accessibilityValue(window.resetsAt.map { format.precise($0) } ?? "")
    }
}

/// A thin meter filled by the share left.
struct UsageMeter: View {
    let fraction: Double
    let tint: Color
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(tint.opacity(0.85))
                    .frame(width: max(0, min(1, fraction)) * geometry.size.width)
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}

enum UsageText {
    static func reason(_ failure: UsageFailure, provider: ContextProvider) -> String {
        switch failure {
        case .missingClient: return provider == .codex ? "Codex app not found" : "Claude Code not found"
        case .signedOut: return provider == .codex ? "Signed out of Codex" : "Signed out of Claude Code"
        case .noSubscriptionLimits: return "No subscription limits for this sign-in"
        case .offlineOrEmpty: return "No limit data returned · check your connection"
        case .timeout: return "Timed out"
        case .incompatible: return provider == .claude ? "Update Claude Code to show limits" : "This Codex version isn’t supported"
        case .accountChanged: return "Account changed · refresh to check"
        case .cancelled: return "Stopped"
        }
    }

    static func status(_ status: UsageLimitsModel.Status, provider: ContextProvider, retryAfter: Date?, now: Date,
                       format: UsageTimeFormat) -> String {
        var text: String
        switch status {
        case .loading: text = "Checking…"
        case .unavailable(let failure, let tried): text = "Unavailable · \(reason(failure, provider: provider)) · tried \(format.time(tried))"
        case .checking(let checked): text = "Last known · checked \(format.time(checked)) · checking…"
        case .checked(let checked): text = "Checked \(format.time(checked))"
        case .lastKnown(let checked, let failure): text = "Last known · checked \(format.time(checked)) · \(reason(failure, provider: provider))"
        }
        if let retryAfter, retryAfter > now { text += " · Try again after \(format.time(retryAfter))" }
        return text
    }

    /// "Resets Tue, Nov 24 at 2:59 PM"; an expired row says when the reset passed.
    static func reset(_ window: UsageWindow, now: Date, format: UsageTimeFormat) -> String {
        guard let date = window.resetsAt else { return "Reset time unavailable" }
        if window.isExpired(at: now) { return "Reset passed \(format.reset(date, now: now)) · waiting for a new reading" }
        return "Resets \(format.reset(date, now: now))"
    }

    /// "in 2 d 4 h" beside a future reset; nothing for an expired or unknown one.
    static func countdown(_ window: UsageWindow, now: Date, format: UsageTimeFormat) -> String? {
        guard let date = window.resetsAt, !window.isExpired(at: now) else { return nil }
        return format.relative(to: date, now: now)
    }

    /// "Codex, weekly limit, 84 percent left, resets Tuesday, November 24 at 2:59 PM, in 2 days 4 hours"
    static func spoken(_ window: UsageWindow, provider: ContextProvider, now: Date, format: UsageTimeFormat) -> String {
        let label = window.label.replacingOccurrences(of: " · ", with: ", ")
        let name = label.prefix(1).lowercased() + label.dropFirst()
        if window.isExpired(at: now) {
            let passed = window.resetsAt.map { ", reset passed \(format.reset($0, now: now, spoken: true))" } ?? ", reset passed"
            return "\(provider.displayName), \(name)\(passed), waiting for a new reading, was \(window.percentLeft) percent left"
        }
        let reset = window.resetsAt.map { "resets \(format.reset($0, now: now, spoken: true)), \(format.relative(to: $0, now: now, spoken: true))" }
            ?? "reset time unavailable"
        return "\(provider.displayName), \(name), \(window.percentLeft) percent left, \(reset)"
    }
}

/// Marks when Usage content first reaches the window server: the first Core Animation commit
/// after the one that carries it (at most one run-loop turn late), not a compositor frame. Used by the opt-in timing trace
/// and the self-test timings, with fixed event names only.
enum UsageDisplayMarker {
    /// Whether the panel is on screen; set by the panel controller. Previews leave it nil.
    static var panelVisible: (() -> Bool)?
    static var observer: ((String) -> Void)?
    /// Called once when Usage content has been committed while the panel is still hidden.
    static var hiddenCommit: (() -> Void)?
    static func mark(_ event: String) {
        guard panelVisible != nil else { return }
        // A transaction of its own on the next turn, after the one that carried the content
        // has been committed: a completion in that one would also wait for its animations
        // (the glass morph between modes), which is not when the content first appears.
        DispatchQueue.main.async {
            CATransaction.begin()
            CATransaction.setCompletionBlock {
                guard panelVisible?() == true else {
                    if event == "usage.content.displayed", let ready = hiddenCommit { hiddenCommit = nil; ready() }
                    return
                }
                trace(event)
                observer?(event)
            }
            CATransaction.commit()
        }
    }
}
