import SwiftUI

/// The app's logo mark, drawn from the same paths as docs/logo.svg (a 256×256 box).
struct LogoMark: View {
    var body: some View {
        Canvas { ctx, size in
            let scale = min(size.width, size.height) / 256
            ctx.translateBy(x: (size.width - 256 * scale) / 2, y: (size.height - 256 * scale) / 2)
            ctx.scaleBy(x: scale, y: scale)
            ctx.fill(Self.right, with: .color(Color(red: 0xC6 / 255, green: 0x4B / 255, blue: 0x36 / 255)))
            ctx.fill(Self.left, with: .color(Color(red: 0xED / 255, green: 0x69 / 255, blue: 0x47 / 255)))
            // Holes punched through both shapes.
            ctx.blendMode = .destinationOut
            for (x, y) in [(66.0, 65.0), (189.0, 65.0), (138.0, 192.0)] {
                ctx.fill(Path(ellipseIn: CGRect(x: x - 8.5, y: y - 8.5, width: 17, height: 17)), with: .color(.black))
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityLabel("GitGui")
    }

    private static let right = Path { p in
        p.move(to: CGPoint(x: 214, y: 48))
        p.addQuadCurve(to: CGPoint(x: 206, y: 40), control: CGPoint(x: 214, y: 40))
        p.addLine(to: CGPoint(x: 172, y: 40))
        p.addQuadCurve(to: CGPoint(x: 164, y: 48), control: CGPoint(x: 164, y: 40))
        p.addLine(to: CGPoint(x: 164, y: 80))
        p.addQuadCurve(to: CGPoint(x: 157, y: 97), control: CGPoint(x: 164, y: 90))
        p.addLine(to: CGPoint(x: 121, y: 133))
        p.addLine(to: CGPoint(x: 156, y: 168))
        p.addLine(to: CGPoint(x: 190, y: 134))
        p.addQuadCurve(to: CGPoint(x: 214, y: 78), control: CGPoint(x: 214, y: 110))
        p.closeSubpath()
    }

    private static let left = Path { p in
        p.move(to: CGPoint(x: 41, y: 48))
        p.addQuadCurve(to: CGPoint(x: 49, y: 40), control: CGPoint(x: 41, y: 40))
        p.addLine(to: CGPoint(x: 83, y: 40))
        p.addQuadCurve(to: CGPoint(x: 91, y: 48), control: CGPoint(x: 91, y: 40))
        p.addLine(to: CGPoint(x: 91, y: 83))
        p.addQuadCurve(to: CGPoint(x: 96, y: 94), control: CGPoint(x: 91, y: 89))
        p.addLine(to: CGPoint(x: 152, y: 150))
        p.addQuadCurve(to: CGPoint(x: 163, y: 176), control: CGPoint(x: 163, y: 161))
        p.addLine(to: CGPoint(x: 163, y: 209))
        p.addQuadCurve(to: CGPoint(x: 155, y: 217), control: CGPoint(x: 163, y: 217))
        p.addLine(to: CGPoint(x: 121, y: 217))
        p.addQuadCurve(to: CGPoint(x: 113, y: 209), control: CGPoint(x: 113, y: 217))
        p.addLine(to: CGPoint(x: 113, y: 183))
        p.addQuadCurve(to: CGPoint(x: 107, y: 169), control: CGPoint(x: 113, y: 175))
        p.addLine(to: CGPoint(x: 62, y: 124))
        p.addQuadCurve(to: CGPoint(x: 41, y: 81), control: CGPoint(x: 41, y: 103))
        p.closeSubpath()
    }
}
