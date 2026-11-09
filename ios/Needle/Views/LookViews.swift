import SwiftUI

// MARK: - Backgrounds

/// What's behind every screen, drawn in the style of your look.
struct ThemeBackdrop: View {
    var body: some View {
        let s = Look.shared.style
        let accent = Theme.accent
        ZStack {
            Theme.background
            switch s.backdrop {
            case .solid:
                EmptyView()
            case .gradient:
                LinearGradient(colors: [accent.opacity(0.22), accent.opacity(0.05), .clear], startPoint: .top, endPoint: .center)
            case .albumGlow:
                AlbumGlowBackdrop()
            case .grid:
                NeonGridBackdrop(color: accent)
            case .stars:
                SparkleBackdrop(color: accent)
            case .iridescent:
                IridescentBackdrop()
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Soft blobs in the playing album's colors.
struct AlbumGlowBackdrop: View {
    var body: some View {
        let c = AccentStore.shared.albumColor ?? Theme.accent
        GeometryReader { g in
            ZStack {
                Circle().fill(c.opacity(0.32)).frame(width: g.size.width * 1.1).blur(radius: 80)
                    .offset(x: -g.size.width * 0.35, y: -g.size.height * 0.32)
                Circle().fill(c.darker(0.3).opacity(0.25)).frame(width: g.size.width * 0.9).blur(radius: 90)
                    .offset(x: g.size.width * 0.4, y: g.size.height * 0.1)
            }
            .frame(width: g.size.width, height: g.size.height)
        }
        .animation(.easeInOut(duration: 0.8), value: RGBA(c))
    }
}

/// A synthwave floor fading into the dark.
struct NeonGridBackdrop: View {
    let color: Color
    var body: some View {
        Canvas { ctx, size in
            let horizon = size.height * 0.62
            let vanishing = CGPoint(x: size.width / 2, y: horizon)
            var p = Path()
            for i in -10...10 {
                let x = size.width / 2 + CGFloat(i) * size.width * 0.16
                p.move(to: vanishing)
                p.addLine(to: CGPoint(x: x + (x - vanishing.x) * 2.2, y: size.height))
            }
            var y = horizon
            var step: CGFloat = 6
            while y < size.height {
                p.move(to: CGPoint(x: 0, y: y))
                p.addLine(to: CGPoint(x: size.width, y: y))
                y += step
                step *= 1.32
            }
            ctx.stroke(p, with: .color(color.opacity(0.16)), lineWidth: 1)
            let glow = Gradient(colors: [color.opacity(0.18), .clear])
            ctx.fill(Path(CGRect(x: 0, y: horizon - 140, width: size.width, height: 160)),
                     with: .linearGradient(glow, startPoint: CGPoint(x: 0, y: horizon), endPoint: CGPoint(x: 0, y: horizon - 140)))
        }
        .mask(LinearGradient(colors: [.clear, .black.opacity(0.9), .black], startPoint: .top, endPoint: .bottom))
    }
}

/// Little twinkles scattered across the top, Y2K style.
struct SparkleBackdrop: View {
    let color: Color
    var body: some View {
        Canvas { ctx, size in
            var rng = PatternRandom(seed: 7)
            for i in 0..<34 {
                let x = rng.next() * size.width
                let y = rng.next() * size.height * 0.75
                let big = i % 7 == 0
                let r = big ? 7.0 : 1.2 + rng.next() * 1.6
                let alpha = (big ? 0.5 : 0.22 + rng.next() * 0.3) * (1 - y / size.height)
                let shade = i % 3 == 0 ? color : Color.white
                if big {
                    var star = Path()
                    star.move(to: CGPoint(x: x, y: y - r))
                    star.addQuadCurve(to: CGPoint(x: x + r, y: y), control: CGPoint(x: x, y: y))
                    star.addQuadCurve(to: CGPoint(x: x, y: y + r), control: CGPoint(x: x, y: y))
                    star.addQuadCurve(to: CGPoint(x: x - r, y: y), control: CGPoint(x: x, y: y))
                    star.addQuadCurve(to: CGPoint(x: x, y: y - r), control: CGPoint(x: x, y: y))
                    ctx.fill(star, with: .color(shade.opacity(alpha)))
                } else {
                    ctx.fill(Path(ellipseIn: CGRect(x: x - r / 2, y: y - r / 2, width: r, height: r)), with: .color(shade.opacity(alpha)))
                }
            }
        }
        .overlay(LinearGradient(colors: [color.opacity(0.14), .clear], startPoint: .top, endPoint: .center))
    }
}

/// The rainbow sheen on the underside of a CD.
struct IridescentBackdrop: View {
    var body: some View {
        GeometryReader { g in
            AngularGradient(colors: [.pink, .purple, .blue, .cyan, .mint, .yellow, .orange, .pink], center: .topTrailing)
                .opacity(0.16)
                .blur(radius: 40)
                .frame(width: g.size.width, height: g.size.height)
        }
        .mask(LinearGradient(colors: [.black, .black.opacity(0.4), .clear], startPoint: .top, endPoint: .bottom))
    }
}

/// Same "random" numbers every time, so a pattern doesn't jump around.
struct PatternRandom {
    var state: UInt64
    init(seed: UInt64) { state = seed &* 6364136223846793005 &+ 1442695040888963407 }
    mutating func next() -> CGFloat {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return CGFloat((state >> 33) % 10_000) / 10_000
    }
}

// MARK: - Finishes (flat, glossy, glass)

/// A shape filled the way your look finishes things: flat color, glossy candy, or frosted glass.
struct FinishedShape<S: Shape>: View {
    let color: Color
    let shape: S
    var finish: LookFinish = Look.shared.style.finish
    var body: some View {
        switch finish {
        case .flat:
            shape.fill(color)
        case .glossy:
            shape.fill(LinearGradient(colors: [color.lighter(0.28), color, color.darker(0.22)], startPoint: .top, endPoint: .bottom))
                .overlay(
                    shape.fill(LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.08), .clear],
                                              startPoint: .top, endPoint: .center))
                        .padding(1.5)
                )
                .overlay(shape.stroke(.white.opacity(0.35), lineWidth: 1))
        case .glass:
            shape.fill(.ultraThinMaterial)
                .overlay(shape.fill(color.opacity(0.38)))
                .overlay(shape.stroke(LinearGradient(colors: [.white.opacity(0.45), .white.opacity(0.08)],
                                                     startPoint: .top, endPoint: .bottom), lineWidth: 1))
        }
    }
}

extension View {
    /// Puts a finished (flat / glossy / glass) shape behind this view.
    func finish<S: Shape>(_ color: Color, in shape: S, finish: LookFinish? = nil) -> some View {
        background(FinishedShape(color: color, shape: shape, finish: finish ?? Look.shared.style.finish))
    }

    /// The screen background in your look.
    func themedBackground() -> some View { background(ThemeBackdrop()) }

    /// The font family of your look (Bubbly, Serif, Typewriter...) for everything inside.
    func lookFonts() -> some View { fontDesign(Look.shared.style.font.design) }
}

/// Text that reads well on top of a color: black on light colors, white on dark ones.
func readableText(on color: Color) -> Color {
    RGBA(color).luminance > 0.55 ? .black : .white
}
