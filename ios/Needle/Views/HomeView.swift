import SwiftUI

struct MixRoute: Hashable { let mix: Mix }

struct HomeView: View {
    @Environment(AppModel.self) private var app
    @Environment(Player.self) private var player
    @Environment(AppSettings.self) private var settings
    @Environment(LocalLibrary.self) private var local
    let openTab: (AppTab) -> Void

    @State private var recent = Loader<[Album]>()
    @State private var added = Loader<[Album]>()
    @State private var frequent = Loader<[Album]>()
    @State private var mixes = MixStore.shared
    @State private var shuffling = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                HomeHeader(shuffle: settings.config.isComplete ? { Task { await shuffleAll() } } : nil, shuffling: shuffling)

                if settings.config.isComplete {
                    ContinueCard()
                    if let err = recent.error, recent.value == nil {
                        StatusView(icon: "wifi.exclamationmark", title: "Can't reach your server", message: err) {
                            Task { await loadAll(force: true) }
                        }
                    }
                    madeForYou
                    shelf("Recently Played", recent)
                    shelf("On Repeat", frequent)
                    shelf("Recently Added", added)
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
                                    .buttonStyle(PressScale())
                                    .shelfAppear()
                                }
                            }
                            .padding(.horizontal, 20)
                            .scrollTargetLayout()
                        }
                        .scrollTargetBehavior(.viewAligned)
                    }
                }
            }
            .padding(.bottom, 24)
        }
        .background(Theme.background)
        .toolbar(.hidden, for: .navigationBar)
        .withDestinations()
        .refreshable { await loadAll(force: true) }
        .task(id: settings.config) { await loadAll(force: false) }
    }

    // MARK: Made for You

    @ViewBuilder private var madeForYou: some View {
        if !mixes.mixes.isEmpty || mixes.loading {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    SectionHeader(title: "Made for You")
                    Text("New mixes every morning, from your own music")
                        .font(.caption).foregroundStyle(Theme.secondary).padding(.horizontal, 20)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        if mixes.mixes.isEmpty {
                            ForEach(0..<3, id: \.self) { _ in MixCardPlaceholder() }
                        }
                        ForEach(mixes.mixes) { mix in
                            NavigationLink(value: MixRoute(mix: mix)) { MixCard(mix: mix) }
                                .buttonStyle(PressScale())
                                .zoomSource(mix.id)
                                .shelfAppear()
                        }
                    }
                    .padding(.horizontal, 20)
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.viewAligned)
                .animation(.spring(response: 0.5, dampingFraction: 0.85), value: mixes.mixes.map(\.id))
            }
        }
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
                                .buttonStyle(PressScale())
                                .zoomSource(album.id)
                                .shelfAppear()
                        }
                    }
                    .padding(.horizontal, 20)
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.viewAligned)
            }
            .transition(.opacity.combined(with: .offset(y: 12)))
        }
    }

    private func shuffleAll() async {
        shuffling = true
        defer { shuffling = false }
        if let songs = try? await app.client.randomSongs(100), !songs.isEmpty {
            player.play(songs.map(Track.init(song:)))
        }
    }

    private func loadAll(force: Bool) async {
        guard settings.config.isComplete else { return }
        let c = app.client
        app.refreshArtworkClient()
        async let w: Void = WeatherStore.shared.refresh(force: force)
        async let m: Void = mixes.refresh(client: c, force: force)
        async let a: Void = recent.load { try await c.albums("recent", size: 20) }
        async let b: Void = added.load { try await c.albums("newest", size: 20) }
        async let f: Void = frequent.load { try await c.albums("frequent", size: 20) }
        _ = await (a, b, f)
        _ = await (w, m)
    }
}

// MARK: - Header: day, time, greeting, weather

struct HomeHeader: View {
    var shuffle: (() -> Void)?
    var shuffling = false
    @State private var weather = WeatherStore.shared

