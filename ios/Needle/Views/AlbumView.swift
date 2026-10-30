import SwiftUI

struct AlbumView: View {
    @Environment(AppModel.self) private var app
    @Environment(Downloads.self) private var downloads
    @Environment(Player.self) private var player
    let album: Album
    @State private var loader = Loader<(Album, [Track])>()
    @State private var full: FullAlbum?
    @State private var others: [String: Track] = [:]
    @State private var sent: Set<String> = []
    @State private var askedAll = false

    var body: some View {
        let info = loader.value?.0 ?? album
        let local = loader.value?.1 ?? []
        let merged = full.map { merge($0, local) }
        let tracks = merged?.play ?? local
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
                           error: loader.error,
                           rows: merged?.rows,
                           banner: full.flatMap { f in (f.missing ?? 0) > 0 ? AnyView(missingBanner(f)) : nil },
                           onGetOne: { getOne($0) },
                           sent: sent)
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
                await loadFull()
            }
    }

    /// The real album's whole tracklist from the catalog (needs the helper on the NAS; skipped quietly without it).
    private func loadFull() async {
        guard let local = loader.value?.1, let f = try? await app.helper.fullAlbum(libraryId: album.id) else { return }
        let have = Set(local.map(\.id))
        var found: [String: Track] = [:]
        for t in f.tracks {
            guard let id = t.songId, !have.contains(id) else { continue }
            if let s = try? await app.client.song(id) { found[id] = Track(song: s) }     // you have it on another album
        }
        others = found
        full = f
    }

    private func merge(_ f: FullAlbum, _ local: [Track]) -> (rows: [AlbumRow], play: [Track]) {
        var byId: [String: Track] = others
        for t in local { byId[t.id] = t }
        var rows: [AlbumRow] = []
        var play: [Track] = []
        for (k, c) in f.tracks.enumerated() {
            if let id = c.songId, let t = byId[id] {
                rows.append(.have(t, k + 1))
                play.append(t)
            } else {
                rows.append(.missing(c, k + 1))
            }
        }
        let extra = (f.extra ?? []).compactMap { byId[$0] }
        if !extra.isEmpty {
            rows.append(.header("Also on your copy"))
            for t in extra {
                rows.append(.have(t, 0))
                play.append(t)
            }
        }
        return (rows, play)
    }

    private func missingBanner(_ f: FullAlbum) -> some View {
        let n = f.missing ?? 0
        let haveCount = f.tracks.count - n
        return VStack(alignment: .leading, spacing: 10) {
            Text(haveCount == 0 ? "None of \(f.title) is in your library yet" : "\(haveCount) of \(f.tracks.count) songs from \(f.title) are in your library")
                .font(.subheadline).foregroundStyle(Theme.secondary)
            Button { getAll(f) } label: {
                Label(askedAll ? "On the way" : n == 1 ? "Download the Missing Song" : "Download \(n) Missing Songs",
                      systemImage: askedAll ? "checkmark" : "arrow.down.circle.fill")
                    .padding(.horizontal, 18)
            }
            .buttonStyle(FilledPill(fill: askedAll ? Color.white.opacity(0.1) : Theme.accent, text: askedAll ? .white : .black))
            .font(.headline)
            .disabled(askedAll)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    private func getAll(_ f: FullAlbum) {
        askedAll = true
        for t in f.tracks where t.songId == nil { sent.insert(t.id) }
        let h = app.helper
        Task {
            do {
                _ = try await h.getAlbum(f)
                player.errorMessage = "Getting the rest of \(f.title)"
            } catch {
                askedAll = false
                for t in f.tracks where t.songId == nil { sent.remove(t.id) }
                player.errorMessage = error.localizedDescription
            }
        }
    }

    private func getOne(_ s: CatalogSong) {
        sent.insert(s.id)
        let h = app.helper
        Task {
            do {
                _ = try await h.get([s])
                player.errorMessage = "Downloading “\(s.title)”"
            } catch {
                sent.remove(s.id)
                player.errorMessage = error.localizedDescription
            }
        }
    }
}

/// A row on an album screen: a song you have, one you don't (grayed out), or a little heading.
enum AlbumRow: Identifiable {
    case have(Track, Int)
    case missing(CatalogSong, Int)
    case header(String)

    var id: String {
        switch self {
        case .have(let t, let n): return "have-\(n)-\(t.id)"
        case .missing(let s, let n): return "missing-\(n)-\(s.id)"
        case .header(let h): return "header-\(h)"
        }
    }
}

/// A song from the album you don't have yet: grayed out, with a download button.
struct MissingSongRow: View {
    let song: CatalogSong
    let number: Int
    let sent: Bool
    let get: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(String(number)).font(.subheadline.monospacedDigit()).foregroundStyle(Theme.tertiary).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title).lineLimit(1)
                Text(sent ? "On the way" : "Not downloaded").font(.caption).foregroundStyle(Theme.secondary).lineLimit(1)
            }
            .opacity(0.45)
            Spacer(minLength: 8)
            if let d = song.duration, d > 0 {
                Text(formatTime(Double(d))).font(.caption.monospacedDigit()).foregroundStyle(Theme.tertiary).opacity(0.6)
            }
            Button(action: get) {
                Image(systemName: sent ? "checkmark.circle.fill" : "arrow.down.circle")
                    .font(.title2)
                    .foregroundStyle(sent ? Theme.accent : .white)
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
            .disabled(sent)
            .accessibilityLabel(sent ? "On the way" : "Download \(song.title)")
        }
        .padding(.leading, 20).padding(.trailing, 12)
        .padding(.vertical, 7)
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
    /// The album's full tracklist (songs you don't have are grayed out); nil shows just `tracks`.
    var rows: [AlbumRow]? = nil
    var banner: AnyView? = nil
    var onGetOne: ((CatalogSong) -> Void)? = nil
    var sent: Set<String> = []

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

                if let rows {
                    if let banner { banner }
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { row in rowView(row) }
                    }
                } else {
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

    @ViewBuilder
    private func rowView(_ row: AlbumRow) -> some View {
        switch row {
        case .have(let t, let n):
            TrackRow(track: t, number: n > 0 ? n : nil, showArtwork: false) {
                player.play(tracks, startAt: tracks.firstIndex(of: t) ?? 0)
            }
        case .missing(let s, let n):
            MissingSongRow(song: s, number: n, sent: sent.contains(s.id)) { onGetOne?(s) }
        case .header(let h):
            Text(h)
                .font(.footnote.weight(.semibold)).foregroundStyle(Theme.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 6)
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
    @State private var loader = Loader<(Artist, [Album])>()
    @State private var info: SubsonicResponse.ArtistInfo?
    @State private var starting = false
    @State private var bioOpen = false
    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 16)]

    var body: some View {
        let albums = loader.value?.1 ?? []
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                hero
                PlayButtons(play: { Task { await playAll(albums, shuffle: false) } },
                            shuffle: { Task { await playAll(albums, shuffle: true) } })
                    .disabled(albums.isEmpty || starting)
                if let bio = info?.biography.map(Self.plain), !bio.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("About").font(.system(size: 20, weight: .bold).width(.expanded))
                        Text(bio).font(.subheadline).foregroundStyle(Theme.secondary)
                            .lineLimit(bioOpen ? nil : 4)
                        Button(bioOpen ? "Less" : "More") { withAnimation(.easeInOut) { bioOpen.toggle() } }
                            .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.accent)
                    }
                    .padding(.horizontal, 20)
                    .transition(.opacity)
                }
                Text("Albums").font(.system(size: 20, weight: .bold).width(.expanded)).padding(.horizontal, 20)
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
                        .buttonStyle(PressScale())
                        .zoomSource(a.id)
                    }
                }
                .padding(.horizontal, 20)
                if loader.loading && albums.isEmpty { ProgressView().frame(maxWidth: .infinity).padding(40) }
                if let similar = info?.similarArtist, !similar.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Fans Also Like").font(.system(size: 20, weight: .bold).width(.expanded)).padding(.horizontal, 20)
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: 16) {
                                ForEach(similar) { a in
                                    NavigationLink(value: ArtistRoute(id: a.id, name: a.name)) {
                                        VStack(spacing: 6) {
                                            ArtistPhoto(url: a.artistImageUrl, coverArt: a.coverArt ?? a.id, size: 100)
                                            Text(a.name).font(.caption.weight(.semibold)).lineLimit(1)
                                        }
                                        .frame(width: 100)
                                    }
                                    .buttonStyle(PressScale())
                                    .shelfAppear()
                                }
                            }
                            .padding(.horizontal, 20)
                        }
                    }
                }
            }
            .padding(.bottom, 24)
        }
        .background(Theme.background)
        .ignoresSafeArea(edges: .top)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loader.load {
                let (a, albums) = try await app.client.artist(route.id)
                return (a, albums)
            }
            let i = try? await app.client.artistInfo(route.id)
            withAnimation(.easeInOut(duration: 0.4)) { info = i }
        }
    }

    private var hero: some View {
        let url = info?.largeImageUrl ?? loader.value?.0.artistImageUrl
        return ZStack(alignment: .bottomLeading) {
            Group {
                if let s = url, let u = URL(string: s), !s.contains("2a96cbd8b46e442fc41c2b86b821562f") {   // Last.fm's blank star image
                    AsyncImage(url: u, transaction: Transaction(animation: .easeInOut(duration: 0.5))) { phase in
                        if let img = phase.image { img.resizable().scaledToFill() } else { fallbackHero }
                    }
                } else {
                    fallbackHero
                }
            }
            .frame(height: 320)
            .frame(maxWidth: .infinity)
            .clipped()
            LinearGradient(colors: [.clear, Theme.background.opacity(0.6), Theme.background], startPoint: .center, endPoint: .bottom)
            Text(route.name).font(Theme.title(34)).lineLimit(2).minimumScaleFactor(0.6)
                .shadow(color: .black.opacity(0.5), radius: 10)
                .padding(.horizontal, 20).padding(.bottom, 8)
        }
        .frame(height: 320)
    }

    @ViewBuilder private var fallbackHero: some View {
        if let first = loader.value?.1.first {
            ArtworkView(track: nil, coverArt: first.coverArt ?? first.id, size: 400, corner: 0)
                .blur(radius: 30).opacity(0.7)
        } else {
            Theme.surface
        }
    }

    /// Last.fm bios are HTML with a "Read more" link; keep just the words.
    static func plain(_ html: String) -> String {
        var s = html.replacingOccurrences(of: "<a[^>]*>.*?</a>", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
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

/// A round artist photo, or their cover art if there's no photo.
struct ArtistPhoto: View {
    let url: String?
    let coverArt: String
    let size: CGFloat
    var body: some View {
        Group {
            if let s = url, let u = URL(string: s), !s.contains("2a96cbd8b46e442fc41c2b86b821562f") {
                AsyncImage(url: u) { phase in
                    if let img = phase.image { img.resizable().scaledToFill() }
                    else { ArtworkView(track: nil, coverArt: coverArt, size: size, corner: size / 2) }
                }
            } else {
                ArtworkView(track: nil, coverArt: coverArt, size: size, corner: size / 2)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}
