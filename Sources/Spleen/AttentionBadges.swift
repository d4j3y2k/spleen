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
                WorkingBadge()
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

/// An opaque status pill stays readable over both glass and a candy selection.
/// Text and the persistent stripe make working recognizable without animation.
struct WorkingBadge: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(spacing: 5) {
            if reduceMotion {
                Image(systemName: "gearshape.fill").font(.system(size: 10))
                    .frame(width: 12, height: 12)
            } else {
                ProgressView().controlSize(.mini).tint(SpleenStyle.working)
                    .frame(width: 12, height: 12)
            }
            Text("Working").font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(SpleenStyle.working)
        .padding(.horizontal, 7).frame(height: 20)
        .background(SpleenStyle.workingSurface, in: Capsule())
        .overlay(Capsule().strokeBorder(SpleenStyle.working.opacity(contrast == .increased ? 1 : 0.35), lineWidth: 1))
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Working")
        .help("Working")
    }
}

extension View {
    /// Uses the same fresh runtime state as the badge; selection keeps its own color.
    func workingAccent(_ active: Bool, compact: Bool = false) -> some View {
        overlay(alignment: .leading) {
            if active {
                Capsule().fill(SpleenStyle.working)
                    .frame(width: 3)
                    .padding(.vertical, compact ? 12 : 18)
                    .padding(.leading, compact ? 3 : 5)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}
