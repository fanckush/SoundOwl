import AppKit

/// The menu bar owl: a template silhouette of `OwlMark` (ears, face discs, beak), so it takes the
/// menu bar's colour like every other item. A dot means Live is restoring; a ring shows copies
/// being made.
enum OwlGlyph {
    struct State: Equatable {
        var isLive = false
        /// 0...1 while files restore.
        var progress: Double?
    }

    static func image(_ state: State) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let scale = state.progress == nil ? 0.17 : 0.13
            let inset = (18 - 100 * scale) / 2
            context.saveGState()
            context.translateBy(x: inset, y: inset + (state.progress == nil ? 0.5 : 0))
            context.scaleBy(x: scale, y: scale)
            drawOwl(in: context)
            context.restoreGState()

            if let progress = state.progress {
                drawRing(progress, in: context)
            }
            if state.isLive {
                // Cut a gap around the dot so it reads on top of the owl.
                context.setBlendMode(.clear)
                context.fillEllipse(in: CGRect(x: 11.5, y: 11.5, width: 7, height: 7))
                context.setBlendMode(.normal)
                context.setFillColor(NSColor.black.cgColor)
                context.fillEllipse(in: CGRect(x: 12.75, y: 12.75, width: 4.5, height: 4.5))
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    /// `OwlMark`'s silhouette in its 100-point space, with the face cut out.
    private static func drawOwl(in context: CGContext) {
        let body = CGMutablePath()
        body.move(to: CGPoint(x: 18, y: 8))
        body.addLine(to: CGPoint(x: 36, y: 22))
        body.addQuadCurve(to: CGPoint(x: 64, y: 22), control: CGPoint(x: 50, y: 17))
        body.addLine(to: CGPoint(x: 82, y: 8))
        body.addCurve(to: CGPoint(x: 86, y: 62), control1: CGPoint(x: 86, y: 26), control2: CGPoint(x: 90, y: 44))
        body.addCurve(to: CGPoint(x: 50, y: 96), control1: CGPoint(x: 82, y: 84), control2: CGPoint(x: 68, y: 96))
        body.addCurve(to: CGPoint(x: 14, y: 62), control1: CGPoint(x: 32, y: 96), control2: CGPoint(x: 18, y: 84))
        body.addCurve(to: CGPoint(x: 18, y: 8), control1: CGPoint(x: 10, y: 44), control2: CGPoint(x: 14, y: 26))
        body.closeSubpath()
        context.setFillColor(NSColor.black.cgColor)
        context.addPath(body)
        context.fillPath()

        // Eyes: discs cut out, pupils put back.
        context.setBlendMode(.clear)
        for x in [33.0, 67.0] {
            context.fillEllipse(in: CGRect(x: x - 14, y: 28, width: 28, height: 28))
        }
        context.setBlendMode(.normal)
        for x in [33.0, 67.0] {
            context.fillEllipse(in: CGRect(x: x - 7, y: 35, width: 14, height: 14))
        }
    }

    private static func drawRing(_ progress: Double, in context: CGContext) {
        let center = CGPoint(x: 9, y: 9)
        context.setStrokeColor(NSColor.black.withAlphaComponent(0.3).cgColor)
        context.setLineWidth(1.5)
        context.addEllipse(in: CGRect(x: 1, y: 1, width: 16, height: 16))
        context.strokePath()
        context.setStrokeColor(NSColor.black.cgColor)
        context.setLineCap(.round)
        let start = -CGFloat.pi / 2
        context.addArc(center: center, radius: 8, startAngle: start,
                       endAngle: start + 2 * .pi * max(0.04, progress), clockwise: false)
        context.strokePath()
    }
}
