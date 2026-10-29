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
            VStack(alignment: .leading, spacing: 26) {
                HomeHeader(shuffle: settings.config.isComplete ? { Task { await shuffleAll() } } : nil, shuffling: shuffling)

                if settings.config.isComplete {
                    ContinueCard()
                    if let err = recent.error, recent.value == nil {
                        StatusView(icon: "wifi.exclamationmark", title: "Can't reach your server", message: err) {
                            Task { await loadAll(force: true) }
                        }
                    }
                    quickPicks
                    madeForYou
                    shelf("New in Your Library", freshAlbums)
                    WrappedBanner()
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
                                            ArtworkView(track: a.tracks.first, size: 128, corner: 10)
                                            Text(a.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                                            Text(a.artist).font(.caption).foregroundStyle(Theme.secondary).lineLimit(1)
                                        }
                                        .frame(width: 128)
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
                SectionHeader(title: "Made for You")
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        if mixes.mixes.isEmpty {
                            ForEach(0..<3, id: \.self) { _ in MixCardPlaceholder(size: 136) }
                        }
                        ForEach(mixes.mixes) { mix in
                            NavigationLink(value: MixRoute(mix: mix)) { MixCard(mix: mix, size: 136, showSubtitle: false) }
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

    /// Up to six things you've been playing (recent first, then favorites), no repeats.
    private var picks: [Album] {
        var seen = Set<String>(), out: [Album] = []
        for a in (recent.value ?? []) + (frequent.value ?? []) where out.count < 6 && !seen.contains(a.id) { seen.insert(a.id); out.append(a) }
        return out
    }
    /// New music that isn't already in the quick picks.
    private var freshAlbums: [Album] {
        let shown = Set(picks.map(\.id))
        return Array((added.value ?? []).filter { !shown.contains($0.id) }.prefix(12))
    }

    /// What you've been playing, as a tidy grid of small tiles (instead of two big shelves).
    @ViewBuilder private var quickPicks: some View {
        let list = picks
        if !list.isEmpty {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(list) { album in
                    NavigationLink(value: album) { QuickPickTile(album: album) }
                        .buttonStyle(PressScale())
                        .zoomSource(album.id)
                        .shelfAppear()
                }
            }
            .padding(.horizontal, 20)
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private func shelf(_ title: String, _ albums: [Album]) -> some View {
        if !albums.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: title) { openTab(.library) }
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(albums) { album in
                            NavigationLink(value: album) { AlbumCard(album: album, size: 128) }
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

// MARK: - Header: one quiet line (day · time · weather), then the greeting and a shuffle button

struct HomeHeader: View {
    var shuffle: (() -> Void)?
    var shuffling = false
    @State private var weather = WeatherStore.shared

    var body: some View {
        TimelineView(.everyMinute) { ctx in
            let now = ctx.date
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(now.formatted(.dateTime.weekday(.wide))).foregroundStyle(Theme.accent)
                    Text("·").opacity(0.5)
                    Text(now.formatted(date: .omitted, time: .shortened)).monospacedDigit().contentTransition(.numericText())
                    if weather.showWeather, let w = weather.now {
                        Text("·").opacity(0.5)
                        Image(systemName: w.symbol).symbolRenderingMode(.multicolor)
                        Text("\(w.temp)°").monospacedDigit()
                            .accessibilityLabel("\(w.temp) degrees, \(w.words), \(w.place)")
                    }
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
                HStack(alignment: .center) {
                    Text(Self.greeting(now)).font(Theme.title(32)).contentTransition(.opacity)
                    Spacer()
                    if let shuffle {
                        Button(action: shuffle) {
                            Group {
                                if shuffling { ProgressView().controlSize(.small).tint(.black) }
                                else { Image(systemName: "shuffle").font(.system(size: 17, weight: .bold)) }
                            }
                            .frame(width: 42, height: 42)
                            .background(Theme.accent, in: Circle())
                            .foregroundStyle(.black)
                        }
                        .buttonStyle(PressScale())
                        .accessibilityLabel("Shuffle all your music")
                        .sensoryFeedback(.impact(weight: .light), trigger: shuffling)
                    }
                }
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
    var showSubtitle = true
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            MixArtwork(mix: mix, size: size)
            if showSubtitle {
                Text(mix.subtitle).font(.caption).foregroundStyle(Theme.secondary).lineLimit(2)
                    .frame(width: size, alignment: .leading)
            }
        }
        .frame(width: size)
        .accessibilityElement(children: .combine)
        .accessibilityHint(mix.subtitle)
    }
}

/// A small tile in the quick-picks grid: cover on the left, name and artist.
struct QuickPickTile: View {
    let album: Album
    var body: some View {
        HStack(spacing: 10) {
            ArtworkView(track: nil, coverArt: album.coverArt ?? album.id, size: 56, corner: 0)
            VStack(alignment: .leading, spacing: 1) {
                Text(album.name).font(.footnote.weight(.semibold)).lineLimit(1)
                Text(album.artist ?? "").font(.caption2).foregroundStyle(Theme.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .frame(height: 56)
        .background(.white.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
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
    var size: CGFloat = 160
    @State private var glow = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface).frame(width: size, height: size)
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
