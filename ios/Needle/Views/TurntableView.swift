import SwiftUI

/// Live chop mode: the cover turns into a record (the art is the label). Drag around it to scratch, hold it to stop it,
/// let go and the motor brings it back up to speed. Spin it hard and it coasts; far enough and it skips through the
/// song. Same as the web player's turntable.js.
struct TurntableView: View {
    @Environment(Player.self) private var player
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let size: CGFloat

    static let secondsPerTurn = 1.8                 // 33⅓ rpm: one turn is 1.8 s of the song as you hear it
    static let playingSpeed = 360 * 33.333 / 60     // degrees per second

    @State private var angle: Double = 0
    @State private var touching = false
    @State private var coasting = false
    @State private var coastSpeed: Double = 0
    @State private var prevAngle: Double = 0
    @State private var turned: Double = 0
    @State private var sent: Double = 0
    @State private var recent: [(t: Date, turned: Double)] = []
    @State private var lastMove = Date.distantPast
    @State private var sentSpeed = 0.0
    @State private var grabs = 0
    @State private var stopped = false
    @State private var deck = 1.0           // how fast the record turns on screen (winds down on a tape stop)

    var body: some View {
        ZStack {
            record
                .rotationEffect(.degrees(angle))
            Tonearm()
                .stroke(Color(white: 0.85), style: StrokeStyle(lineWidth: max(3, size * 0.014), lineCap: .round, lineJoin: .round))
                .frame(width: size * 0.22, height: size * 0.7)
                .rotationEffect(.degrees(touching ? 5 : 3), anchor: UnitPoint(x: 0.66, y: 0.11))
                .position(x: size * 0.93, y: size * 0.29)
                .shadow(color: .black.opacity(0.5), radius: 6, y: 5)
                .allowsHitTesting(false)
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .highPriorityGesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { v in drag(v.location) }
                .onEnded { _ in letGo() }
        )
        .sensoryFeedback(.impact(weight: .light), trigger: grabs)
        .interactiveDismissDisabled(touching || coasting)
        .task { await spin() }
        .accessibilityElement()
        .accessibilityLabel("Record. Drag around it to scratch, hold it to stop it, spin it hard to skip.")
        .accessibilityIdentifier("turntable")
        // the Start/Stop button sits on top, outside the record's own touch handling
        .overlay(alignment: .bottomLeading) { deckButton }
    }

    /// The deck's Start/Stop button: tape stop (brakes the record to a halt, pitch dropping) or start.
    private var deckButton: some View {
        Button {
            stopped.toggle()
            player.tapeStop(stopped)
        } label: {
            Text(stopped ? "START" : "STOP")
                .font(.system(size: 12, weight: .heavy).width(.expanded)).tracking(1)
                .frame(minWidth: 64, minHeight: 34)
                .padding(.horizontal, 10)
                .foregroundStyle(stopped ? Color.black : Color(white: 0.92))
                .background(
                    LinearGradient(colors: stopped ? [Color(red: 1, green: 0.54, blue: 0.54), Color(red: 0.88, green: 0.33, blue: 0.33)]
                                                   : [Color(white: 0.23), Color(white: 0.14)], startPoint: .top, endPoint: .bottom),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(.white.opacity(0.12)))
                .shadow(color: .black.opacity(0.45), radius: 7, y: 6)
        }
        .buttonStyle(PressScale())
        .sensoryFeedback(.impact(weight: .medium), trigger: stopped)
        .accessibilityLabel(stopped ? "Start: spin the record back up" : "Tape stop: brake the record to a halt")
        .accessibilityIdentifier("deck-button")
    }

