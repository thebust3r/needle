import SwiftUI

/// Cover art from the music catalog (a web address, not your server).
struct CatalogArt: View {
    let url: String?
    var size: CGFloat = 46
    var corner: CGFloat = 6
    var body: some View {
        AsyncImage(url: url.flatMap(URL.init(string:))) { phase in
            if let img = phase.image {
                img.resizable().scaledToFill()
            } else {
                ZStack {
                    Theme.surface
                    Image(systemName: "music.note").foregroundStyle(Theme.tertiary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
}

/// Plays a song you already have, from a catalog result.
@MainActor func playOwned(_ songId: String, app: AppModel, player: Player) async {
    do {
        if let s = try await app.client.song(songId) { player.play([Track(song: s)]) }
    } catch {
        player.errorMessage = error.localizedDescription
    }
}

/// One catalog song: download button, or a check if it's already in your library.
struct CatalogSongRow: View {
    @Environment(AppModel.self) private var app
    @Environment(Player.self) private var player
    let song: CatalogSong
    var showArt = true
    @Binding var sent: Set<String>

    var body: some View {
        let have = song.songId != nil
        let isSent = sent.contains(song.id)
        Button {
            if let id = song.songId { Task { await playOwned(id, app: app, player: player) } } else if !isSent { get() }
        } label: {
            HStack(spacing: 12) {
                if showArt { CatalogArt(url: song.cover) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(song.title).lineLimit(1).foregroundStyle(.white)
                    Text([song.artist, song.album ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(Theme.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                if let d = song.duration, d > 0 {
                    Text(formatTime(Double(d))).font(.caption.monospacedDigit()).foregroundStyle(Theme.tertiary)
                }
                Image(systemName: have || isSent ? "checkmark.circle.fill" : "arrow.down.circle")
                    .font(.title2)
                    .foregroundStyle(have || isSent ? Theme.accent : .white)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 36)
                    .accessibilityLabel(have ? "In your library" : isSent ? "Downloading" : "Download")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
        .sensoryFeedback(.success, trigger: isSent)
    }

    private func get() {
        sent.insert(song.id)
        let h = app.helper, s = song
        Task {
            do {
                let n = try await h.get([s])
                player.errorMessage = n > 0 ? "Downloading “\(s.title)”" : "Already on the way"
            } catch {
                sent.remove(s.id)
                player.errorMessage = error.localizedDescription
            }
        }
    }
}

/// Search results in Search's "Download" mode.
struct GetMusicResults: View {
    @Environment(AppModel.self) private var app
    let query: String
    let kind: String          // "song" or "album"
    @State private var songs: [CatalogSong] = []
    @State private var albums: [CatalogAlbum] = []
    @State private var loading = false
    @State private var error: String?
    @State private var sent: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if query.isEmpty {
                StatusView(icon: "icloud.and.arrow.down", title: "Get new music",
                           message: "Type a song, artist or album. Pick one and Platter downloads it to your NAS.")
                    .padding(.top, 30)
            } else if let error {
                StatusView(icon: "exclamationmark.triangle", title: "Can't search right now", message: error)
            } else if loading && songs.isEmpty && albums.isEmpty {
                ProgressView().frame(maxWidth: .infinity).padding(30)
            } else if kind == "album" {
                if albums.isEmpty && !loading {
                    StatusView(icon: "questionmark.circle", title: "No albums found", message: "Try the artist's name too.")
                }
                LazyVStack(spacing: 0) {
                    ForEach(albums) { a in
                        NavigationLink(value: a) {
                            HStack(spacing: 12) {
                                CatalogArt(url: a.cover, size: 56, corner: 8)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(a.title).lineLimit(1).foregroundStyle(.white)
                                    Text(albumLine(a))
                                        .font(.caption).foregroundStyle(Theme.secondary).lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Theme.tertiary)
                            }
                            .padding(.horizontal, 20).padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(RowButtonStyle())
                    }
                }
            } else {
                if songs.isEmpty && !loading {
                    StatusView(icon: "questionmark.circle", title: "Nothing found", message: "Try adding the artist's name.")
                }
                LazyVStack(spacing: 0) {
                    ForEach(Array(songs.enumerated()), id: \.offset) { _, s in CatalogSongRow(song: s, sent: $sent) }
                }
            }
        }
        .task(id: "\(kind)|\(query)") {
            guard !query.isEmpty else { songs = []; albums = []; return }
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            loading = true
            defer { loading = false }
            do {
                if kind == "album" { albums = try await app.helper.findAlbums(query) } else { songs = try await app.helper.findSongs(query) }
                error = nil
            } catch is CancellationError {
            } catch let e as URLError where e.code == .cancelled {
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

private func albumLine(_ a: CatalogAlbum) -> String {
    var parts = [a.artist, a.kind]
    if let n = a.tracks, n > 0 { parts.append("\(n) songs") }
    return parts.joined(separator: " · ")
}

/// An album from the catalog: its songs (checks on the ones you have) and Download Album.
struct CatalogAlbumView: View {
    @Environment(AppModel.self) private var app
    @Environment(Player.self) private var player
    let album: CatalogAlbum
    @State private var loader = Loader<CatalogAlbumDetail>()
    @State private var sent: Set<String> = []

    var body: some View {
        let tracks = loader.value?.tracks ?? []
        let missing = tracks.filter { $0.songId == nil && !sent.contains($0.id) }
        ScrollView {
            VStack(spacing: 16) {
                CatalogArt(url: (loader.value?.cover ?? album.cover)?.replacingOccurrences(of: "250x250", with: "500x500"), size: 220, corner: 14)
                    .shadow(color: .black.opacity(0.5), radius: 24, y: 12)
                    .padding(.top, 12)
                VStack(spacing: 4) {
                    Text(album.title).font(Theme.title(22)).multilineTextAlignment(.center)
                    Text(album.artist).font(.title3.weight(.medium)).foregroundStyle(Theme.accent)
                    if let y = loader.value?.year, !y.isEmpty {
                        Text("\(y) · \(tracks.count) songs").font(.caption).foregroundStyle(Theme.secondary)
                    }
                }
                .padding(.horizontal, 20)
                if !tracks.isEmpty {
                    Button { getAll(missing) } label: {
                        Label(missing.isEmpty ? "All in your library or on the way"
                                : missing.count == tracks.count ? "Download Album" : "Download \(missing.count) Missing",
                              systemImage: missing.isEmpty ? "checkmark" : "arrow.down.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(FilledPill(fill: missing.isEmpty ? Color.white.opacity(0.1) : Theme.accent, text: missing.isEmpty ? .white : .black))
                    .font(.headline)
                    .padding(.horizontal, 20)
                    .disabled(missing.isEmpty)
                }
                if loader.value == nil {
                    if let e = loader.error { StatusView(icon: "exclamationmark.triangle", title: "Couldn't load", message: e) } else { ProgressView().padding(30) }
                }
                LazyVStack(spacing: 0) {
                    ForEach(Array(tracks.enumerated()), id: \.offset) { _, t in CatalogSongRow(song: t, showArt: false, sent: $sent) }
                }
            }
            .padding(.bottom, 24)
        }
        .background(Theme.background)
        .navigationBarTitleDisplayMode(.inline)
        .task { await loader.load { try await app.helper.catalogAlbum(album.id) } }
    }

    private func getAll(_ songs: [CatalogSong]) {
        for s in songs { sent.insert(s.id) }
        let h = app.helper
        Task {
            do {
                let n = try await h.get(songs)
                player.errorMessage = "Downloading \(n) song\(n == 1 ? "" : "s")"
            } catch {
                for s in songs { sent.remove(s.id) }
                player.errorMessage = error.localizedDescription
            }
        }
    }
}

/// Everything you asked to download to the NAS, newest first, updating live.
struct DownloadQueueView: View {
    @Environment(AppModel.self) private var app
    @Environment(Player.self) private var player
    @State private var job: ImportJob?
    @State private var error: String?

    var body: some View {
        let tracks = job?.tracks ?? []
        List {
            if let error, job == nil {
                StatusView(icon: "exclamationmark.triangle", title: "Can't reach the helper", message: error)
                    .listRowBackground(Color.clear)
            } else if job != nil && tracks.isEmpty {
                StatusView(icon: "icloud.and.arrow.down", title: "Nothing yet",
                           message: "In Search, switch to Download, find a song or album and tap the download button.")
                    .listRowBackground(Color.clear)
            }
            ForEach(tracks) { t in
                HStack(spacing: 12) {
                    CatalogArt(url: t.cover)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(t.title).lineLimit(1)
                        Text((t.status == "failed" || t.status == "queued") && t.note != nil ? "\(t.artist) · \(t.note ?? "")" : t.artist)
                            .font(.caption).foregroundStyle(Theme.secondary).lineLimit(2)
                        if t.status == "downloading" {
                            ProgressView(value: Double(t.progress ?? 0), total: 100).tint(Theme.accent)
                        }
                    }
                    Spacer(minLength: 8)
                    if t.isActive { ProgressView().controlSize(.small) }
                    Text(label(t)).font(.caption.weight(.medium))
                        .foregroundStyle(t.status == "failed" ? Color.red.opacity(0.85) : t.status == "found" ? Theme.accent : Theme.secondary)
                    if t.status == "failed", let job {
                        Button { retry(job, t) } label: { Image(systemName: "arrow.clockwise.circle.fill").font(.title2) }
                            .buttonStyle(.plain).foregroundStyle(.white)
                            .accessibilityLabel("Try again")
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { if let id = t.songId { Task { await playOwned(id, app: app, player: player) } } }
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Download Queue")
        .toolbar {
            if tracks.contains(where: { !$0.isActive }) {
                Button("Clear Finished") {
                    Task { try? await app.helper.clearFinished(); await refresh() }
                }
            }
        }
        .refreshable { await refresh() }
        .task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(job?.active == true ? 3 : 15))
            }
        }
    }

    private func label(_ t: ImportTrack) -> String {
        switch t.status {
        case "found": return t.note == "Already in your library" ? "Had it" : "Added"
        case "failed": return "Didn't work"
        case "importing": return "Adding…"
        default: return t.label
        }
    }

    private func refresh() async {
        do {
            job = try await app.helper.downloadQueue()      // newest first
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func retry(_ job: ImportJob, _ t: ImportTrack) {
        Task {
            _ = try? await app.helper.download(job.id, method: "song", indexes: [t.i])
            await refresh()
        }
    }
}
