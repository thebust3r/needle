import SwiftUI

/// Synced lyrics: the line being sung lights up and scrolls into view; tap a line to jump there.
struct LyricsView: View {
    @Environment(AppModel.self) private var app
    @Environment(Player.self) private var player
    @State private var userScrolledAt = Date.distantPast

    private var store: LyricsStore { app.lyrics }

    var body: some View {
        Group {
            switch store.state {
            case .idle, .loading:
                note("Finding lyrics…")
            case .failed:
                note("Couldn't reach the lyrics service. Check your connection.")
            case .none:
                note("No lyrics found for this song.")
            case .loaded(let lyrics):
                if lyrics.instrumental { note("Instrumental. No lyrics to show.") }
                else if lyrics.lines.isEmpty { note("No lyrics found for this song.") }
                else { lines(lyrics) }
            }
        }
        .task(id: player.current?.id) { await store.load(player.current, client: app.client) }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.body)
            .foregroundStyle(.white.opacity(0.65))
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func lines(_ lyrics: Lyrics) -> some View {
        let current = lyrics.synced ? lyrics.index(at: player.currentTime + 0.15) : -1
        return ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(Array(lyrics.lines.enumerated()), id: \.offset) { i, line in
                        Text(line.text.isEmpty ? "♪" : line.text)
                            .font(lyrics.synced ? Theme.title(26) : .system(size: 21, weight: .semibold))
                            .foregroundStyle(color(i, current: current, synced: lyrics.synced))
                            .scaleEffect(i == current ? 1.03 : 1, anchor: .leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                guard lyrics.synced else { return }
                                player.seek(to: line.t)
                                userScrolledAt = .distantPast
                            }
                            .id(i)
                            .animation(.easeOut(duration: 0.3), value: current)
                    }
                    Text("\(lyrics.synced ? "Synced lyrics" : "Lyrics") from \(lyrics.source)")
                        .font(.caption).foregroundStyle(.white.opacity(0.45)).padding(.top, 10)
                }
                .padding(.vertical, 120)
            }
            .simultaneousGesture(DragGesture().onChanged { _ in userScrolledAt = Date() })
            .onChange(of: current) { _, new in
                guard new >= 0, Date().timeIntervalSince(userScrolledAt) > 3.5 else { return }
                withAnimation(.easeInOut(duration: 0.45)) { proxy.scrollTo(new, anchor: UnitPoint(x: 0, y: 0.32)) }
            }
        }
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.12),
                                     .init(color: .black, location: 0.8), .init(color: .clear, location: 1)],
                             startPoint: .top, endPoint: .bottom))
    }

    private func color(_ i: Int, current: Int, synced: Bool) -> Color {
        guard synced else { return .white.opacity(0.85) }
        if i == current { return .white }
        return .white.opacity(i < current ? 0.5 : 0.34)
    }
}
