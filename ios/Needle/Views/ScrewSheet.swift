import SwiftUI

/// Slowed / chopped & screwed controls.
struct ScrewSheet: View {
    @Environment(Player.self) private var player
    let tint: Color

    static func label(_ s: ScrewSpeed, _ c: ChopAmount) -> String {
        switch (s, c) {
        case (.off, .off): return "Off"
        case (.off, _): return "Chopped"
        case (_, .off): return s.label
        case (.screwed, _), (.syrup, _): return "\(s.label) & Chopped"
        default: return "\(s.label) + Chops"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Chopped & Screwed").font(Theme.title(22))
                    Text("Slow it down like a record, and let it cut back on the beat.")
                        .font(.subheadline).foregroundStyle(Theme.secondary)
                }
                Spacer()
            }

            Text("SPEED").font(.caption.weight(.bold)).tracking(1).foregroundStyle(Theme.secondary)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(ScrewSpeed.allCases) { s in
                    option(s.label, s == .off ? "Normal" : "\(Int((s.rate * 100).rounded()))% · \(s.detail)", selected: player.screwSpeed == s) {
                        player.setScrew(speed: s)
                    }
                }
            }

            Text("CHOPS").font(.caption.weight(.bold)).tracking(1).foregroundStyle(Theme.secondary)
            HStack(spacing: 10) {
                ForEach(ChopAmount.allCases) { c in
                    option(c.label, c == .off ? "None" : c == .light ? "Every few bars" : "Every bar, all moves", selected: player.chops == c) {
                        player.setScrew(chops: c)
                    }
                }
            }
            if player.chops != .off {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    let st = ScrewSettings.shared.status
                    HStack(spacing: 8) {
                        Circle().fill(st.locked ? Color.green : Color.orange).frame(width: 8, height: 8)
                        Text(Self.statusText(st)).font(.footnote.weight(.semibold)).monospacedDigit()
                    }
                    .accessibilityIdentifier("screw-status")
                }
            }
            Text("Chops follow the song's beat: repeats, run-backs, stutters and back-it-ups. They start a few seconds into each song, once Needle has found the rhythm.")
                .font(.caption).foregroundStyle(Theme.tertiary)
        }
        .padding(22)
        .foregroundStyle(.white)
        .sensoryFeedback(.selection, trigger: "\(player.screwSpeed.rawValue)-\(player.chops.rawValue)")
    }

    static func statusText(_ st: ScrewStatus) -> String {
        guard st.locked else { return "Listening for the beat…" }
        var t = "Locked on beat · \(Int(st.bpm.rounded())) BPM"
        if let m = st.last { t += " · last: \(m.label)" }
        return t
    }

    private func option(_ title: String, _ sub: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: { withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { action() } }) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(sub).font(.caption2).opacity(0.75).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(selected ? AnyShapeStyle(tint) : AnyShapeStyle(.white.opacity(0.08)), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .foregroundStyle(selected ? .black : .white)
        }
        .buttonStyle(PressScale())
    }
}
