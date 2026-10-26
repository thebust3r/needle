import SwiftUI

struct AlbumView: View {
    @Environment(AppModel.self) private var app
    @Environment(Downloads.self) private var downloads
    let album: Album
    @State private var loader = Loader<(Album, [Track])>()

    var body: some View {
        let info = loader.value?.0 ?? album
        let tracks = loader.value?.1 ?? []
        var meta: [String] = []
        if let y = info.year, y > 0 { meta.append(String(y)) }
        if let g = info.genre, !g.isEmpty { meta.append(g) }
        if !tracks.isEmpty { meta.append("\(tracks.count) songs") }
        let total = Int(tracks.reduce(0) { $0 + $1.duration })
        if total > 0 { meta.append(formatDuration(total)) }

        return AlbumLayout(title: info.name, artist: info.artist ?? "",
                           artistRoute: info.artistId.map { ArtistRoute(id: $0, name: info.artist ?? "") },
                           meta: meta.joined(separator: " · "),
                           artTrack: tracks.first, coverArt: info.coverArt ?? info.id,
                           tracks: tracks, showTrackNumbers: true, loading: loader.loading && tracks.isEmpty,
                           error: loader.error)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if !tracks.isEmpty { downloadButton(tracks) }
                    Menu { TrackMenu(tracks: tracks) } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .task {
                await loader.load {
                    let (a, songs) = try await app.client.album(album.id)
                    return (a, songs.map(Track.init(song:)))
                }
            }
    }

    @ViewBuilder
    private func downloadButton(_ tracks: [Track]) -> some View {
        let saved = tracks.filter { downloads.isSaved($0.id) }.count
        let busy = tracks.contains { downloads.active.contains($0.id) }
        if busy {
            ProgressView(value: Double(saved), total: Double(tracks.count))
                .progressViewStyle(.circular).tint(Theme.accent)
        } else if saved == tracks.count {
            Button { downloads.remove(tracks) } label: { Image(systemName: "arrow.down.circle.fill").foregroundStyle(Theme.accent) }
        } else {
            Button { downloads.save(tracks) } label: { Image(systemName: "arrow.down.circle") }
        }
    }
}

/// The shared look for album-style screens: a color wash from the cover, the art, and the songs.
struct AlbumLayout: View {
    @Environment(Player.self) private var player
    let title: String
    let artist: String
    let artistRoute: ArtistRoute?
    let meta: String
    let artTrack: Track?
    let coverArt: String?
    let tracks: [Track]
    var showTrackNumbers = true
    var loading = false
    var error: String? = nil

    @State private var palette = Palette.fallback

    private var multiDisc: Bool { Set(tracks.compactMap(\.disc)).count > 1 }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                header
                PlayButtons(tint: palette.accent,
                            play: { player.play(tracks) },
                            shuffle: { player.play(tracks, shuffle: true) })
                    .disabled(tracks.isEmpty)
                    .padding(.top, 20)
                    .padding(.bottom, 12)

                if loading { ProgressView().padding(40) }
                if let error, tracks.isEmpty { StatusView(icon: "wifi.exclamationmark", title: "Couldn't load this album", message: error) }

                LazyVStack(spacing: 0) {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { i, t in
                        if multiDisc, t.disc != tracks[safe: i - 1]?.disc {
                            Text("Disc \(t.disc ?? 1)")
                                .font(.footnote.weight(.semibold)).foregroundStyle(Theme.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 20).padding(.top, i == 0 ? 4 : 18).padding(.bottom, 6)
                        }
                        TrackRow(track: t, number: t.trackNumber ?? (i + 1), showArtwork: false) {
                            player.play(tracks, startAt: i)
                        }
                    }
                }
            }
            .padding(.bottom, 24)
        }
        .background(alignment: .top) {
            LinearGradient(colors: [palette.top.opacity(0.9), palette.bottom.opacity(0.5), Theme.background],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 560)
                .ignoresSafeArea(edges: .top)
        }
        .background(Theme.background)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .task(id: artTrack?.artworkKey ?? coverArt) {
            let p: Palette
            if let t = artTrack {
                p = await ArtworkStore.shared.palette(for: t)
            } else if let c = coverArt {
                var probe = Track(id: c, title: "", artist: "", album: "", duration: 0, localArtwork: nil, filename: "")
                probe.coverArt = c
                probe.localArtwork = nil
                p = await ArtworkStore.shared.palette(for: probe)
            } else { p = .fallback }
            withAnimation(.easeInOut(duration: 0.5)) { palette = p }
        }
    }

    private var header: some View {
        VStack(spacing: 14) {
            ArtworkView(track: artTrack, coverArt: coverArt, size: 250, corner: 14)
                .shadow(color: .black.opacity(0.5), radius: 30, y: 16)
                .padding(.top, 8)
            VStack(spacing: 4) {
                Text(title).font(Theme.title(24)).multilineTextAlignment(.center)
                if let artistRoute {
                    NavigationLink(value: artistRoute) {
                        Text(artist).font(.title3.weight(.medium)).foregroundStyle(palette.accent)
                    }
                } else {
                    Text(artist).font(.title3.weight(.medium)).foregroundStyle(palette.accent)
                }
                if !meta.isEmpty { Text(meta).font(.caption).foregroundStyle(Theme.secondary).padding(.top, 2) }
            }
            .padding(.horizontal, 24)
        }
    }
}

struct ArtistView: View {
    @Environment(AppModel.self) private var app
    @Environment(Player.self) private var player
    let route: ArtistRoute
    @State private var loader = Loader<[Album]>()
    @State private var starting = false
    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 16)]

    var body: some View {
        let albums = loader.value ?? []
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(route.name).font(Theme.title(32)).padding(.horizontal, 20).padding(.top, 8)
                PlayButtons(play: { Task { await playAll(albums, shuffle: false) } },
                            shuffle: { Task { await playAll(albums, shuffle: true) } })
                    .disabled(albums.isEmpty || starting)
                LazyVGrid(columns: columns, alignment: .leading, spacing: 22) {
                    ForEach(albums) { a in
                        NavigationLink(value: a) {
                            VStack(alignment: .leading, spacing: 6) {
                                ArtworkView(track: nil, coverArt: a.coverArt ?? a.id, size: 160, corner: 10)
                                Text(a.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                                if let y = a.year, y > 0 { Text(String(y)).font(.caption).foregroundStyle(Theme.secondary) }
                            }
                            .frame(width: 160)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
                if loader.loading && albums.isEmpty { ProgressView().frame(maxWidth: .infinity).padding(40) }
            }
            .padding(.bottom, 24)
        }
        .background(Theme.background)
        .navigationBarTitleDisplayMode(.inline)
        .task { await loader.load { try await app.client.artist(route.id).1 } }
    }

    private func playAll(_ albums: [Album], shuffle: Bool) async {
        starting = true
        defer { starting = false }
        var all: [Track] = []
        for a in albums {
            if let result = try? await app.client.album(a.id) { all += result.1.map(Track.init(song:)) }
        }
        player.play(all, shuffle: shuffle)
    }
}
