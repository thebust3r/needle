import SwiftUI

/// The big picture on Now Playing, drawn the way your look says: the cover, a spinning record, a CD, or a cassette.
struct NowPlayingArt: View {
    @Environment(Player.self) private var player
    let size: CGFloat

    var body: some View {
        switch Look.shared.style.nowPlaying {
        case .art, .visualizer:
            ArtworkView(track: player.current, size: size, corner: 16)
        case .vinyl:
            VinylArt(track: player.current, size: size, playing: player.isPlaying)
        case .cd:
            CDArt(track: player.current, size: size, playing: player.isPlaying)
        case .cassette:
            CassetteArt(track: player.current, size: size, playing: player.isPlaying, progress: player.progress)
        }
    }
}

/// Keeps a spinning thing's angle smooth: it carries on from where it stopped instead of jumping.
struct Spin {
    private var base: Double = 0
    private var since: Date?
    let degreesPerSecond: Double

    init(degreesPerSecond: Double) { self.degreesPerSecond = degreesPerSecond }

    func angle(at date: Date) -> Double {
        guard let since else { return base }
        return (base + date.timeIntervalSince(since) * degreesPerSecond).truncatingRemainder(dividingBy: 360)
    }

    mutating func set(running: Bool, at date: Date = Date()) {
        if running {
            if since == nil { since = date }
        } else if since != nil {
            base = angle(at: date)
            since = nil
        }
    }
}

/// A record: black grooves, the cover as the label in the middle, spinning at 33⅓ while it plays.
struct VinylArt: View {
    let track: Track?
    let size: CGFloat
    let playing: Bool
    @State private var spin = Spin(degreesPerSecond: 200)

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: !playing)) { ctx in
            ZStack {
                Circle().fill(Color(white: 0.06))
                Canvas { g, s in
                    let c = CGPoint(x: s.width / 2, y: s.height / 2)
                    for i in stride(from: 0.36, through: 0.97, by: 0.022) {
                        let r = s.width / 2 * i
                        g.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                                 with: .color(.white.opacity(i.truncatingRemainder(dividingBy: 0.088) < 0.022 ? 0.07 : 0.035)), lineWidth: 1)
                    }
                }
                // the shine that stays put while the record turns under it
                Circle().fill(AngularGradient(colors: [.clear, .white.opacity(0.12), .clear, .clear, .white.opacity(0.08), .clear],
                                              center: .center))
                    .rotationEffect(.degrees(-spin.angle(at: ctx.date)))
                ArtworkView(track: track, size: size * 0.38, corner: size)
                    .clipShape(Circle())
                Circle().fill(Color(white: 0.08)).frame(width: size * 0.035, height: size * 0.035)
            }
            .frame(width: size, height: size)
            .rotationEffect(.degrees(spin.angle(at: ctx.date)))
            .shadow(color: .black.opacity(0.5), radius: 20, y: 10)
        }
        .onAppear { spin.set(running: playing) }
        .onChange(of: playing) { _, on in spin.set(running: on) }
        .accessibilityLabel("Record of \(track?.album ?? "this song")")
    }
}

