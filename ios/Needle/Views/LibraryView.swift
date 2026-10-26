import SwiftUI
import UniformTypeIdentifiers

// MARK: - Navigation

struct ArtistRoute: Hashable { let id: String; let name: String }
struct PlaylistRoute: Hashable { let playlist: Playlist }
struct LocalAlbumRoute: Hashable { let name: String; let artist: String }
enum ListRoute: Hashable { case albums, artists, playlists, favorites, downloads, onPhone, importer }

extension View {
    func withDestinations() -> some View {
        self
            .navigationDestination(for: Album.self) { AlbumView(album: $0) }
            .navigationDestination(for: ArtistRoute.self) { ArtistView(route: $0) }
            .navigationDestination(for: PlaylistRoute.self) { PlaylistView(playlist: $0.playlist) }
            .navigationDestination(for: LocalAlbumRoute.self) { LocalAlbumView(route: $0) }
            .navigationDestination(for: ImportRoute.self) { ImportJobView(id: $0.id) }
            .navigationDestination(for: ListRoute.self) { route in
                switch route {
                case .albums: AlbumsGridView()
                case .artists: ArtistsListView()
                case .playlists: PlaylistsListView()
                case .favorites: FavoritesView()
                case .downloads: DownloadsView()
                case .onPhone: OnPhoneView()
                case .importer: ImportView()
                }
            }
    }
}

// MARK: - Library tab

struct LibraryView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(Downloads.self) private var downloads
    @Environment(LocalLibrary.self) private var local

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ScreenTitle(text: "Library").padding(.bottom, 16)
                if settings.config.isComplete {
                    row("Albums", "square.stack", .albums)
                    row("Artists", "music.mic", .artists)
                    row("Playlists", "music.note.list", .playlists)
                    row("Favorites", "heart", .favorites)
                }
                row("Downloaded", "arrow.down.circle", .downloads, count: downloads.saved.count)
                if settings.config.isComplete {
                    row("Import a Spotify Playlist", "square.and.arrow.down.on.square", .importer)
                }
                row("On This iPhone", "iphone", .onPhone, count: local.tracks.count)
            }
            .padding(.bottom, 24)
        }
        .background(Theme.background)
        .toolbar(.hidden, for: .navigationBar)
        .withDestinations()
    }

    private func row(_ title: String, _ icon: String, _ route: ListRoute, count: Int? = nil) -> some View {
        NavigationLink(value: route) {
            HStack(spacing: 16) {
                Image(systemName: icon).font(.title3).foregroundStyle(Theme.accent).frame(width: 28)
                Text(title).font(.title3.weight(.medium))
                Spacer()
                if let count, count > 0 { Text("\(count)").foregroundStyle(Theme.tertiary) }
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Theme.tertiary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 15)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
        .overlay(alignment: .bottom) { Theme.line.frame(height: 1).padding(.leading, 64) }
    }
}

// MARK: - All albums

struct AlbumsGridView: View {
    @Environment(AppModel.self) private var app
    enum Sort: String, CaseIterable, Identifiable {
        case alphabeticalByName = "A–Z", newest = "Recently Added", alphabeticalByArtist = "Artist", frequent = "Most Played"
        var id: String { rawValue }
        var api: String { String(describing: self) }
    }
    @State private var sort: Sort = .alphabeticalByName
    @State private var albums: [Album] = []
    @State private var done = false
    @State private var loading = false
    @State private var error: String?

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 16)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 22) {
                ForEach(albums) { album in
                    NavigationLink(value: album) { AlbumCard(album: album, size: 160) }
                        .buttonStyle(.plain)
                        .onAppear { if album.id == albums.last?.id { Task { await more() } } }
                }
            }
            .padding(20)
            if loading { ProgressView().padding() }
            if let error { StatusView(icon: "wifi.exclamationmark", title: "Couldn't load albums", message: error) { Task { await reload() } } }
        }
        .background(Theme.background)
        .navigationTitle("Albums")
        .toolbar {
            Menu {
                Picker("Sort", selection: $sort) { ForEach(Sort.allCases) { Text($0.rawValue).tag($0) } }
            } label: { Image(systemName: "arrow.up.arrow.down") }
        }
        .task(id: sort) { await reload() }
    }

    private func reload() async { albums = []; done = false; await more() }

    private func more() async {
        guard !loading, !done else { return }
        loading = true
        defer { loading = false }
        do {
            let page = try await app.client.albums(sort.api, size: 60, offset: albums.count)
            albums += page
            done = page.count < 60
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}

// MARK: - Artists

struct ArtistsListView: View {
    @Environment(AppModel.self) private var app
    @State private var loader = Loader<[Artist]>()
    @State private var filter = ""

    var body: some View {
        let list = (loader.value ?? []).filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) }
        List(list) { artist in
            NavigationLink(value: ArtistRoute(id: artist.id, name: artist.name)) {
                HStack(spacing: 14) {
                    ArtworkView(track: nil, coverArt: artist.coverArt ?? artist.id, size: 48, corner: 24)
                    VStack(alignment: .leading) {
                        Text(artist.name).font(.body.weight(.medium))
                        if let n = artist.albumCount { Text("\(n) album\(n == 1 ? "" : "s")").font(.caption).foregroundStyle(Theme.secondary) }
                    }
                }
            }
            .listRowBackground(Theme.background)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .searchable(text: $filter, prompt: "Filter artists")
        .navigationTitle("Artists")
        .overlay { if loader.loading && loader.value == nil { ProgressView() } }
        .task { if loader.value == nil { await loader.load { try await app.client.artists() } } }
    }
}

