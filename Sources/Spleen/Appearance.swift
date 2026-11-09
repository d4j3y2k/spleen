import AppKit
import SwiftUI
import SpleenCore

enum SpleenStyle {
    static let managementSize = NSSize(width: 680, height: 584)
    static let accent = adaptive(light: 0xA43F59, dark: 0xE7A0AE)
    static let blush = adaptive(light: 0xDB8798, dark: 0xB75C74)
    static let claude = adaptive(light: 0xA55C3D, dark: 0xDCA081)
    static let surface = adaptive(light: 0xFFFAFB, dark: 0x352D31)
    static let line = Color.primary.opacity(0.09)
    /// Hard-candy selections keep their provider color through the body, glow,
    /// rim and soft text shadow: strawberry for Codex, orange for Claude.
    static let candy = CandyPalette(
        top: adaptive(light: 0xFFB0C5, dark: 0xD13E70),
        bottom: adaptive(light: 0xF0648D, dark: 0x8A0E3A),
        glow: adaptive(light: 0xFFE0E8, dark: 0xFF86AA),
        ink: adaptive(light: 0xFFF2F5, dark: 0x4A0620))
    static let claudeCandy = CandyPalette(
        top: adaptive(light: 0xFFC18F, dark: 0xC76C35),
        bottom: adaptive(light: 0xEC9252, dark: 0x873B17),
        glow: adaptive(light: 0xFFE5CB, dark: 0xFFB578),
        ink: adaptive(light: 0xFFF4E8, dark: 0x48200C))

    static func candy(for provider: ContextProvider) -> CandyPalette {
        provider == .claude ? claudeCandy : candy
    }
    /// Liquid Glass carries its own shadows, so the panel window draws none.
    static var usesGlass: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let rgb = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: Double((rgb >> 16) & 255) / 255,
                           green: Double((rgb >> 8) & 255) / 255,
                           blue: Double(rgb & 255) / 255, alpha: 1)
        })
    }
}

struct CandyPalette {
    let top: Color
    let bottom: Color
    let glow: Color
    let ink: Color
}

/// Set by the offscreen preview renderer. Liquid Glass is composited by the
/// window server and cannot be cached offscreen, so snapshots draw the fallback.
private struct SpleenSnapshotKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    var spleenSnapshot: Bool {
        get { self[SpleenSnapshotKey.self] }
        set { self[SpleenSnapshotKey.self] = newValue }
    }
}

/// A rounded rectangle, or a capsule when `radius` is nil, usable for glass and strokes.
struct SpleenSurfaceShape: InsettableShape {
    var radius: CGFloat?
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let frame = rect.insetBy(dx: inset, dy: inset)
        guard let radius else { return Capsule(style: .circular).path(in: frame) }
        return RoundedRectangle(cornerRadius: max(0, radius - inset), style: .continuous).path(in: frame)
    }

    func inset(by amount: CGFloat) -> SpleenSurfaceShape {
        var shape = self
        shape.inset += amount
        return shape
    }
}

/// Behind-window blur with a crisp rounded mask, for systems without Liquid Glass.
/// The mask uses the same corner curve as `SpleenSurfaceShape`, so no blur shows outside its edge.
private struct BehindWindowMaterial: NSViewRepresentable {
    var cornerRadius: CGFloat
    var continuous: Bool

    final class Coordinator { var radius: CGFloat = -1 }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        guard context.coordinator.radius != cornerRadius else { return }
        context.coordinator.radius = cornerRadius
        // A continuous corner reaches about 1.53× its radius along each edge.
        let cap = ceil(cornerRadius * (continuous ? 1.53 : 1)) + 1
        let radius = cornerRadius
        let style: RoundedCornerStyle = continuous ? .continuous : .circular
        let image = NSImage(size: NSSize(width: cap * 2 + 1, height: cap * 2 + 1), flipped: false) { rect in
            guard let graphics = NSGraphicsContext.current?.cgContext else { return false }
            graphics.setFillColor(NSColor.black.cgColor)
            graphics.addPath(RoundedRectangle(cornerRadius: radius, style: style).path(in: rect).cgPath)
            graphics.fillPath()
            return true
        }
        image.capInsets = NSEdgeInsets(top: cap, left: cap, bottom: cap, right: cap)
        image.resizingMode = .stretch
        view.maskImage = image
    }
}

enum SpleenSurfaceKind {
    /// Compass choices.
    case card
    /// The compass's selected-conversation preview.
    case preview
    /// Capsules: header chips, footer bars, the search field.
    case chrome
    /// Reading surfaces with dense text (search results, settings, the editor).
    /// A light appearance-matched tint keeps small text legible over any desktop.
    case panel
}