    var body: some View {
        TimelineView(.everyMinute) { ctx in
            let now = ctx.date
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center) {
                    Text(now.formatted(.dateTime.weekday(.wide).month(.wide).day()).uppercased())
                        .font(.caption.weight(.bold)).tracking(1.2)
                        .foregroundStyle(Theme.accent)
                    Spacer()
                    if weather.showWeather, let w = weather.now {
                        HStack(spacing: 6) {
                            Image(systemName: w.symbol).symbolRenderingMode(.multicolor)
                            Text("\(w.temp)°").monospacedDigit()
                        }
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.white.opacity(0.08), in: Capsule())
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                        .accessibilityLabel("\(w.temp) degrees, \(w.words), \(w.place)")
                    }
                }
                Text(Self.greeting(now)).font(Theme.title(32))
                    .contentTransition(.opacity)
                HStack(spacing: 8) {
                    Text(now.formatted(date: .omitted, time: .shortened))
                        .font(.title3.weight(.semibold).monospacedDigit())
                        .contentTransition(.numericText())
                    if weather.showWeather, let w = weather.now {
                        Text("· \(w.words) in \(w.place)").font(.subheadline).foregroundStyle(Theme.secondary).lineLimit(1)
                    }
                    Spacer()
                    if let shuffle {
                        Button(action: shuffle) {
                            HStack(spacing: 6) {
                                if shuffling { ProgressView().controlSize(.small).tint(.black) }
                                else { Image(systemName: "shuffle") }
                                Text("Shuffle")
                            }
                            .font(.subheadline.weight(.bold))
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(Theme.accent, in: Capsule())
                            .foregroundStyle(.black)
                        }
                        .buttonStyle(PressScale())
                        .sensoryFeedback(.impact(weight: .light), trigger: shuffling)
                    }
                }
                .foregroundStyle(.white.opacity(0.85))
            }
            .animation(.easeInOut(duration: 0.4), value: weather.now)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    static func greeting(_ d: Date) -> String {
        switch Calendar.current.component(.hour, from: d) {
        case 5..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        case 17..<22: return "Good evening"
        default: return "Up late"
        }
    }
}

// MARK: - Continue Listening

struct ContinueCard: View {
    @Environment(Player.self) private var player

    var body: some View {
        if let t = player.current, !player.isPlaying {
            Button { player.resume() } label: {
                HStack(spacing: 14) {
                    ArtworkView(track: t, size: 64, corner: 10)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("CONTINUE LISTENING").font(.caption2.weight(.bold)).tracking(1).foregroundStyle(Theme.accent)
                        Text(t.title).font(.headline).lineLimit(1)
                        Text(t.artist).font(.subheadline).foregroundStyle(Theme.secondary).lineLimit(1)
                        ProgressView(value: player.progress).tint(.white.opacity(0.85)).scaleEffect(y: 0.6)
                    }
                    Image(systemName: "play.circle.fill").font(.system(size: 38)).foregroundStyle(Theme.accent)
                }
                .padding(12)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.line))
                .padding(.horizontal, 20)
            }
            .buttonStyle(PressScale())
            .transition(.opacity.combined(with: .scale(scale: 0.97)))
        }
    }
}

// MARK: - Mix cards and the mix page

struct MixCard: View {
    let mix: Mix
    var size: CGFloat = 160
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            MixArtwork(mix: mix, size: size)
            Text(mix.subtitle).font(.caption).foregroundStyle(Theme.secondary).lineLimit(2)
                .frame(width: size, alignment: .leading)
        }
        .frame(width: size)
    }
}

/// Four covers from the mix, washed in the mix's color, with its name on top.
struct MixArtwork: View {
    let mix: Mix
    let size: CGFloat
    var body: some View {
        let covers = mix.covers
        let tint = Color(hue: mix.hue, saturation: 0.75, brightness: 0.85)
        ZStack(alignment: .bottomLeading) {
            Group {
                if covers.count >= 4 {
                    Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                        GridRow { cover(covers[0]); cover(covers[1]) }
                        GridRow { cover(covers[2]); cover(covers[3]) }
                    }
                } else if let c = covers.first {
                    ArtworkView(track: nil, coverArt: c, size: size, corner: 0)
                } else {
                    Color(hue: mix.hue, saturation: 0.5, brightness: 0.3)
                }
            }
            .frame(width: size, height: size)
            LinearGradient(colors: [tint.opacity(0.15), tint.opacity(0.55), .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 2) {
                Image(systemName: icon).font(.caption.weight(.bold)).foregroundStyle(tint)
                Text(mix.title).font(.system(size: size * 0.11, weight: .heavy).width(.expanded)).lineLimit(2)
                    .minimumScaleFactor(0.7)
            }
            .foregroundStyle(.white)
            .padding(10)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.35), radius: 10, y: 6)
    }

    private var icon: String {
        switch mix.kind {
        case .daily: return "sparkles"
        case .rediscover: return "arrow.counterclockwise"
        case .fresh: return "leaf.fill"
        case .timeOfDay: return "clock.fill"
        case .onThisDay: return "calendar"
        }
    }

    private func cover(_ id: String) -> some View {
        ArtworkView(track: nil, coverArt: id, size: size / 2, corner: 0)
    }
}

