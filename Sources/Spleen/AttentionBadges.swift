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
            Text("Working…").font(.system(size: 10.5, weight: .medium))
        }
        .foregroundStyle(.primary)
        .frame(height: 20)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Working")
        .help("Working")
    }
}

/// Draw the blink natively so it does not depend on SwiftUI animation playback
/// in a nonactivating panel. Removing the dot also stops its timer.
private struct BlinkingWorkingDot: NSViewRepresentable {
    func makeNSView(context: Context) -> ActivityDotView { ActivityDotView() }
    func updateNSView(_ view: ActivityDotView, context: Context) {}
    static func dismantleNSView(_ view: ActivityDotView, coordinator: ()) { view.stop() }

    final class ActivityDotView: NSView {
        private var bright = true
        private var timer: Timer?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            bright = true
            needsDisplay = true
            let clock = Timer(timeInterval: 0.65, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.bright.toggle()
                self.needsDisplay = true
            }
            timer = clock
            RunLoop.main.add(clock, forMode: .common)
        }

        override func draw(_ dirtyRect: NSRect) {
            NSColor.labelColor.withAlphaComponent(bright ? 1 : 0.15).setFill()
            NSBezierPath(ovalIn: bounds).fill()
        }

        func stop() { timer?.invalidate(); timer = nil }
        deinit { timer?.invalidate() }
    }
}
