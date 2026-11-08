import SwiftUI
import SpleenCore

/// Standalone provider glyphs; the enclosing badge owns color and background.
struct ProviderGlyph: View {
    let provider: ContextProvider
    var size: CGFloat = 14

    var body: some View {
        Group {
            if provider == .claude {
                ClaudeAsterisk().fill()
            } else {
                CodexPrompt().stroke(style: StrokeStyle(lineWidth: size * 0.11,
                                                       lineCap: .square, lineJoin: .miter))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A terminal prompt without a surrounding terminal window.
private struct CodexPrompt: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.10, y: rect.minY + rect.height * 0.23))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.37, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.10, y: rect.minY + rect.height * 0.77))
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.53, y: rect.minY + rect.height * 0.77))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.90, y: rect.minY + rect.height * 0.77))
        return path
    }
}

/// Claude's irregular asterisk, from the vector wordmark at https://claude.com/.
/// Preserve its 125 × 125 geometry instead of substituting a sun or font asterisk.
private struct ClaudeAsterisk: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 125
        return Self.outline.applying(CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
            tx: rect.midX - 62.5 * scale, ty: rect.midY - 62.5 * scale))
    }

    private static let outline: Path = {
        var path = Path()
        path.move(to: CGPoint(x: 54.375, y: 118.75))
        for point in [
            CGPoint(x: 56.125, y: 111), CGPoint(x: 58.125, y: 101),
            CGPoint(x: 59.75, y: 93), CGPoint(x: 61.25, y: 83.125), CGPoint(x: 62.125, y: 79.875),
            CGPoint(x: 62, y: 79.625), CGPoint(x: 61.375, y: 79.75), CGPoint(x: 53.875, y: 90),
            CGPoint(x: 42.5, y: 105.375), CGPoint(x: 33.5, y: 114.875), CGPoint(x: 31.375, y: 115.75),
            CGPoint(x: 27.625, y: 113.875), CGPoint(x: 28, y: 110.375), CGPoint(x: 30.125, y: 107.375),
            CGPoint(x: 42.5, y: 91.5), CGPoint(x: 50, y: 81.625), CGPoint(x: 54.875, y: 76),
            CGPoint(x: 54.75, y: 75.25), CGPoint(x: 54.5, y: 75.25), CGPoint(x: 21.5, y: 96.75),
            CGPoint(x: 15.625, y: 97.5), CGPoint(x: 13, y: 95.125), CGPoint(x: 13.375, y: 91.25),
            CGPoint(x: 14.625, y: 90), CGPoint(x: 24.5, y: 83.125), CGPoint(x: 49.125, y: 69.375),
            CGPoint(x: 49.5, y: 68.125), CGPoint(x: 49.125, y: 67.5), CGPoint(x: 47.875, y: 67.5),
            CGPoint(x: 43.75, y: 67.25), CGPoint(x: 29.75, y: 66.875), CGPoint(x: 17.625, y: 66.375),
            CGPoint(x: 5.75, y: 65.75), CGPoint(x: 2.75, y: 65.125), CGPoint(x: 0, y: 61.375),
            CGPoint(x: 0.25, y: 59.5), CGPoint(x: 2.75, y: 57.875), CGPoint(x: 6.375, y: 58.125),
            CGPoint(x: 14.25, y: 58.75), CGPoint(x: 26.125, y: 59.5), CGPoint(x: 34.75, y: 60),
            CGPoint(x: 47.5, y: 61.375), CGPoint(x: 49.5, y: 61.375), CGPoint(x: 49.75, y: 60.5),
            CGPoint(x: 49.125, y: 60), CGPoint(x: 48.625, y: 59.5), CGPoint(x: 36.25, y: 51.25),
            CGPoint(x: 23, y: 42.5), CGPoint(x: 16, y: 37.375), CGPoint(x: 12.25, y: 34.75),
            CGPoint(x: 10.375, y: 32.375), CGPoint(x: 9.625, y: 27.125), CGPoint(x: 13, y: 23.375),
            CGPoint(x: 17.625, y: 23.75), CGPoint(x: 18.75, y: 24), CGPoint(x: 23.375, y: 27.625),
            CGPoint(x: 33.25, y: 35.25), CGPoint(x: 46.25, y: 44.875), CGPoint(x: 48.125, y: 46.375),
            CGPoint(x: 49, y: 45.875), CGPoint(x: 49, y: 45.5), CGPoint(x: 48.125, y: 44.125),
            CGPoint(x: 41.125, y: 31.375), CGPoint(x: 33.625, y: 18.375), CGPoint(x: 30.25, y: 13),
            CGPoint(x: 29.375, y: 9.75)
        ] { path.addLine(to: point) }
        path.addCurve(to: CGPoint(x: 28.875, y: 6),
                      control1: CGPoint(x: 29.0417, y: 8.625),
                      control2: CGPoint(x: 28.875, y: 7.375))
        for point in [
            CGPoint(x: 32.75, y: 0.750006), CGPoint(x: 34.875, y: 0),
            CGPoint(x: 40.125, y: 0.750006), CGPoint(x: 42.25, y: 2.625), CGPoint(x: 45.5, y: 10),
            CGPoint(x: 50.625, y: 21.625), CGPoint(x: 58.75, y: 37.375), CGPoint(x: 61.125, y: 42.125),
            CGPoint(x: 62.375, y: 46.375), CGPoint(x: 62.875, y: 47.75), CGPoint(x: 63.75, y: 47.75),
            CGPoint(x: 63.75, y: 47), CGPoint(x: 64.375, y: 38), CGPoint(x: 65.625, y: 27.125),
            CGPoint(x: 66.875, y: 13.125), CGPoint(x: 67.25, y: 9.125), CGPoint(x: 69.25, y: 4.375),
            CGPoint(x: 73.125, y: 1.87501), CGPoint(x: 76.125, y: 3.25), CGPoint(x: 78.625, y: 6.875),
            CGPoint(x: 78.25, y: 9.125), CGPoint(x: 76.875, y: 18.75), CGPoint(x: 73.875, y: 33.875),
            CGPoint(x: 72, y: 44.125), CGPoint(x: 73.125, y: 44.125), CGPoint(x: 74.375, y: 42.75),
            CGPoint(x: 79.5, y: 36), CGPoint(x: 88.125, y: 25.25), CGPoint(x: 91.875, y: 21),
            CGPoint(x: 96.375, y: 16.25), CGPoint(x: 99.25, y: 14), CGPoint(x: 104.625, y: 14),
            CGPoint(x: 108.5, y: 19.875), CGPoint(x: 106.75, y: 26), CGPoint(x: 101.25, y: 33),
            CGPoint(x: 96.625, y: 38.875), CGPoint(x: 90, y: 47.75), CGPoint(x: 86, y: 54.875),
            CGPoint(x: 86.375, y: 55.375), CGPoint(x: 87.25, y: 55.375), CGPoint(x: 102.125, y: 52.125),
            CGPoint(x: 110.25, y: 50.75), CGPoint(x: 119.75, y: 49.125), CGPoint(x: 124.125, y: 51.125),
            CGPoint(x: 124.625, y: 53.125), CGPoint(x: 122.875, y: 57.375), CGPoint(x: 112.625, y: 59.875),
            CGPoint(x: 100.625, y: 62.25), CGPoint(x: 82.75, y: 66.5), CGPoint(x: 82.5, y: 66.625),
            CGPoint(x: 82.75, y: 67), CGPoint(x: 90.75, y: 67.75), CGPoint(x: 94.25, y: 68),
            CGPoint(x: 102.75, y: 68), CGPoint(x: 118.5, y: 69.125), CGPoint(x: 122.625, y: 71.875),
            CGPoint(x: 125, y: 75.125), CGPoint(x: 124.625, y: 77.75), CGPoint(x: 118.25, y: 80.875),
            CGPoint(x: 109.75, y: 78.875), CGPoint(x: 89.75, y: 74.125), CGPoint(x: 83, y: 72.5),
            CGPoint(x: 82, y: 72.5), CGPoint(x: 82, y: 73), CGPoint(x: 87.75, y: 78.625),
            CGPoint(x: 98.125, y: 88), CGPoint(x: 111.25, y: 100.125), CGPoint(x: 111.875, y: 103.125),
            CGPoint(x: 110.25, y: 105.625), CGPoint(x: 108.5, y: 105.375), CGPoint(x: 97, y: 96.625),
            CGPoint(x: 92.5, y: 92.75), CGPoint(x: 82.5, y: 84.375), CGPoint(x: 81.875, y: 84.375),
            CGPoint(x: 81.875, y: 85.25), CGPoint(x: 84.125, y: 88.625), CGPoint(x: 96.375, y: 107),
            CGPoint(x: 97, y: 112.625), CGPoint(x: 96.125, y: 114.375), CGPoint(x: 92.875, y: 115.5),
            CGPoint(x: 89.5, y: 114.875), CGPoint(x: 82.25, y: 104.875), CGPoint(x: 74.875, y: 93.5),
            CGPoint(x: 68.875, y: 83.375), CGPoint(x: 68.25, y: 83.875), CGPoint(x: 64.625, y: 121.625),
            CGPoint(x: 63, y: 123.5), CGPoint(x: 59.25, y: 125), CGPoint(x: 56.125, y: 122.625),
            CGPoint(x: 54.375, y: 118.75)
        ] { path.addLine(to: point) }
        path.closeSubpath()
        return path
    }()
}