struct MixCardPlaceholder: View {
    @State private var glow = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface).frame(width: 160, height: 160)
            RoundedRectangle(cornerRadius: 3).fill(Theme.surface).frame(width: 110, height: 10)
        }
        .opacity(glow ? 0.5 : 1)
        .onAppear { withAnimation(.easeInOut(duration: 0.9).repeatForever()) { glow = true } }
    }
}

struct MixView: View {
    @Environment(AppModel.self) private var app
    @Environment(Player.self) private var player
    let mix: Mix
    @State private var saved = false
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        let tracks = mix.songs.map(Track.init(song:))
        let tint = Color(hue: mix.hue, saturation: 0.6, brightness: 0.5)
        ScrollView {
            VStack(spacing: 16) {
                MixArtwork(mix: mix, size: 230)
                    .padding(.top, 12)
                VStack(spacing: 4) {
                    Text(mix.title).font(Theme.title(26))
                    Text(mix.subtitle).font(.subheadline).foregroundStyle(Theme.secondary).multilineTextAlignment(.center)
                    Text("\(tracks.count) songs · \(formatDuration(Int(tracks.reduce(0) { $0 + $1.duration })))")
                        .font(.caption).foregroundStyle(Theme.tertiary)
                }
                .padding(.horizontal, 20)
                PlayButtons(play: { player.play(tracks) }, shuffle: { player.play(tracks, shuffle: true) })
                Button {
                    Task { await save() }
                } label: {
                    Label(saved ? "Saved to Playlists" : "Save as Playlist", systemImage: saved ? "checkmark" : "plus")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.bordered).tint(.white)
                .disabled(saved || saving)
                .sensoryFeedback(.success, trigger: saved)
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
                LazyVStack(spacing: 0) {
                    ForEach(Array(tracks.enumerated()), id: \.offset) { i, t in
                        TrackRow(track: t) { player.play(tracks, startAt: i) }
                    }
                }
            }
            .padding(.bottom, 20)
        }
        .background {
            LinearGradient(colors: [tint, Theme.background], startPoint: .top, endPoint: .center).ignoresSafeArea()
        }
        .navigationBarTitleDisplayMode(.inline)
        .zoomDestination(mix.id)
    }

    private func save() async {
        saving = true
        defer { saving = false }
        let name = "\(mix.title) · \(Date.now.formatted(.dateTime.month(.abbreviated).day()))"
        do {
            try await app.client.createPlaylist(name: name, songIds: mix.songs.map(\.id))
            withAnimation { saved = true }
        } catch { self.error = error.localizedDescription }
    }
}

// MARK: - Motion helpers

private struct ZoomNamespaceKey: EnvironmentKey { static let defaultValue: Namespace.ID? = nil }
extension EnvironmentValues {
    var zoomNamespace: Namespace.ID? {
        get { self[ZoomNamespaceKey.self] }
        set { self[ZoomNamespaceKey.self] = newValue }
    }
}

extension View {
    /// The card a page grows out of (iOS 18 and later; older versions slide as before).
    func zoomSource(_ id: String) -> some View { modifier(ZoomSource(id: id)) }
    /// The page that grows out of a card.
    func zoomDestination(_ id: String) -> some View { modifier(ZoomDestination(id: id)) }
    /// Cards ease in and settle as they scroll onto the screen.
    func shelfAppear() -> some View {
        scrollTransition(.interactive, axis: .horizontal) { content, phase in
            content
                .scaleEffect(phase.isIdentity ? 1 : 0.92)
                .opacity(phase.isIdentity ? 1 : 0.6)
        }
    }
}

private struct ZoomSource: ViewModifier {
    @Environment(\.zoomNamespace) private var ns
    let id: String
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *), let ns {
            content.matchedTransitionSource(id: id, in: ns)
        } else {
            content
        }
    }
}

private struct ZoomDestination: ViewModifier {
    @Environment(\.zoomNamespace) private var ns
    let id: String
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *), let ns {
            content.navigationTransition(.zoom(sourceID: id, in: ns))
        } else {
            content
        }
    }
}