/// The compass's single surface language: native Liquid Glass on macOS 26,
/// a crisp behind-window material elsewhere. Each surface keeps a clean edge
/// so the desktop never ghosts through its text. A provider tint stays faint.
///
/// Selection and hover never change the glass itself: macOS animates any glass
/// change with its own lens-in zoom, which was disorienting on every arrow press.
/// Instead a separate highlight layer sits between the glass and the content,
/// and settles onto the card with a small zoom we control.
private struct SpleenSurface: ViewModifier {
    /// Scale the selection highlight starts from before settling onto the card.
    static let focusSettleScale: CGFloat = 1.015
    var kind: SpleenSurfaceKind
    var selected = false
    var hovered = false
    var tint: Color?
    var candy = SpleenStyle.candy
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.spleenSnapshot) private var snapshot

    private var shape: SpleenSurfaceShape {
        switch kind {
        case .card: return SpleenSurfaceShape(radius: 20)
        case .preview, .panel: return SpleenSurfaceShape(radius: 24)
        case .chrome: return SpleenSurfaceShape(radius: nil)
        }
    }

    /// Constant per surface, so the glass never animates on selection.
    private func wash(glass: Bool) -> Color? {
        if kind == .panel { return SpleenStyle.surface.opacity(glass ? 0.35 : 0.30) }
        return tint?.opacity(glass ? 0.10 : 0.08)
    }

    /// Hover brightening and the candy selection, above the glass and below the text.
    private func highlight(glass: Bool) -> some View {
        ZStack {
            shape.fill(Color.primary.opacity(0.06)).opacity(hovered && !selected ? 1 : 0)
            CandyHighlight(radius: shape.radius ?? 20, palette: candy)
                .scaleEffect(selected || reduceMotion ? 1 : Self.focusSettleScale)
            .opacity(selected ? 1 : 0)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder private func edge(glass: Bool) -> some View {
        if contrast == .increased && !selected {
            shape.strokeBorder(Color.primary.opacity(0.45), lineWidth: 1)
        } else if !glass && !selected {
            shape.strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
        }
    }

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *), !snapshot {
            content
                .background(highlight(glass: true))
                .glassEffect(Glass.regular.tint(wash(glass: true)), in: shape)
                .overlay(edge(glass: true).allowsHitTesting(false))
        } else {
            content
                .background(highlight(glass: false))
                .background(fallback.allowsHitTesting(false).accessibilityHidden(true))
                .overlay(edge(glass: false).allowsHitTesting(false))
        }
    }

    private var fallback: some View {
        ZStack {
            if reduceTransparency {
                shape.fill(SpleenStyle.surface)
            } else {
                GeometryReader { proxy in
                    BehindWindowMaterial(cornerRadius: shape.radius ?? min(proxy.size.width, proxy.size.height) / 2,
                                         continuous: shape.radius != nil)
                }
                shape.fill(SpleenStyle.surface.opacity(0.55))
            }
            if let wash = wash(glass: false) { shape.fill(wash) }
        }
    }
}

/// Groups the compass's glass so neighbouring surfaces share one sampling pass
/// and morph together, while staying separate at rest.
struct SpleenGlassGroup<Content: View>: View {
    var spacing: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

/// Selection drawn as glossy hard candy, like the original Aqua buttons:
/// a saturated jelly body, light pooling along the bottom, a gel highlight
/// across the top, and a rim that is bright above and deep below. It is a
/// plain layer, so the glass beneath it never changes.
struct CandyHighlight: View {
    var radius: CGFloat
    var palette = SpleenStyle.candy
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack {
            shape.fill(LinearGradient(colors: [palette.top, palette.bottom],
                                      startPoint: .top, endPoint: .bottom))
                .opacity(reduceTransparency ? 1 : 0.9)
            shape.fill(EllipticalGradient(colors: [palette.glow.opacity(0.6), .clear],
                                          center: UnitPoint(x: 0.5, y: 1), endRadiusFraction: 0.65))
            GeometryReader { proxy in
                // Capped so the gloss ends above a card's title instead of cutting through it.
                RoundedRectangle(cornerRadius: max(0, radius - 2), style: .continuous)
                    .fill(LinearGradient(colors: [.white.opacity(0.38), .white.opacity(0.04)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(height: min(proxy.size.height * 0.46, 34))
                    .padding(.horizontal, 2).padding(.top, 2)
            }
            shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.75), palette.bottom.opacity(0.95)],
                                              startPoint: .top, endPoint: .bottom), lineWidth: 1)
            if contrast == .increased {
                shape.strokeBorder(Color.primary, lineWidth: 2)
            }
        }
        .compositingGroup()
        .shadow(color: palette.bottom.opacity(0.45), radius: 10, y: 4)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Text on candy gets a soft shadow: dark in dark mode, a light emboss in light mode.
extension View {
    func candyText(_ active: Bool, palette: CandyPalette = SpleenStyle.candy) -> some View {
        shadow(color: active ? palette.ink.opacity(0.7) : .clear, radius: 1, x: 0, y: 0.75)
    }
}

/// Selection inside a glass panel. Rows are plain layers, not nested glass,
/// and use the same candy as a selected compass card.
struct SpleenRowHighlight: View {
    var selected: Bool
    var radius: CGFloat = 16
    var palette = SpleenStyle.candy

