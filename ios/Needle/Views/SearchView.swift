import SwiftUI

struct SearchView: View {
    @Environment(AppModel.self) private var app
    @Environment(Player.self) private var player
    @Environment(LocalLibrary.self) private var local
    @Environment(AppSettings.self) private var settings
    @State private var query = ""
    @State private var result = SubsonicResponse.SearchResult()
    @State private var searching = false
    @State private var error: String?
    @AppStorage("searchMode") private var mode = "library"     // "library" or "get" (download new music)
    @AppStorage("getKind") private var kind = "song"

    private var localHits: [Track] {
        guard !query.isEmpty else { return [] }
        return local.tracks.filter {
            $0.title.localizedCaseInsensitiveContains(query) || $0.artist.localizedCaseInsensitiveContains(query)
                || $0.album.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        let songs = (result.song ?? []).map(Track.init(song:)) + localHits
        ScrollView {
            if mode == "get" {
                GetMusicResults(query: query.trimmingCharacters(in: .whitespaces), kind: kind)
                    .padding(.bottom, 24)
            } else {
            VStack(alignment: .leading, spacing: 22) {
                if query.isEmpty {
                    StatusView(icon: "magnifyingglass", title: "Find anything",
                               message: "Search songs, albums and artists across your NAS and this iPhone.")
                        .padding(.top, 40)
                } else {
                    if let artists = result.artist, !artists.isEmpty {
                        SectionHeader(title: "Artists")
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 16) {
                                ForEach(artists) { a in
                                    NavigationLink(value: ArtistRoute(id: a.id, name: a.name)) {
                                        VStack(spacing: 8) {
                                            ArtworkView(track: nil, coverArt: a.coverArt ?? a.id, size: 96, corner: 48)
                                            Text(a.name).font(.caption.weight(.medium)).lineLimit(1)
                                        }
                                        .frame(width: 96)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 20)
                        }
                    }
                    if let albums = result.album, !albums.isEmpty {
                        SectionHeader(title: "Albums")
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: 14) {
                                ForEach(albums) { a in
                                    NavigationLink(value: a) { AlbumCard(album: a, size: 140) }.buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 20)
                        }
                    }
                    if !songs.isEmpty {
                        SectionHeader(title: "Songs")
                        LazyVStack(spacing: 0) {
                            ForEach(Array(songs.enumerated()), id: \.element.id) { i, t in
                                TrackRow(track: t) { player.play(songs, startAt: i) }
                            }
                        }
                    }
                    if searching && songs.isEmpty { ProgressView().frame(maxWidth: .infinity).padding(30) }
                    if let error { Text(error).font(.footnote).foregroundStyle(Theme.secondary).padding(.horizontal, 20) }
                    if !searching && error == nil && songs.isEmpty && (result.album ?? []).isEmpty && (result.artist ?? []).isEmpty {
                        StatusView(icon: "questionmark.circle", title: "No results", message: "Nothing matches “\(query)”.")
                    }
                }
            }
            .padding(.bottom, 24)
            }
        }
        .scrollDismissesKeyboard(.immediately)
        .background(Theme.background)
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .top) {
            VStack(spacing: 4) {
                ScreenTitle(text: "Search")
                modePicker
                searchField
                if mode == "get" { kindPicker }
            }
            .background(Theme.background)
        }
        .withDestinations()
        .task(id: query) {
            guard mode == "library" else { return }
            guard !query.isEmpty else { result = .init(); return }
            try? await Task.sleep(for: .milliseconds(300))      // wait until typing pauses
            guard !Task.isCancelled, settings.config.isComplete else { return }
            searching = true
            defer { searching = false }
            do {
                result = try await app.client.search(query)
                error = nil
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private var modePicker: some View {
        HStack(spacing: 8) {
            chip("Your Library", icon: nil, on: mode == "library") { mode = "library" }
            chip("Download", icon: "arrow.down.circle", on: mode == "get") { mode = "get" }
            Spacer()
            if mode == "get" {
                NavigationLink(value: ListRoute.getQueue) {
                    Label("Queue", systemImage: "icloud.and.arrow.down").font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(Theme.accent)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .sensoryFeedback(.selection, trigger: mode)
        .onChange(of: mode) { _, m in if m == "library" { result = .init(); Task { await searchLibraryAgain() } } }
    }

    private var kindPicker: some View {
        HStack(spacing: 8) {
            chip("Songs", icon: nil, on: kind == "song") { kind = "song" }
            chip("Albums", icon: nil, on: kind == "album") { kind = "album" }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 4)
    }

    private func chip(_ title: String, icon: String?, on: Bool, _ tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            HStack(spacing: 5) {
                if let icon { Image(systemName: icon) }
                Text(title)
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(on ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.white.opacity(0.1)), in: Capsule())
            .foregroundStyle(on ? Color.black : Color.white)
        }
        .buttonStyle(PressScale())
    }

    private func searchLibraryAgain() async {
        guard !query.isEmpty, settings.config.isComplete else { return }
        searching = true
        defer { searching = false }
        result = (try? await app.client.search(query)) ?? .init()
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.tertiary)
            TextField(mode == "get" ? (kind == "album" ? "Album or artist to download" : "Song to download (add the artist)") : "Songs, albums, artists",
                      text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.tertiary) }
            }
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(Theme.background)
    }
}
