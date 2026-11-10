import SwiftUI

/// SoundOwl's owl, drawn in code so it stays sharp at every size and is the same in the app icon,
/// the empty state and onboarding. Owls hear better than almost anything; that's the whole idea.
struct OwlMark: View {
    var size: CGFloat = 96
    /// Eyes closed reads as "listening"; open is the default.
    var listening = false

    static let feathers = Color(red: 0.20, green: 0.25, blue: 0.42)
    static let featherShade = Color(red: 0.13, green: 0.16, blue: 0.29)
    static let face = Color(red: 0.95, green: 0.92, blue: 0.86)
    static let iris = Color(red: 0.98, green: 0.66, blue: 0.20)
    static let beak = Color(red: 0.93, green: 0.55, blue: 0.16)

    var body: some View {
        Canvas { context, canvas in
            let s = canvas.width / 100
            func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
                CGRect(x: x * s, y: y * s, width: w * s, height: h * s)
            }

            // Body with ear tufts, one path so the silhouette reads at 16 px.
            var body = Path()
            body.move(to: CGPoint(x: 18 * s, y: 8 * s))
            body.addLine(to: CGPoint(x: 36 * s, y: 22 * s))
            body.addQuadCurve(to: CGPoint(x: 64 * s, y: 22 * s), control: CGPoint(x: 50 * s, y: 17 * s))
            body.addLine(to: CGPoint(x: 82 * s, y: 8 * s))
            body.addCurve(
                to: CGPoint(x: 86 * s, y: 62 * s),
                control1: CGPoint(x: 86 * s, y: 26 * s),
                control2: CGPoint(x: 90 * s, y: 44 * s)
            )
            body.addCurve(
                to: CGPoint(x: 50 * s, y: 96 * s),
                control1: CGPoint(x: 82 * s, y: 84 * s),
                control2: CGPoint(x: 68 * s, y: 96 * s)
            )
            body.addCurve(
                to: CGPoint(x: 14 * s, y: 62 * s),
                control1: CGPoint(x: 32 * s, y: 96 * s),
                control2: CGPoint(x: 18 * s, y: 84 * s)
            )
            body.addCurve(
                to: CGPoint(x: 18 * s, y: 8 * s),
                control1: CGPoint(x: 10 * s, y: 44 * s),
                control2: CGPoint(x: 14 * s, y: 26 * s)
            )
            body.closeSubpath()
            context.fill(body, with: .linearGradient(Gradient(colors: [Self.feathers, Self.featherShade]),
                                                     startPoint: CGPoint(x: 50 * s, y: 8 * s),
                                                     endPoint: CGPoint(x: 50 * s, y: 96 * s)))

            // Belly feathers: three soft chevrons, like sound waves turned on their side.
            for (i, y) in [66.0, 74.0, 82.0].enumerated() {
                var chevron = Path()
                let w = 14.0 - Double(i) * 3
                chevron.move(to: CGPoint(x: (50 - w) * s, y: y * s))
                chevron.addQuadCurve(to: CGPoint(x: (50 + w) * s, y: y * s), control: CGPoint(x: 50 * s, y: (y + 5) * s))
                context.stroke(chevron, with: .color(Self.face.opacity(0.28)),
                               style: StrokeStyle(lineWidth: 2.4 * s, lineCap: .round))
            }

            // Facial discs and eyes.
            for x in [33.0, 67.0] {
                context.fill(Path(ellipseIn: rect(x - 17, 25, 34, 34)), with: .color(Self.face))
                if listening {
                    var lid = Path()
                    lid.move(to: CGPoint(x: (x - 9) * s, y: 42 * s))
                    lid.addQuadCurve(to: CGPoint(x: (x + 9) * s, y: 42 * s), control: CGPoint(x: x * s, y: 49 * s))
                    context.stroke(lid, with: .color(Self.featherShade), style: StrokeStyle(lineWidth: 3.2 * s, lineCap: .round))
                } else {
                    context.fill(Path(ellipseIn: rect(x - 11, 31, 22, 22)), with: .color(Self.iris))
                    context.fill(Path(ellipseIn: rect(x - 6, 36, 12, 12)), with: .color(Self.featherShade))
                    context.fill(Path(ellipseIn: rect(x - 4.5, 36.5, 4.5, 4.5)), with: .color(.white.opacity(0.9)))
                }
            }

            // Beak.
            var beak = Path()
            beak.move(to: CGPoint(x: 45 * s, y: 52 * s))
            beak.addLine(to: CGPoint(x: 55 * s, y: 52 * s))
            beak.addLine(to: CGPoint(x: 50 * s, y: 62 * s))
            beak.closeSubpath()
            context.fill(beak, with: .color(Self.beak))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

#Preview {
    HStack(spacing: 24) {
        OwlMark(size: 128)
        OwlMark(size: 128, listening: true)
        OwlMark(size: 32)
        OwlMark(size: 16)
    }
    .padding()
}