    private var record: some View {
        ZStack {
            Circle().fill(Color(white: 0.06))
            Canvas { ctx, sz in        // the grooves
                let c = CGPoint(x: sz.width / 2, y: sz.height / 2), r = sz.width / 2
                var radius = r * 0.97
                var k = 0
                while radius > r * 0.36 {
                    let ring = Path(ellipseIn: CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2))
                    ctx.stroke(ring, with: .color(.white.opacity(k % 9 == 0 ? 0.07 : 0.025)), lineWidth: 0.7)
                    radius -= max(1.6, r * 0.012); k += 1
                }
            }
            // light catching the grooves
            Circle().fill(AngularGradient(colors: [.clear, .white.opacity(0.10), .clear, .clear, .white.opacity(0.07), .clear, .clear],
                                          center: .center))
            ArtworkView(track: player.current, size: size * 0.34, corner: size * 0.17)
                .clipShape(Circle())
                .overlay(Circle().stroke(.black.opacity(0.6), lineWidth: 3))
            Circle()
                .fill(RadialGradient(colors: [Color(white: 0.85), Color(white: 0.45), Color(white: 0.25)], center: .init(x: 0.4, y: 0.35),
                                     startRadius: 0, endRadius: 5))
                .frame(width: 8, height: 8)
        }
        .frame(width: size * 0.94, height: size * 0.94)
        .shadow(color: .black.opacity(0.55), radius: 20, y: 14)
    }

    private func angleAt(_ p: CGPoint) -> Double { atan2(Double(p.y - size / 2), Double(p.x - size / 2)) * 180 / .pi }
    private func wrap(_ d: Double) -> Double { d > 180 ? d - 360 : d < -180 ? d + 360 : d }

    private func drag(_ p: CGPoint) {
        let a = angleAt(p)
        if !touching {
            touching = true; coasting = false
            prevAngle = a; turned = 0; sent = 0; sentSpeed = 0; lastMove = .distantPast; recent = [(Date(), 0)]
            grabs += 1
            stopped = false
            player.scratchDown()
            return
        }
        let d = wrap(a - prevAngle)
        prevAngle = a; turned += d; angle += d
        let now = Date()
        recent.append((now, turned))
        while recent.count > 2, now.timeIntervalSince(recent[0].t) > 0.09 { recent.removeFirst() }
        lastMove = now
        sendIfChanged()
    }

    /// How fast the record is turning right now, in playing speeds (1 = normal, 0 = still, negative = backwards).
    private var handSpeed: Double {
        let perSpeed = 360 / Self.secondsPerTurn               // degrees per second at normal speed
        if coasting { return coastSpeed / perSpeed }
        let now = Date()
        if now.timeIntervalSince(lastMove) > 0.045 { return 0 }  // finger resting on the record: it's stopped
        let r = recent.filter { now.timeIntervalSince($0.t) <= 0.05 }
        guard let a = r.first, let b = r.last, b.t > a.t else { return sentSpeed }
        return (b.turned - a.turned) / b.t.timeIntervalSince(a.t) / perSpeed
    }

    private func sendIfChanged() {
        let sp = handSpeed
        if turned != sent || abs(sp - sentSpeed) > 0.01 {
            sent = turned; sentSpeed = sp
            player.scratchMove(turned / 360 * Self.secondsPerTurn, speed: sp)
        }
    }

    private func letGo() {
        guard touching else { return }
        touching = false
        if let a = recent.first, let b = recent.last, b.t > a.t {
            let speed = (b.turned - a.turned) / b.t.timeIntervalSince(a.t)
            if abs(speed) > Self.playingSpeed * 2.5 { coasting = true; coastSpeed = speed; return }   // a fling: let it coast
        }
        player.scratchUp()
    }

    /// Keeps the record turning: with the music, or coasting after a fling (slowing under its own weight).
    private func spin() async {
        var last = Date()
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(16))
            let now = Date(), dt = min(0.05, now.timeIntervalSince(last))
            last = now
            if touching { sendIfChanged() }                      // keeps the speed current (0 when your finger rests)
            if coasting {
                coastSpeed *= exp(-dt / 0.7)
                let d = coastSpeed * dt
                turned += d; angle += d
                sendIfChanged()
                if abs(coastSpeed) < Self.playingSpeed * 1.2 { coasting = false; player.scratchUp() }
            } else if !touching, player.isPlaying, !reduceMotion {
                // spinning along with the music (winding down on a tape stop, spinning back up on start, like the sound)
                if stopped != ScrewSettings.shared.stopped, !touching { stopped = ScrewSettings.shared.stopped }
                deck = stopped ? max(0, deck - dt / 0.75) : deck + (1 - deck) * (1 - exp(-dt / 0.06))
                angle += Self.playingSpeed * Double(player.screwSpeed.rate) * deck * dt
            }
            if abs(angle) > 36000 { angle = angle.truncatingRemainder(dividingBy: 360) }
        }
    }
}

/// The tonearm: pivot at the top, arm down to the headshell.
private struct Tonearm: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let pivot = CGPoint(x: r.width * 0.66, y: r.height * 0.11)
        p.addEllipse(in: CGRect(x: pivot.x - r.width * 0.2, y: pivot.y - r.width * 0.2, width: r.width * 0.4, height: r.width * 0.4))
        p.move(to: pivot)
        p.addLine(to: CGPoint(x: r.width * 0.6, y: r.height * 0.75))
        p.addLine(to: CGPoint(x: r.width * 0.3, y: r.height * 0.89))
        p.addRoundedRect(in: CGRect(x: r.width * 0.12, y: r.height * 0.85, width: r.width * 0.34, height: r.height * 0.12),
                         cornerSize: CGSize(width: 3, height: 3))
        return p
    }
}