// MARK: - Playlists

struct PlaylistsListView: View {
    @Environment(AppModel.self) private var app
    @State private var loader = Loader<[Playlist]>()

    var body: some View {
        List(loader.value ?? []) { p in
            NavigationLink(value: PlaylistRoute(playlist: p)) {
                HStack(spacing: 14) {
                    ArtworkView(track: nil, coverArt: p.coverArt ?? p.id, size: 56, corner: 8)
                    VStack(alignment: .leading) {
                        Text(p.name).font(.body.weight(.medium))
                        Text("\(p.songCount ?? 0) songs").font(.caption).foregroundStyle(Theme.secondary)
                    }
                }
            }
            .listRowBackground(Theme.background)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Playlists")
        .toolbar {
            NavigationLink(value: ListRoute.importer) { Label("Import from Spotify", systemImage: "square.and.arrow.down") }
        }
        .overlay {
            if loader.value?.isEmpty == true {
                StatusView(icon: "music.note.list", title: "No playlists yet", message: "Playlists you make in Navidrome show up here.")
            }
        }
        .task { await loader.load { try await app.client.playlists() } }
    }
}

struct PlaylistView: View {
    @Environment(AppModel.self) private var app
    @Environment(Player.self) private var player
    let playlist: Playlist
    @State private var loader = Loader<[Track]>()

    var body: some View {
        let tracks = loader.value ?? []
        ScrollView {
            VStack(spacing: 18) {
                ArtworkView(track: nil, coverArt: playlist.coverArt ?? playlist.id, size: 220, corner: 14)
                    .shadow(color: .black.opacity(0.5), radius: 24, y: 12)
                    .padding(.top, 12)
                Text(playlist.name).font(Theme.title(24)).multilineTextAlignment(.center).padding(.horizontal, 20)
                PlayButtons(play: { player.play(tracks) }, shuffle: { player.play(tracks, shuffle: true) })
                LazyVStack(spacing: 0) {
                    ForEach(Array(tracks.enumerated()), id: \.offset) { i, t in
                        TrackRow(track: t) { player.play(tracks, startAt: i) }
                    }
                }
            }
            .padding(.bottom, 20)
        }
        .background(Theme.background)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { Menu { TrackMenu(tracks: tracks) } label: { Image(systemName: "ellipsis.circle") } }
        .task { await loader.load { try await app.client.playlist(playlist.id).map(Track.init(song:)) } }
    }
}

// MARK: - Favorites

struct FavoritesView: View {
    @Environment(AppModel.self) private var app
    @Environment(Player.self) private var player
    @State private var loader = Loader<SubsonicResponse.SearchResult>()

