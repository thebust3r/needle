import SwiftUI

struct QueueView: View {
    @Environment(Player.self) private var player

    var body: some View {
        NavigationStack {
            List {
                if let t = player.current {
                    Section("Now Playing") {
                        HStack(spacing: 12) {
                            ArtworkView(track: t, size: 46, corner: 6)
                            VStack(alignment: .leading) {
                                Text(t.title).font(.body.weight(.semibold)).lineLimit(1)
                                Text(t.artist).font(.caption).foregroundStyle(Theme.secondary).lineLimit(1)
                            }
                            Spacer()
                            NowPlayingBars(playing: player.isPlaying).frame(width: 16, height: 14)
                        }
                        .listRowBackground(Color.clear)
                    }
                }
                let n = player.queuedCount
                let up = player.upNext
                if n > 0 {
                    Section {
                        ForEach(Array(up.prefix(n).enumerated()), id: \.offset) { i, t in row(t, at: i) }
                            .onDelete { player.removeUpNext(at: $0) }
                            .onMove { player.moveUpNext(from: $0, to: min($1, n)) }
                    } header: {
                        HStack {
                            Text("Next in Queue")
                            Spacer()
                            Button("Clear") { withAnimation { player.clearQueued() } }.font(.caption.weight(.semibold))
                        }
                    }
                }
                Section {
                    ForEach(Array(up.dropFirst(n).enumerated()), id: \.offset) { i, t in row(t, at: i + n) }
                        .onDelete { offsets in player.removeUpNext(at: IndexSet(offsets.map { $0 + n })) }
                        .onMove { from, to in player.moveUpNext(from: IndexSet(from.map { $0 + n }), to: to + n) }
                } header: {
                    HStack {
                        Text(n > 0 ? "Then" : "Up Next")
                        Spacer()
                        if player.shuffled { Label("Shuffled", systemImage: "shuffle").font(.caption) }
                    }
                } footer: {
                    if up.isEmpty { Text("Nothing queued. Swipe a song right, or use its ••• menu, to add it.") }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .toolbar { if !player.upNext.isEmpty { EditButton() } }
            .navigationTitle("Queue")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func row(_ t: Track, at i: Int) -> some View {
        Button { player.jump(toUpNext: i) } label: {
            HStack(spacing: 12) {
                ArtworkView(track: t, size: 40, corner: 5)
                VStack(alignment: .leading) {
                    Text(t.title).lineLimit(1)
                    Text(t.artist).font(.caption).foregroundStyle(Theme.secondary).lineLimit(1)
                }
                Spacer()
                Text(formatTime(t.duration)).font(.caption.monospacedDigit()).foregroundStyle(Theme.tertiary)
            }
        }
        .foregroundStyle(.white)
        .listRowBackground(Color.clear)
    }
}
