import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var app
    @Environment(Player.self) private var player
    @Environment(AppSettings.self) private var settings
    @Environment(LocalLibrary.self) private var local
    let openTab: (AppTab) -> Void

    @State private var recent = Loader<[Album]>()
    @State private var added = Loader<[Album]>()
    @State private var frequent = Loader<[Album]>()
    @State private var random = Loader<[Album]>()
    @State private var shuffling = false

    private var greeting: String {
        switch Calendar.current.component(.hour, from: .now) {
        case 5..<12: return "Morning"
        case 12..<17: return "Afternoon"
        case 17..<22: return "Evening"
        default: return "Late night"
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(greeting).font(.subheadline.weight(.medium)).foregroundStyle(Theme.secondary)
                    Text("Listen Now").font(Theme.title(32))
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)

                if settings.config.isComplete {
                    shuffleCard
                    if let err = recent.error, recent.value == nil {
                        StatusView(icon: "wifi.exclamationmark", title: "Can't reach your server", message: err) {
                            Task { await loadAll() }
                        }
                    }
                    shelf("Jump Back In", recent)
                    shelf("Recently Added", added)
                    shelf("On Repeat", frequent)
                    shelf("Rediscover", random)
                } else {
                    connectCard
                }

                if !local.tracks.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(title: "On This iPhone") { openTab(.library) }
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 14) {
                                ForEach(local.albums.prefix(12)) { a in
                                    NavigationLink(value: LocalAlbumRoute(name: a.name, artist: a.artist)) {
                                        VStack(alignment: .leading, spacing: 6) {
                                            ArtworkView(track: a.tracks.first, size: 140, corner: 10)
                                            Text(a.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                                            Text(a.artist).font(.caption).foregroundStyle(Theme.secondary).lineLimit(1)
                                        }
                                        .frame(width: 140)
                                    }
                                    .buttonStyle(.plain)
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
        .toolbar(.hidden, for: .navigationBar)
        .withDestinations()
        .refreshable { await loadAll() }
        .task(id: settings.config) { await loadAll() }
    }

    private var shuffleCard: some View {
        Button {
            Task {
                shuffling = true
                defer { shuffling = false }
                if let songs = try? await app.client.randomSongs(100), !songs.isEmpty {
                    player.play(songs.map(Track.init(song:)))
                }
            }
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(Theme.accent)
                    if shuffling { ProgressView().tint(.black) }
                    else { Image(systemName: "shuffle").font(.title3.weight(.bold)).foregroundStyle(.black) }
                }
                .frame(width: 50, height: 50)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Shuffle Everything").font(.headline)
                    Text("100 random songs from your library").font(.caption).foregroundStyle(Theme.secondary)
                }
                Spacer()
            }
            .padding(14)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(.horizontal, 20)
        }
        .buttonStyle(PressScale())
    }

    private var connectCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Connect your music server").font(.headline)
            Text("Add your Navidrome address in Settings to stream everything on your NAS.")
                .font(.subheadline).foregroundStyle(Theme.secondary)
            Button("Open Settings") { openTab(.settings) }
                .buttonStyle(FilledPill(fill: Theme.accent, text: .black))
                .font(.subheadline.weight(.semibold))
                .padding(.top, 4)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.horizontal, 20)
    }

    @ViewBuilder
    private func shelf(_ title: String, _ loader: Loader<[Album]>) -> some View {
        if let albums = loader.value, !albums.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: title)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(albums) { album in
                            NavigationLink(value: album) { AlbumCard(album: album, size: 150) }
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 20)
                }
            }
        }
    }

    private func loadAll() async {
        guard settings.config.isComplete else { return }
        let c = app.client
        app.refreshArtworkClient()
        async let a: Void = recent.load { try await c.albums("recent", size: 20) }
        async let b: Void = added.load { try await c.albums("newest", size: 20) }
        async let f: Void = frequent.load { try await c.albums("frequent", size: 20) }
        async let r: Void = random.load { try await c.albums("random", size: 20) }
        _ = await (a, b, f, r)
    }
}