    var body: some View {
        let songs = (loader.value?.song ?? []).map(Track.init(song:))
        let albums = loader.value?.album ?? []
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if !albums.isEmpty {
                    SectionHeader(title: "Albums")
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 14) {
                            ForEach(albums) { a in NavigationLink(value: a) { AlbumCard(album: a, size: 140) }.buttonStyle(.plain) }
                        }
                        .padding(.horizontal, 20)
                    }
                }
                if !songs.isEmpty {
                    SectionHeader(title: "Songs")
                    PlayButtons(play: { player.play(songs) }, shuffle: { player.play(songs, shuffle: true) })
                    LazyVStack(spacing: 0) {
                        ForEach(Array(songs.enumerated()), id: \.offset) { i, t in TrackRow(track: t) { player.play(songs, startAt: i) } }
                    }
                }
                if loader.value != nil && songs.isEmpty && albums.isEmpty {
                    StatusView(icon: "heart", title: "No favorites yet", message: "Tap the heart on the Now Playing screen to save songs here.")
                }
            }
            .padding(.vertical, 12)
        }
        .background(Theme.background)
        .navigationTitle("Favorites")
        .task { await loader.load { try await app.client.starred() } }
    }
}

// MARK: - Downloaded

struct DownloadsView: View {
    @Environment(Downloads.self) private var downloads
    @Environment(Player.self) private var player

    var body: some View {
        let tracks = downloads.tracks
        List {
            if !tracks.isEmpty {
                Section {
                    PlayButtons(play: { player.play(tracks) }, shuffle: { player.play(tracks, shuffle: true) })
                        .listRowInsets(EdgeInsets())
                        .padding(.vertical, 8)
                } footer: {
                    Text("\(tracks.count) songs · \(ByteCountFormatter.string(fromByteCount: downloads.totalBytes, countStyle: .file)). Plays with no connection.")
                }
                .listRowBackground(Theme.background)
            }
            ForEach(Array(tracks.enumerated()), id: \.element.id) { i, t in
                TrackRow(track: t) { player.play(tracks, startAt: i) }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Theme.background)
            }
            .onDelete { offsets in downloads.remove(offsets.map { tracks[$0] }) }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Downloaded")
        .overlay {
            if tracks.isEmpty {
                StatusView(icon: "arrow.down.circle", title: "Nothing downloaded",
                           message: "Download albums or songs to play them with no signal. Long-press any song, or use the download button on an album.")
            }
        }
    }
}

// MARK: - Music on this iPhone

struct OnPhoneView: View {
    @Environment(LocalLibrary.self) private var local
    @State private var importing = false
    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 16)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Button { importing = true } label: {
                    Label("Import from Files", systemImage: "folder.badge.plus").frame(maxWidth: .infinity)
                }
                .buttonStyle(FilledPill(fill: Theme.accent, text: .black))
                .font(.headline)
                .padding(.horizontal, 20)

                Text("You can also drop music into Files › On My iPhone › Needle. It shows up here automatically.")
                    .font(.footnote).foregroundStyle(Theme.secondary).padding(.horizontal, 20)

                if local.isImporting { HStack { ProgressView(); Text("Importing…") }.padding(.horizontal, 20) }

                LazyVGrid(columns: columns, alignment: .leading, spacing: 22) {
                    ForEach(local.albums) { a in
                        NavigationLink(value: LocalAlbumRoute(name: a.name, artist: a.artist)) {
                            VStack(alignment: .leading, spacing: 6) {
                                ArtworkView(track: a.tracks.first, size: 160, corner: 10)
                                Text(a.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                                Text(a.artist).font(.caption).foregroundStyle(Theme.secondary).lineLimit(1)
                            }
                            .frame(width: 160)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive) { local.remove(a.tracks) } label: { Label("Remove from iPhone", systemImage: "trash") }
                        }
                    }
                }
                .padding(.horizontal, 20)
            }
            .padding(.vertical, 12)
        }
        .background(Theme.background)
        .navigationTitle("On This iPhone")
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { Task { await local.importFiles(urls) } }
        }
    }
}

struct LocalAlbumView: View {
    @Environment(LocalLibrary.self) private var local
    @Environment(Player.self) private var player
    let route: LocalAlbumRoute

    var body: some View {
        let tracks = local.albums.first { $0.name == route.name && $0.artist == route.artist }?.tracks ?? []
        AlbumLayout(title: route.name, artist: route.artist, artistRoute: nil, meta: "\(tracks.count) songs on this iPhone",
                    artTrack: tracks.first, coverArt: nil, tracks: tracks, showTrackNumbers: true)
            .toolbar {
                Menu {
                    TrackMenu(tracks: tracks)
                    Button(role: .destructive) { local.remove(tracks) } label: { Label("Remove from iPhone", systemImage: "trash") }
                } label: { Image(systemName: "ellipsis.circle") }
            }
    }
}