    var body: some View {
        ZStack {
            if selected { CandyHighlight(radius: radius, palette: palette) }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A quiet header for page titles and trailing controls.
struct SwitcherHeader<Trailing: View>: View {
    var title: String? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack {
            if let title {
                Text(title).font(.system(size: 13, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
            }
            Spacer()
            trailing
        }
        .padding(.horizontal, 22).frame(height: 52)
    }
}

/// Text entry inside a glass panel: a quiet tinted well rather than a bordered system field.
extension View {
    func spleenField() -> some View {
        textFieldStyle(.plain).font(.system(size: 14))
            .padding(11)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(SpleenStyle.line))
    }
}

/// The floating capsule along the bottom of every Spleen view. Trailing
/// controls sit concentric with its rounded end.
struct SpleenBar<Content: View>: View {
    var height: CGFloat = 40
    var trailingInset: CGFloat = 6
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 16) { content }
            .padding(.leading, 16).padding(.trailing, trailingInset)
            .frame(height: height)
            .spleenSurface(.chrome)
            .padding(.horizontal, 22).frame(height: 58)
    }
}

extension View {
    func spleenSurface(_ kind: SpleenSurfaceKind, selected: Bool = false, hovered: Bool = false, tint: Color? = nil,
                       candy: CandyPalette = SpleenStyle.candy) -> some View {
        modifier(SpleenSurface(kind: kind, selected: selected, hovered: hovered, tint: tint, candy: candy))
    }
}

struct KeyCap: View {
    let text: String
    var emphasized = false
    /// Sits on a candy selection: a frosted cap with full-strength text.
    var candy = false
    @Environment(\.colorSchemeContrast) private var contrast
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 6, style: .continuous) }
    private var ink: AnyShapeStyle {
        if candy { return AnyShapeStyle(Color.primary) }
        return emphasized ? AnyShapeStyle(SpleenStyle.accent) : AnyShapeStyle(.secondary)
    }
    private var fill: Color {
        if candy { return Color.white.opacity(0.28) }
        return emphasized ? SpleenStyle.accent.opacity(0.16) : Color.primary.opacity(0.07)
    }
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(ink)
            .padding(.horizontal, 6)
            .frame(minWidth: 22, minHeight: 20)
            .background(fill, in: shape)
            .overlay(shape.strokeBorder(contrast == .increased ? Color.primary.opacity(0.4) : .clear))
            .accessibilityHidden(true)
    }
}

struct KeyboardHint: View {
    let key: String
    let label: String
    var body: some View {
        HStack(spacing: 6) {
            KeyCap(text: key)
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(key): \(label)")
    }
}

/// A provider cue, not a live status indicator. Live signals retain their own badges.
struct ProviderMark: View {
    let provider: ContextProvider
    var size: CGFloat = 22
    /// Sits on a candy selection: a frosted chip with a full-strength glyph.
    var candy = false
    private var hue: Color { provider == .claude ? SpleenStyle.claude : SpleenStyle.accent }
    var body: some View {
        ProviderGlyph(provider: provider, size: size * 0.60)
            .foregroundStyle(candy ? Color.primary.opacity(0.9) : hue)
            .frame(width: size, height: size)
            .background(candy ? Color.white.opacity(0.26) : hue.opacity(0.14),
                        in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// Cards stay still when selection moves; only the highlight layer settles in
/// (see `SpleenSurface`), on a short ease-out with no overshoot.
struct ConversationButtonStyle: ButtonStyle {
    var selected: Bool
    var provider: ContextProvider
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .candyText(selected, palette: SpleenStyle.candy(for: provider))
            .spleenSurface(.card, selected: selected, hovered: hovered,
                           tint: provider == .claude ? SpleenStyle.claude : nil,
                           candy: SpleenStyle.candy(for: provider))
            .scaleEffect(reduceMotion || !configuration.isPressed ? 1 : 0.98)
            .onHover { hovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: selected)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

struct QuietIconButton: View {
    let symbol: String
    let label: String
    let action: () -> Void
    @State private var hovered = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium))
                .foregroundStyle(hovered ? .primary : .secondary)
                .frame(width: 28, height: 28)
                .background(Color.primary.opacity(hovered ? 0.08 : 0), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(label).accessibilityLabel(label)
    }
}

struct SettingsSection<Content: View>: View {
    let title: String
    var symbol: String? = nil
    var provider: ContextProvider? = nil
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label {
                Text(title)
            } icon: {
                if let provider {
                    ProviderGlyph(provider: provider, size: 13)
                } else if let symbol {
                    Image(systemName: symbol)
                }
            }
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(SpleenStyle.accent)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
