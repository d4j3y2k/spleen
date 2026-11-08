import AppKit

/// One scalable contour for the gradient identity, menu-bar template and app icon.
/// Coordinates are top-down; the shape follows the approved rounded logo study.
enum SpleenLogo {
    static let aspectRatio: CGFloat = 666 / 921

    static func path(in rect: CGRect) -> CGPath {
        let height = min(rect.height, rect.width / aspectRatio)
        let width = height * aspectRatio
        var transform = CGAffineTransform(a: width, b: 0, c: 0, d: height,
                                          tx: rect.midX - width / 2, ty: rect.midY - height / 2)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0.354, y: 0))
        path.addCurve(to: CGPoint(x: 0.920, y: 0.223),
                      control1: CGPoint(x: 0.590, y: 0), control2: CGPoint(x: 0.824, y: 0.080))
        path.addCurve(to: CGPoint(x: 0.915, y: 0.776),
                      control1: CGPoint(x: 1.025, y: 0.375), control2: CGPoint(x: 1.030, y: 0.606))
        path.addCurve(to: CGPoint(x: 0.530, y: 0.999),
                      control1: CGPoint(x: 0.818, y: 0.922), control2: CGPoint(x: 0.688, y: 1.011))
        path.addCurve(to: CGPoint(x: 0.271, y: 0.757),
                      control1: CGPoint(x: 0.380, y: 0.990), control2: CGPoint(x: 0.287, y: 0.893))
        path.addCurve(to: CGPoint(x: 0.113, y: 0.393),
                      control1: CGPoint(x: 0.250, y: 0.583), control2: CGPoint(x: 0.230, y: 0.525))
        path.addCurve(to: CGPoint(x: 0.004, y: 0.177),
                      control1: CGPoint(x: 0.021, y: 0.287), control2: CGPoint(x: -0.020, y: 0.254))
        path.addCurve(to: CGPoint(x: 0.354, y: 0),
                      control1: CGPoint(x: 0.031, y: 0.080), control2: CGPoint(x: 0.184, y: 0))
        path.closeSubpath()
        return path.copy(using: &transform)!
    }

    static let image: NSImage = makeImage(size: NSSize(width: 18, height: 24), template: false)
    static let menuBarImage: NSImage = makeImage(size: NSSize(width: 18, height: 18), template: true)

    private static func makeImage(size: NSSize, template: Bool) -> NSImage {
        let image = NSImage(size: size, flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            draw(in: template ? rect.insetBy(dx: 1, dy: 1) : rect, context: context, monochrome: template)
            return true
        }
        image.isTemplate = template
        image.accessibilityDescription = "Spleen"
        return image
    }

    /// Rose and burgundy beneath a glossy candy shell. Reflections scale with the
    /// contour, while the menu-bar template stays a clear monochrome silhouette.
    static func draw(in rect: CGRect, context: CGContext, monochrome: Bool = false) {
        context.saveGState()
        defer { context.restoreGState() }
        let silhouette = path(in: rect)
        context.addPath(silhouette)
        if monochrome {
            context.setFillColor(NSColor.black.cgColor)
            context.fillPath()
            return
        }
        context.clip()
        let bounds = silhouette.boundingBoxOfPath
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: bounds.minX + bounds.width * x, y: bounds.minY + bounds.height * y)
        }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let base = CGGradient(colorsSpace: space,
                              colors: [color(0xD77795), color(0xA43F59), color(0x87334F)] as CFArray,
                              locations: [0, 0.60, 1])!
        context.drawLinearGradient(base, start: point(0.05, 0.12), end: point(0.95, 0.90),
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        func bloom(_ hex: UInt32, alpha: CGFloat, x: CGFloat, y: CGFloat, radius: CGFloat) {
            let gradient = CGGradient(colorsSpace: space,
                colors: [color(hex, alpha: alpha), color(hex, alpha: alpha * 0.5), color(hex, alpha: 0)] as CFArray,
                locations: [0, 0.45, 1])!
            context.drawRadialGradient(gradient, startCenter: point(x, y), startRadius: 0,
                                       endCenter: point(x, y), endRadius: bounds.height * radius,
                                       options: [])
        }
        bloom(0xF2B5C6, alpha: 0.70, x: 0.18, y: 0.16, radius: 0.40)
        bloom(0xD77697, alpha: 0.68, x: 0.42, y: 0.49, radius: 0.40)
        bloom(0x541B37, alpha: 0.60, x: 0.88, y: 0.66, radius: 0.37)
        bloom(0x5D2345, alpha: 0.52, x: 0.49, y: 0.91, radius: 0.25)
        bloom(0xE7A0AE, alpha: 0.43, x: 0.79, y: 0.94, radius: 0.23)

        // A curved softbox reflection gives the sugar coating its wet shine.
        // Its broad upper area remains visible even in the small header mark.
        let reflection = CGMutablePath()
        reflection.move(to: point(0.139, 0.151))
        reflection.addCurve(to: point(0.351, 0.047),
                            control1: point(0.178, 0.070), control2: point(0.264, 0.040))
        reflection.addCurve(to: point(0.426, 0.077),
                            control1: point(0.398, 0.047), control2: point(0.450, 0.057))
        reflection.addCurve(to: point(0.283, 0.151),
                            control1: point(0.402, 0.101), control2: point(0.331, 0.107))
        reflection.addCurve(to: point(0.172, 0.287),
                            control1: point(0.222, 0.206), control2: point(0.204, 0.267))
        reflection.addCurve(to: point(0.139, 0.151),
                            control1: point(0.127, 0.315), control2: point(0.100, 0.231))
        reflection.closeSubpath()
        context.saveGState()
        context.setShadow(offset: .zero, blur: bounds.height * 0.014,
                          color: color(0xFFE8F1, alpha: 0.35))
        context.setFillColor(color(0xFFE8F1, alpha: 0.12))
        context.addPath(reflection)
        context.fillPath()
        context.restoreGState()
        context.saveGState()
        context.addPath(reflection)
        context.clip()
        let shine = CGGradient(colorsSpace: space,
            colors: [color(0xFFF8FB, alpha: 0.96), color(0xFFE8F1, alpha: 0.68), color(0xFFE8F1, alpha: 0)] as CFArray,
            locations: [0, 0.30, 1])!
        context.drawLinearGradient(shine, start: point(0.24, 0.055), end: point(0.19, 0.30),
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        context.restoreGState()

        // A fine reflected edge on the opposite side rounds the clear coating.
        let rim = CGMutablePath()
        rim.move(to: point(0.773, 0.171))
        rim.addCurve(to: point(0.951, 0.456),
                     control1: point(0.902, 0.251), control2: point(0.948, 0.346))
        context.saveGState()
        context.setLineCap(.round)
        context.setLineWidth(bounds.height * 0.006)
        context.setStrokeColor(color(0xFFD8E9, alpha: 0.45))
        context.setShadow(offset: .zero, blur: bounds.height * 0.012,
                          color: color(0xF1ACC6, alpha: 0.60))
        context.addPath(rim)
        context.strokePath()
        context.restoreGState()
    }

    static func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
                green: CGFloat((hex >> 8) & 255) / 255,
                blue: CGFloat(hex & 255) / 255, alpha: alpha)
    }
}
