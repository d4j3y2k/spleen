import AppKit
import SwiftUI
import SpleenCore

extension LiveSessionState {
    var accessibilityText: String {
        var values: [String] = isUnread == true ? ["Unread reply"] : []
        switch activity {
        case .working: values.append("Working")
        case .waitingForApproval: values.append("Needs approval")
        case .waitingForInput: values.append("Needs input")
        case .idle, nil: break
        }
        if completion != nil { values.append("Turn completed") }
        return values.joined(separator: ", ")
    }
}
struct AttentionBadges: View {
    let sample: LiveSessionState?
    var showsWorking = true
    var body: some View {
        HStack(spacing: 5) {
            if sample?.isUnread == true {
                Circle().fill(Color.blue).frame(width: 7, height: 7)
            }
            if showsWorking && sample?.activity == .working {
                WorkingStatus()
            }
            if sample?.completion != nil && sample?.activity != .working && sample?.isUnread != true {
                Image(systemName: "checkmark.circle").foregroundStyle(.secondary).font(.system(size: 12))
            }
            if sample?.activity == .waitingForApproval || sample?.activity == .waitingForInput {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange).font(.system(size: 12))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(sample?.accessibilityText ?? "")
        .help(sample?.accessibilityText ?? "")
    }
}

/// A monochrome blinking dot makes the plain status easier to spot.
struct WorkingStatus: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.spleenSnapshot) private var snapshot

    var body: some View {
        HStack(spacing: 5) {
            Group {
                if reduceMotion || snapshot {
                    Circle().fill(.primary)
                } else {
                    BlinkingWorkingDot()
                }
            }
            .frame(width: 7, height: 7)
            .frame(width: 12, height: 12)
            .accessibilityHidden(true)
            Text("Working…").font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(.primary)
        .frame(height: 20)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Working")
        .help("Working")
    }
}

/// Running blink timers, for the native self-test.
enum WorkingDotDiagnostics { static var activeTimers = 0 }

/// Draw the blink natively so it does not depend on SwiftUI animation playback
/// in a nonactivating panel. Removing the dot also stops its timer.
private struct BlinkingWorkingDot: NSViewRepresentable {
    func makeNSView(context: Context) -> ActivityDotView { ActivityDotView() }
    func updateNSView(_ view: ActivityDotView, context: Context) {}
    static func dismantleNSView(_ view: ActivityDotView, coordinator: ()) { view.stop() }

    final class ActivityDotView: NSView {
        private var bright = true
        private var timer: Timer?
        private var occlusion: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            if let occlusion { NotificationCenter.default.removeObserver(occlusion); self.occlusion = nil }
            guard let window else { return }
            // Dismissal orders the panel out without removing this view, so blink only
            // while the window is on screen; otherwise a working session wakes a hidden app.
            occlusion = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                                               object: window, queue: .main) { [weak self] _ in self?.updateBlinking() }
            updateBlinking()
        }

        private func updateBlinking() {
            guard let window, window.occlusionState.contains(.visible) else {
                stop(); bright = true; return
            }
            guard timer == nil else { return }
            bright = true
            needsDisplay = true
            let clock = Timer(timeInterval: 0.65, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.bright.toggle()
                self.needsDisplay = true
            }
            clock.tolerance = 0.05
            timer = clock
            WorkingDotDiagnostics.activeTimers += 1
            RunLoop.main.add(clock, forMode: .common)
        }

        override func draw(_ dirtyRect: NSRect) {
            NSColor.labelColor.withAlphaComponent(bright ? 1 : 0.15).setFill()
            NSBezierPath(ovalIn: bounds).fill()
        }

        func stop() {
            guard let timer else { return }
            timer.invalidate(); self.timer = nil
            WorkingDotDiagnostics.activeTimers -= 1
        }
        deinit {
            stop()
            if let occlusion { NotificationCenter.default.removeObserver(occlusion) }
        }
    }
}
