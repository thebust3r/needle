import SwiftUI

/// Wrapped: your month, year or all-time listening, as a stack of cards. Same as the web player's Wrapped page.
struct WrappedView: View {
    @Environment(Player.self) private var player
    @State var period: WrappedPeriod
    @State private var stats: WrappedStats?
    @State private var all: [PlayRecord] = []

    static let brand = LinearGradient(colors: [Color(red: 0.48, green: 0.30, blue: 1), Color(red: 0.75, green: 0.25, blue: 0.85),
                                               Color(red: 1, green: 0.36, blue: 0.56)], startPoint: .topLeading, endPoint: .bottomTrailing)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ScreenTitle(text: "Wrapped")
                Picker("Period", selection: $period) {
                    ForEach(WrappedPeriod.allCases) { p in Text(Wrapped.range(p).label).tag(p) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 20)
                if let w = stats {
                    if w.plays < 3 {
                        StatusView(icon: "sparkles", title: "Not much to show yet",
                                   message: "Play some music and your Wrapped fills in here: top songs, artists, your listening personality and more.")
                            .padding(.top, 40)
                    } else {
                        cards(w).padding(.horizontal, 20)
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 60)
                }
            }
            .padding(.bottom, 30)
        }
        .background(Theme.background)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            all = await PlayHistory.shared.everything()
            stats = Wrapped.compute(all, period: period)
        }
        .onChange(of: period) { _, p in withAnimation(.easeInOut(duration: 0.25)) { stats = Wrapped.compute(all, period: p) } }
    }

    private func hoursText(_ m: Int) -> (String, String) { m >= 120 ? ("\(Int((Double(m) / 60).rounded()))", "hours") : ("\(m)", "minutes") }

    @ViewBuilder private func cards(_ w: WrappedStats) -> some View {
        let big = hoursText(w.minutes)
        // the hero
        VStack(alignment: .leading, spacing: 8) {
            Text(w.period == .all ? "ALL TIME ON PLATTER" : "YOUR \(w.label.uppercased()) SO FAR")
                .font(.caption.weight(.bold)).tracking(0.6).opacity(0.85)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(big.0).font(.system(size: 72, weight: .heavy).width(.expanded)).minimumScaleFactor(0.5).lineLimit(1)
                Text(big.1).font(.system(size: 22, weight: .heavy).width(.expanded))
            }
            Text("of music: \(w.plays) plays, \(w.songs) different songs by \(w.artists) artists.")
                .font(.subheadline).opacity(0.92)
            Button {
                player.play(w.playlist.map { Track(song: Song(id: $0.id, title: $0.title, album: $0.album, artist: $0.artist,
                                                                albumId: $0.albumId, coverArt: $0.coverArt, duration: Int($0.duration))) })
            } label: {
                Label("Play your top songs", systemImage: "play.fill").font(.subheadline.weight(.bold))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.white, in: Capsule()).foregroundStyle(.black)
            }
            .buttonStyle(PressScale())
            .padding(.top, 6)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Self.brand, in: RoundedRectangle(cornerRadius: 20, style: .continuous))

        card("Top Songs") {
            ForEach(Array(w.topSongs.enumerated()), id: \.element.id) { i, s in
                row(i + 1, cover: s.coverArt ?? s.albumId, round: false, title: s.title, sub: s.artist,
                    trailing: "\(s.plays) play\(s.plays == 1 ? "" : "s")")
            }
        }
        card("Top Artists") {
            ForEach(Array(w.topArtists.enumerated()), id: \.element.id) { i, a in
                let h = hoursText(Int(a.minutes.rounded()))
                row(i + 1, cover: a.coverArt, round: true, title: a.name, sub: "\(h.0) \(h.1)", trailing: nil)
            }
        }
        if let album = w.topAlbum {
            let h = hoursText(Int(album.minutes.rounded()))
            card("Album on Repeat", center: true) {
                ArtworkView(track: nil, coverArt: album.coverArt ?? album.albumId, size: 220, corner: 14)
                    .shadow(color: .black.opacity(0.45), radius: 18, y: 12)
                Text(album.name).font(.headline).padding(.top, 8)
                Text("\(album.artist) · \(h.0) \(h.1)").font(.caption).foregroundStyle(Theme.secondary)
            }
        }
        if let p = w.persona {
            VStack(alignment: .leading, spacing: 6) {
                Text("Your listening personality").font(.caption.weight(.semibold)).foregroundStyle(Theme.secondary)
                Text(p.name).font(.system(size: 34, weight: .heavy).width(.expanded))
                    .foregroundStyle(LinearGradient(colors: [Theme.accent, Color(red: 0.66, green: 0.55, blue: 1)], startPoint: .leading, endPoint: .trailing))
                Text("\(Int((p.share * 100).rounded()))% \(p.line).").font(.subheadline).foregroundStyle(Theme.secondary)
                let maxH = max(1, w.hours.max() ?? 1)
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(0..<24, id: \.self) { h in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(LinearGradient(colors: [Color(red: 0.66, green: 0.55, blue: 1), Theme.accent], startPoint: .top, endPoint: .bottom))
                            .frame(height: max(3, 70 * CGFloat(w.hours[h]) / CGFloat(maxH)))
                    }
                }
                .frame(height: 70, alignment: .bottom)
                .padding(.top, 8)
                .accessibilityHidden(true)
                HStack {
                    Text("12a"); Spacer(); Text("6a"); Spacer(); Text("12p"); Spacer(); Text("6p"); Spacer(); Text("12a")
                }
                .font(.caption2).foregroundStyle(Theme.tertiary)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LinearGradient(colors: [Color(red: 0.11, green: 0.11, blue: 0.23), Color(red: 0.06, green: 0.07, blue: 0.11)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            tile("Longest streak", "\(w.longestStreak)", "day\(w.longestStreak == 1 ? "" : "s") in a row")
            if let b = w.biggestDay {
                let h = hoursText(b.minutes)
                tile("Biggest day", h.0, "\(h.1) on \(b.at.formatted(.dateTime.weekday(.wide).month(.wide).day()))")
            }
            tile("New artists", "\(w.newArtists.count)", w.newArtists.names.isEmpty ? "found something new" : w.newArtists.names.joined(separator: ", "))
            tile("Slowed down", "\(Int((w.slowedShare * 100).rounded()))%",
                 w.favoriteSpeed.flatMap { ScrewSpeed(rawValue: $0)?.label }.map { "mostly \($0)" } ?? "of your listening")
        }
    }

    private func card<C: View>(_ title: String, center: Bool = false, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: center ? .center : .leading, spacing: 8) {
            Text(title).font(.system(size: 20, weight: .heavy).width(.expanded)).frame(maxWidth: .infinity, alignment: center ? .center : .leading)
            content()
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func row(_ n: Int, cover: String?, round: Bool, title: String, sub: String, trailing: String?) -> some View {
        HStack(spacing: 12) {
            Text("\(n)").font(.headline).foregroundStyle(Theme.accent).frame(width: 18)
            ArtworkView(track: nil, coverArt: cover, size: 48, corner: round ? 24 : 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(sub).font(.caption).foregroundStyle(Theme.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if let trailing { Text(trailing).font(.caption).foregroundStyle(Theme.secondary) }
        }
        .padding(.vertical, 3)
    }

    private func tile(_ label: String, _ value: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(Theme.secondary)
            Text(value).font(.system(size: 30, weight: .heavy).width(.expanded)).lineLimit(1).minimumScaleFactor(0.6)
            Text(sub).font(.caption).foregroundStyle(Theme.secondary).lineLimit(2)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// The Home banner: your month so far (shows once there's enough listening).
struct WrappedBanner: View {
    @State private var stats: WrappedStats?
    var body: some View {
        Group {
            if let w = stats, w.plays >= 10 {
                NavigationLink(value: WrappedRoute(period: .month)) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Label("WRAPPED", systemImage: "sparkles").font(.caption.weight(.bold)).opacity(0.85)
                            Text("Your \(w.label) so far").font(.system(size: 19, weight: .heavy).width(.expanded))
                            let h = w.minutes >= 120 ? "\(Int((Double(w.minutes) / 60).rounded())) hours" : "\(w.minutes) minutes"
                            Text(h + (w.topArtists.first.map { " · \($0.name) on top" } ?? "")).font(.footnote).opacity(0.9).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.headline)
                    }
                    .foregroundStyle(.white)
                    .padding(16)
                    .background(WrappedView.brand, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .shadow(color: Color(red: 0.48, green: 0.30, blue: 1).opacity(0.3), radius: 14, y: 8)
                }
                .buttonStyle(PressScale())
                .padding(.horizontal, 20)
                .transition(.opacity)
            }
        }
        .task { stats = Wrapped.compute(await PlayHistory.shared.everything(), period: .month) }
    }
}
