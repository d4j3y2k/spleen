import SwiftUI
import AppKit
import SpleenCore

/// Each provider has its own column. Choose the roomiest rows that all fit at once.
struct UsageLimitsList: View {
    @ObservedObject var usage: UsageLimitsModel
    var openPage: (UsageProvider) -> Void
    var format = UsageTimeFormat()

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(usage.providers, id: \.self) { provider in
                ViewThatFits(in: .vertical) {
                    section(provider, compact: false)
                    section(provider, compact: true)
                    // Very small displays and unusually large accounts can still reach every row.
                    ScrollView { section(provider, compact: true) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .padding(10)
        .onAppear { UsageDisplayMarker.mark("usage.content.displayed") }
        .onChange(of: usage.openingID) { _ in UsageDisplayMarker.mark("usage.content.displayed") }
    }

    private func section(_ provider: UsageProvider, compact: Bool) -> some View {
        UsageProviderSection(provider: provider, state: usage.state(provider), status: usage.status(provider),
                             now: usage.now, openedAt: usage.openedAt, format: format,
                             history: usage.history, compact: compact) { openPage(provider) }
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct UsageRefreshButton: View {
    @ObservedObject var usage: UsageLimitsModel
    var body: some View {
        QuietIconButton(symbol: "arrow.clockwise", label: "Refresh usage limits · ⌘R") { usage.refreshAll() }
            .disabled(!usage.canRefresh)
            .padding(4).spleenSurface(.chrome)
    }
}

struct UsageProviderSection: View {
    let provider: UsageProvider
    let state: UsageLimitsModel.ProviderState
    let status: UsageLimitsModel.Status
    let now: Date
    let openedAt: Date?
    let format: UsageTimeFormat
    var history = UsageHistory()
    let compact: Bool
    let openPage: () -> Void

    private var hue: Color {
        switch provider {
        case .codex: return SpleenStyle.accent
        case .claude: return SpleenStyle.claude
        case .antigravity: return .indigo
        }
    }
    @ViewBuilder private var mark: some View {
        switch provider {
        case .codex: ProviderMark(provider: .codex, size: 26)
        case .claude: ProviderMark(provider: .claude, size: 26)
        case .antigravity:
            Text("agy")
                .font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(hue)
                .frame(width: 26, height: 26)
                .background(hue.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)
        }
    }
    /// A row read during this opening is a fresh row.
    private func markFresh(_ reading: UsageReading) {
        if let openedAt, reading.checkedAt >= openedAt { UsageDisplayMarker.mark("usage.\(provider.rawValue).row") }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 14) {
            HStack(spacing: 10) {
                mark
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.displayName).font(.system(size: 13, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text(UsageText.status(status, provider: provider, retryAfter: state.retryAfter, now: now, format: format))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if state.inFlight { ProgressView().controlSize(.small).accessibilityLabel("Checking \(provider.displayName)") }
                Button(action: openPage) { Image(systemName: "arrow.up.right.square") }
                    .buttonStyle(.borderless)
                    .help("Open \(provider.detailsLabel)")
                    .accessibilityLabel("Open \(provider.detailsLabel)")
            }
            if let reading = state.reading {
                VStack(alignment: .leading, spacing: compact ? 7 : 14) {
                    ForEach(reading.windows) { window in
                        UsageWindowRow(provider: provider, window: window, hue: hue, now: now, format: format,
                                       trend: history.trend(for: window), compact: compact)
                    }
                }
                .onAppear { markFresh(reading) }
                .onChange(of: reading.checkedAt) { _ in markFresh(reading) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct UsageWindowRow: View {
    let provider: UsageProvider
    let window: UsageWindow
    let hue: Color
    let now: Date
    let format: UsageTimeFormat
    var trend: UsageTrend?
    let compact: Bool

    var body: some View {
        let expired = window.isExpired(at: now)
        let plot = expired ? nil : trend.flatMap { UsageTrendPlot(trend: $0, now: now) }
        VStack(alignment: .leading, spacing: compact ? 2 : 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.label).font(.system(size: 13, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if compact, let plot {
                    UsageTrendChart(plot: plot, tint: hue, now: now, format: format).frame(width: 44, height: 14)
                }
                Text(expired ? "was \(window.percentLeft)% left" : "\(window.percentLeft)% left")
                    .font(.system(size: expired ? 12 : 13, weight: expired ? .regular : .semibold)).monospacedDigit().fixedSize()
            }
            UsageMeter(fraction: Double(window.percentLeft) / 100, tint: expired ? Color.secondary : hue)
            if !compact, let plot {
                UsageTrendChart(plot: plot, tint: hue, now: now, format: format).frame(height: 32)
            }
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

/// The share left since the period began, as a quiet line under the meter. The dashed line
/// is an even pace from all of it at the start to none at the reset; above it is slower.
struct UsageTrendChart: View {
    let plot: UsageTrendPlot
    let tint: Color
    let now: Date
    let format: UsageTimeFormat

    private static let inset: CGFloat = 3
    private func point(_ spot: UsageTrendPlot.Spot, in size: CGSize) -> CGPoint {
        CGPoint(x: spot.x * size.width,
                y: Self.inset + (1 - spot.y) * (size.height - Self.inset * 2))
    }
    private var caption: String {
        "Share left since \(format.reset(plot.start, now: now))" + (plot.hasPace ? " · the dashed line is an even pace to the reset" : "")
    }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let spots = plot.line.map { point($0, in: size) }
            let floor = size.height - Self.inset
            ZStack {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: floor)); path.addLine(to: CGPoint(x: size.width, y: floor))
                }
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                if plot.hasPace {
                    Path { path in
                        path.move(to: point(.init(x: 0, y: 1), in: size)); path.addLine(to: point(.init(x: 1, y: 0), in: size))
                    }
                    .stroke(Color.primary.opacity(0.22), style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [2, 4]))
                }
                if let first = spots.first, let last = spots.last {
                    Path { path in
                        path.move(to: CGPoint(x: first.x, y: floor))
                        for spot in spots { path.addLine(to: spot) }
                        path.addLine(to: CGPoint(x: last.x, y: floor)); path.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [tint.opacity(0.2), tint.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    Path { path in
                        path.move(to: first)
                        for spot in spots.dropFirst() { path.addLine(to: spot) }
                    }
                    .stroke(tint.opacity(0.9), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    Circle().fill(tint).frame(width: 5, height: 5).position(last)
                }
            }
        }
        .help(caption)
        .accessibilityHidden(true)
    }
}

enum UsageText {
    static func reason(_ failure: UsageFailure, provider: UsageProvider) -> String {
        switch failure {
        case .missingClient: return provider == .codex ? "Codex app not found" : "\(provider.clientName) not found"
        case .signedOut: return "Signed out of \(provider.clientName)"
        case .noSubscriptionLimits: return "No subscription limits for this sign-in"
        case .offlineOrEmpty: return "No limit data returned · check your connection"
        case .timeout: return "Timed out"
        case .incompatible: return provider == .codex ? "This Codex version isn’t supported" : "Update \(provider.clientName) to show limits"
        case .accountChanged: return "Account changed · refresh to check"
        case .cancelled: return "Stopped"
        }
    }

    static func status(_ status: UsageLimitsModel.Status, provider: UsageProvider, retryAfter: Date?, now: Date,
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
    static func spoken(_ window: UsageWindow, provider: UsageProvider, now: Date, format: UsageTimeFormat) -> String {
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
