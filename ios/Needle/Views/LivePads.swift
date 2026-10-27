import SwiftUI

/// Live chops: tap a pad and it cuts back right away, in time with the song. Hold Repeat to loop the beat.
/// Pads fire on touch-down (like a drum pad), not on lift, so they feel instant.
struct LivePads: View {
    let tint: Color
    @State private var down: ChopMove?
    @State private var hits = 0
    @State private var locked = false

    private static let pads: [(ChopMove, String, String)] = [
        (.loop, "Repeat", "hold = loop"),
        (.stutter, "Stutter", "ch-ch-ch"),
        (.doubleUp, "Double", "beat ×2"),
        (.runBack, "Run back", "2 beats"),
        (.backItUp, "Back up", "a bar"),
    ]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Self.pads, id: \.0) { move, title, sub in
                pad(move, title, sub)
            }
        }
        .opacity(locked ? 1 : 0.5)
        .sensoryFeedback(.impact(weight: .medium, intensity: 0.8), trigger: hits)
        .task {
            // the audio thread updates the beat status about once a second
            while !Task.isCancelled {
                locked = ScrewSettings.shared.status.locked
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(locked ? "Live chops" : "Live chops, finding the beat")
    }

    private func pad(_ move: ChopMove, _ title: String, _ sub: String) -> some View {
        let isDown = down == move
        return VStack(spacing: 1) {
            Text(title).font(.system(size: 13, weight: .bold)).lineLimit(1).minimumScaleFactor(0.7)
            Text(sub).font(.system(size: 10)).opacity(0.6).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, minHeight: 52)
        .background(isDown ? AnyShapeStyle(tint) : AnyShapeStyle(.white.opacity(0.09)), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.white.opacity(0.08)))
        .foregroundStyle(isDown ? .black : .white)
        .scaleEffect(isDown ? 0.94 : 1)
        .animation(.spring(response: 0.18, dampingFraction: 0.7), value: isDown)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard down != move else { return }
                    down = move
                    hits += 1
                    ScrewSettings.shared.tap(move, hold: move == .loop)
                }
                .onEnded { _ in
                    if move == .loop { ScrewSettings.shared.release() }
                    down = nil
                }
        )
        .accessibilityElement()
        .accessibilityLabel(move == .loop ? "Repeat. Hold to loop" : title)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { ScrewSettings.shared.tap(move == .loop ? .repeatBeat : move) }
        .accessibilityIdentifier("pad-\(move)")
    }
}
