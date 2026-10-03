#if os(iOS)
    import SwiftUI

    struct IOSDieterActivityGlyph: View {
        let size: CGFloat
        var tint: Color = .accentColor
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var rotation = Angle.zero
        @State private var breathing = false

        var body: some View {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.16))
                    .frame(width: size * 1.18, height: size * 1.18)
                    .blur(radius: size * 0.17)
                    .scaleEffect(breathing ? 1.08 : 0.92)
                Circle()
                    .stroke(tint.opacity(0.14), lineWidth: max(1, size * 0.025))
                    .frame(width: size, height: size)
                Circle()
                    .trim(from: 0.08, to: 0.73)
                    .stroke(
                        AngularGradient(
                            colors: [.clear, tint.opacity(0.35), tint, .clear],
                            center: .center),
                        style: StrokeStyle(lineWidth: max(2, size * 0.055), lineCap: .round)
                    )
                    .frame(width: size, height: size)
                    .rotationEffect(rotation)
                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: size * 0.7, height: size * 0.7)
                    .overlay(Circle().stroke(.white.opacity(0.22), lineWidth: 0.75))
                IOSDieterMark()
                    .frame(width: size * 0.52, height: size * 0.52)
                    .scaleEffect(breathing ? 1.04 : 0.94)
                    .rotationEffect(breathing ? .degrees(2) : .degrees(-2))
                    .shadow(color: tint.opacity(0.22), radius: size * 0.06, y: size * 0.02)
            }
            .frame(width: size * 1.25, height: size * 1.25)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.7).repeatForever(autoreverses: false)) {
                    rotation = .degrees(360)
                }
                withAnimation(.easeInOut(duration: 1.15).repeatForever(autoreverses: true)) {
                    breathing = true
                }
            }
            .accessibilityHidden(true)
        }
    }

    struct IOSDieterMark: View {
        var body: some View {
            Canvas { context, size in
                let scale = min(size.width, size.height) / 1_024
                context.translateBy(
                    x: (size.width - 1_024 * scale) / 2,
                    y: (size.height - 1_024 * scale) / 2)
                context.scaleBy(x: scale, y: scale)

                context.fill(
                    shell,
                    with: .linearGradient(
                        Gradient(colors: [
                            Color(red: 0.55, green: 0.85, blue: 0.91),
                            Color(red: 0.24, green: 0.43, blue: 0.52),
                            Color(red: 0.20, green: 0.35, blue: 0.43),
                        ]),
                        startPoint: CGPoint(x: 190, y: 160),
                        endPoint: CGPoint(x: 862, y: 912)))
                context.fill(operatorBody, with: .color(Color(red: 0.05, green: 0.11, blue: 0.14)))
                context.fill(
                    panes,
                    with: .linearGradient(
                        Gradient(colors: [
                            Color(red: 0.84, green: 0.95, blue: 0.96),
                            Color(red: 0.55, green: 0.85, blue: 0.91),
                            Color(red: 0.38, green: 0.71, blue: 0.80),
                        ]),
                        startPoint: CGPoint(x: 250, y: 220),
                        endPoint: CGPoint(x: 730, y: 850)))
                context.fill(eyes, with: .color(Color(red: 0.74, green: 0.92, blue: 0.95)))
            }
            .accessibilityHidden(true)
        }

        private var shell: Path {
            var path = Path()
            path.move(to: CGPoint(x: 742, y: 104))
            path.addLine(to: CGPoint(x: 862, y: 104))
            path.addLine(to: CGPoint(x: 862, y: 686))
            path.addCurve(
                to: CGPoint(x: 630, y: 918),
                control1: CGPoint(x: 862, y: 814),
                control2: CGPoint(x: 758, y: 918))
            path.addLine(to: CGPoint(x: 394, y: 918))
            path.addCurve(
                to: CGPoint(x: 162, y: 686),
                control1: CGPoint(x: 266, y: 918),
                control2: CGPoint(x: 162, y: 814))
            path.addLine(to: CGPoint(x: 162, y: 493))
            path.addCurve(
                to: CGPoint(x: 512, y: 143),
                control1: CGPoint(x: 162, y: 300),
                control2: CGPoint(x: 319, y: 143))
            path.addCurve(
                to: CGPoint(x: 742, y: 226),
                control1: CGPoint(x: 599, y: 143),
                control2: CGPoint(x: 679, y: 175))
            path.closeSubpath()
            return path
        }

        private var operatorBody: Path {
            var path = Path()
            path.move(to: CGPoint(x: 512, y: 342))
            path.addCurve(
                to: CGPoint(x: 288, y: 534),
                control1: CGPoint(x: 374, y: 342),
                control2: CGPoint(x: 288, y: 425))
            path.addCurve(
                to: CGPoint(x: 394, y: 688),
                control1: CGPoint(x: 288, y: 603),
                control2: CGPoint(x: 326, y: 650))
            path.addLine(to: CGPoint(x: 394, y: 786))
            path.addCurve(
                to: CGPoint(x: 495, y: 887),
                control1: CGPoint(x: 394, y: 842),
                control2: CGPoint(x: 439, y: 887))
            path.addLine(to: CGPoint(x: 529, y: 887))
            path.addCurve(
                to: CGPoint(x: 630, y: 786),
                control1: CGPoint(x: 585, y: 887),
                control2: CGPoint(x: 630, y: 842))
            path.addLine(to: CGPoint(x: 630, y: 688))
            path.addCurve(
                to: CGPoint(x: 736, y: 534),
                control1: CGPoint(x: 698, y: 650),
                control2: CGPoint(x: 736, y: 603))
            path.addCurve(
                to: CGPoint(x: 512, y: 342),
                control1: CGPoint(x: 736, y: 425),
                control2: CGPoint(x: 650, y: 342))
            path.closeSubpath()
            return path
        }

        private var panes: Path {
            var path = Path(
                roundedRect: CGRect(x: 412, y: 224, width: 200, height: 142),
                cornerSize: CGSize(width: 36, height: 36))
            path.addPath(sidePane(mirrored: false))
            path.addPath(sidePane(mirrored: true))
            return path
        }

        private func sidePane(mirrored: Bool) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: 218, y: 668))
            path.addCurve(
                to: CGPoint(x: 277, y: 622),
                control1: CGPoint(x: 218, y: 636),
                control2: CGPoint(x: 246, y: 614))
            path.addLine(to: CGPoint(x: 370, y: 647))
            path.addCurve(
                to: CGPoint(x: 418, y: 710),
                control1: CGPoint(x: 398, y: 655),
                control2: CGPoint(x: 418, y: 680))
            path.addLine(to: CGPoint(x: 418, y: 817))
            path.addCurve(
                to: CGPoint(x: 361, y: 864),
                control1: CGPoint(x: 418, y: 847),
                control2: CGPoint(x: 390, y: 870))
            path.addLine(to: CGPoint(x: 275, y: 847))
            path.addCurve(
                to: CGPoint(x: 218, y: 778),
                control1: CGPoint(x: 242, y: 840),
                control2: CGPoint(x: 218, y: 811))
            path.closeSubpath()
            guard mirrored else { return path }
            return path.applying(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 1_024, ty: 0))
        }

        private var eyes: Path {
            var path = Path(
                roundedRect: CGRect(x: 376, y: 516, width: 88, height: 36),
                cornerSize: CGSize(width: 18, height: 18))
            path.addRoundedRect(
                in: CGRect(x: 560, y: 516, width: 88, height: 36),
                cornerSize: CGSize(width: 18, height: 18))
            return path
        }
    }
#endif
