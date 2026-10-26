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
                Section {
                    ForEach(Array(player.upNext.enumerated()), id: \.offset) { i, t in
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
                    .onDelete { player.removeUpNext(at: $0) }
                    .onMove { player.moveUpNext(from: $0, to: $1) }
                } header: {
                    HStack {
                        Text("Up Next")
                        Spacer()
                        if player.shuffled { Label("Shuffled", systemImage: "shuffle").font(.caption) }
                    }
                } footer: {
                    if player.upNext.isEmpty { Text("Nothing queued. Long-press any song to add it.") }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .toolbar { if !player.upNext.isEmpty { EditButton() } }
            .navigationTitle("Queue")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