/// A CD: the cover printed on the disc, a rainbow sheen, and a clear center ring.
struct CDArt: View {
    let track: Track?
    let size: CGFloat
    let playing: Bool
    @State private var spin = Spin(degreesPerSecond: 140)

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: !playing)) { ctx in
            let a = spin.angle(at: ctx.date)
            ZStack {
                Circle().fill(LinearGradient(colors: [Color(white: 0.85), Color(white: 0.55), Color(white: 0.9)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                ArtworkView(track: track, size: size * 0.96, corner: size)
                    .clipShape(Circle())
                    .rotationEffect(.degrees(a))
                // rainbow sheen: stays mostly still, like light catching the disc
                Circle()
                    .fill(AngularGradient(colors: [.red, .orange, .yellow, .green, .cyan, .blue, .purple, .pink, .red], center: .center))
                    .opacity(0.22)
                    .blendMode(.screen)
                    .rotationEffect(.degrees(-a * 0.15))
                Circle().fill(RadialGradient(colors: [.white.opacity(0.35), .clear], center: .topLeading, startRadius: 0, endRadius: size * 0.7))
                // the clear plastic hub and the hole
                Circle().fill(Color.white.opacity(0.18)).frame(width: size * 0.3, height: size * 0.3)
                    .overlay(Circle().stroke(.white.opacity(0.35), lineWidth: 1))
                Circle().fill(Color.black.opacity(0.85)).frame(width: size * 0.11, height: size * 0.11)
                    .overlay(Circle().stroke(.white.opacity(0.25), lineWidth: 1))
            }
            .frame(width: size, height: size)
            .compositingGroup()
            .shadow(color: .black.opacity(0.45), radius: 22, y: 12)
        }
        .onAppear { spin.set(running: playing) }
        .onChange(of: playing) { _, on in spin.set(running: on) }
        .accessibilityLabel("CD of \(track?.album ?? "this song")")
    }
}

/// A cassette: the cover on the label, two reels turning, tape moving from one to the other as the song plays.
struct CassetteArt: View {
    let track: Track?
    let size: CGFloat
    let playing: Bool
    let progress: Double
    @State private var spin = Spin(degreesPerSecond: 160)

    var body: some View {
        let w = size
        let h = size * 0.64
        TimelineView(.animation(minimumInterval: 1 / 60, paused: !playing)) { ctx in
            let a = spin.angle(at: ctx.date)
            ZStack {
                // the shell
                RoundedRectangle(cornerRadius: w * 0.05, style: .continuous)
                    .fill(LinearGradient(colors: [Color(white: 0.22), Color(white: 0.12)], startPoint: .top, endPoint: .bottom))
                    .overlay(RoundedRectangle(cornerRadius: w * 0.05, style: .continuous).stroke(.white.opacity(0.18), lineWidth: 1))
                VStack(spacing: h * 0.05) {
                    // label with the cover and the name
                    HStack(spacing: w * 0.03) {
                        ArtworkView(track: track, size: h * 0.3, corner: 4)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(track?.title ?? "Side A").font(.system(size: w * 0.045, weight: .bold)).lineLimit(1)
                            Text(track?.artist ?? "").font(.system(size: w * 0.035)).opacity(0.7).lineLimit(1)
                        }
                        .foregroundStyle(.black)
                        Spacer(minLength: 0)
                    }
                    .padding(w * 0.025)
                    .background(RoundedRectangle(cornerRadius: w * 0.02).fill(Color(red: 0.96, green: 0.93, blue: 0.85)))
                    .overlay(alignment: .topTrailing) {
                        Rectangle().fill(Theme.accent).frame(width: w * 0.12, height: 4).padding(w * 0.03)
                    }
                    // the window with the reels
                    ZStack {
                        Capsule().fill(Color.black.opacity(0.55)).overlay(Capsule().stroke(.white.opacity(0.15)))
                        HStack {
                            reel(tape: 1 - progress, angle: a)
                            Spacer()
                            reel(tape: progress, angle: a * 1.15)
                        }
                        .padding(.horizontal, w * 0.08)
                    }
                    .frame(height: h * 0.34)
                    .padding(.horizontal, w * 0.12)
                }
                .padding(w * 0.05)
                // screws
                ForEach(0..<4, id: \.self) { i in
                    Circle().fill(Color(white: 0.4)).frame(width: w * 0.022, height: w * 0.022)
                        .position(x: i % 2 == 0 ? w * 0.04 : w * 0.96, y: i < 2 ? h * 0.06 : h * 0.94)
                }
            }
            .frame(width: w, height: h)
            .shadow(color: .black.opacity(0.5), radius: 18, y: 10)
        }
        .frame(width: size, height: size)
        .onAppear { spin.set(running: playing) }
        .onChange(of: playing) { _, on in spin.set(running: on) }
        .accessibilityLabel("Cassette of \(track?.album ?? "this song")")
    }

    /// A reel: its tape gets fatter or thinner as the song goes.
    private func reel(tape: Double, angle: Double) -> some View {
        let d = size * 0.17
        let full = d * (1.05 + 0.75 * max(0, min(1, tape)))
        return ZStack {
            Circle().fill(Color(red: 0.25, green: 0.16, blue: 0.1)).frame(width: full, height: full)
            Circle().fill(Color.white.opacity(0.9)).frame(width: d * 0.9, height: d * 0.9)
            ForEach(0..<6, id: \.self) { i in
                Capsule().fill(Color(white: 0.25)).frame(width: d * 0.08, height: d * 0.34)
                    .offset(y: -d * 0.22)
                    .rotationEffect(.degrees(Double(i) * 60))
            }
            Circle().fill(Color(white: 0.2)).frame(width: d * 0.22, height: d * 0.22)
        }
        .rotationEffect(.degrees(angle))
        .frame(width: size * 0.32, height: size * 0.32)
    }
}
