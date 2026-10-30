import SwiftUI

enum Theme {
    static let background = Color(red: 0.055, green: 0.058, blue: 0.075)
    static let surface = Color(red: 0.10, green: 0.105, blue: 0.13)
    static let line = Color.white.opacity(0.08)
    static let secondary = Color.white.opacity(0.58)
    static let tertiary = Color.white.opacity(0.36)
    /// Your accent color (Settings), or the playing album's color. Views using it update when it changes.
    static var accent: Color { AccentStore.shared.color }

    static func title(_ size: CGFloat) -> Font { .system(size: size, weight: .bold).width(.expanded) }
}

/// A big screen title in the app's wide type.
struct ScreenTitle: View {
    let text: String
    var body: some View {
        Text(text)
            .font(Theme.title(30))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 8)
    }
}

struct SectionHeader: View {
    let title: String
    var action: (() -> Void)? = nil
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 20, weight: .bold).width(.expanded))
            Spacer()
            if let action {
                Button("See all", action: action).font(.subheadline.weight(.medium)).foregroundStyle(Theme.secondary)
            }
        }
        .padding(.horizontal, 20)
    }
}

struct AlbumCard: View {
    let album: Album
    var size: CGFloat = 160
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ArtworkView(track: nil, coverArt: album.coverArt ?? album.id, size: size, corner: 10)
                .shadow(color: .black.opacity(0.35), radius: 10, y: 6)
            Text(album.name).font(.subheadline.weight(.semibold)).lineLimit(1)
            Text(album.artist ?? "").font(.caption).foregroundStyle(Theme.secondary).lineLimit(1)
        }
        .frame(width: size)
    }
}

/// One song in a list. Swipe right to add it to the queue, swipe left to favorite it (like Spotify).
/// ••• (or a long press) has the rest: Play Next, Add to Playlist, Download…
struct TrackRow: View {
    @Environment(Player.self) private var player
    @Environment(Downloads.self) private var downloads
    let track: Track
    var number: Int? = nil
    var showArtwork = true
    /// When the row is in one of your playlists: offers "Remove from This Playlist".
    var onRemove: (() -> Void)? = nil
    /// Off inside Lists that have their own swipe actions.
    var swipes = true
    let action: () -> Void

    @State private var dx: CGFloat = 0
    @State private var horizontal: Bool? = nil
    @State private var armed = false
    @State private var fired = 0
    @State private var swipedAt = Date.distantPast

    private var isCurrent: Bool { player.current?.id == track.id }
    private var starred: Bool { player.isStarred(track) }
    private static let trigger: CGFloat = 80

    var body: some View {
        ZStack {
            swipeBackground
            HStack(spacing: 0) {
                Button {
                    if Date().timeIntervalSince(swipedAt) > 0.4 { action() }
                } label: { content }
                .buttonStyle(RowButtonStyle())
                Menu {
                    TrackMenu(tracks: [track], onRemove: onRemove)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.tertiary)
                        .frame(width: 40, height: 44)
                        .contentShape(Rectangle())
                }
                .padding(.trailing, 8)
                .accessibilityLabel("More")
            }
            .background(Theme.background.opacity(dx == 0 ? 0 : 1))
            .offset(x: dx)
        }
        .clipped()
        .contextMenu { TrackMenu(tracks: [track], onRemove: onRemove) }
        .simultaneousGesture(swipe, including: swipes ? .all : .subviews)
        .sensoryFeedback(.impact(weight: .medium), trigger: armed) { _, now in now }
        .sensoryFeedback(.success, trigger: fired)
        .accessibilityAction(named: "Add to Queue") { player.addToQueue([track]) }
        .accessibilityAction(named: starred ? "Remove from Favorites" : "Add to Favorites") { player.setStarred([track], !starred) }
    }

    private var content: some View {
        HStack(spacing: 12) {
            if showArtwork {
                ArtworkView(track: track, size: 46, corner: 6)
            } else {
                Group {
                    if isCurrent {
                        NowPlayingBars(playing: player.isPlaying).frame(width: 16, height: 14)
                    } else {
                        Text(number.map { String($0) } ?? "").font(.subheadline.monospacedDigit()).foregroundStyle(Theme.tertiary)
                    }
                }
                .frame(width: 26)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.body.weight(isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? Theme.accent : .white)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    if downloads.isSaved(track.id) || track.isLocal {
                        Image(systemName: track.isLocal ? "iphone" : "arrow.down.circle.fill")
                            .font(.caption2).foregroundStyle(Theme.accent.opacity(0.8))
                    }
                    Text(showArtwork ? "\(track.artist) · \(track.album)" : track.artist)
                        .font(.caption).foregroundStyle(Theme.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if showArtwork, isCurrent {
                NowPlayingBars(playing: player.isPlaying).frame(width: 16, height: 14)
            }
            if starred {
                Image(systemName: "heart.fill").font(.caption2).foregroundStyle(Theme.accent)
            }
            Text(formatTime(track.duration)).font(.caption.monospacedDigit()).foregroundStyle(Theme.tertiary)
        }
        .padding(.leading, 20)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
    }

    /// What shows under the row as you drag it.
    private var swipeBackground: some View {
        let right = dx > 0
        let fill: Color = armed ? (right ? Color(red: 0.12, green: 0.62, blue: 0.33) : Theme.accent) : Color.white.opacity(0.07)
        return HStack {
            if right {
                Label("Add to Queue", systemImage: "text.append")
                Spacer()
            } else {
                Spacer()
                Label(starred ? "Unfavorite" : "Favorite", systemImage: starred ? "heart.slash.fill" : "heart.fill")
            }
        }
        .font(.subheadline.weight(.bold))
        .foregroundStyle(armed && !right ? Color.black : Color.white)
        .padding(.horizontal, 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(fill)
        .opacity(dx == 0 ? 0 : 1)
        .animation(.easeOut(duration: 0.12), value: armed)
    }

    private var swipe: some Gesture {
        DragGesture(minimumDistance: 14, coordinateSpace: .local)
            .onChanged { v in
                let w = v.translation.width, h = v.translation.height
                if horizontal == nil {
                    // decide once per drag: sideways means swipe, up/down means the list is scrolling
                    horizontal = abs(w) > abs(h) * 1.4
                }
                guard horizontal == true else { return }
                let limit: CGFloat = 150
                let x = abs(w) > limit ? (w > 0 ? 1 : -1) * (limit + (abs(w) - limit) * 0.25) : w
                dx = x
                let on = abs(x) > Self.trigger
                if on != armed { armed = on }
            }
            .onEnded { _ in
                defer {
                    horizontal = nil
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) { dx = 0 }
                    armed = false
                }
                guard horizontal == true else { return }
                swipedAt = Date()
                guard armed else { return }
                fired += 1
                if dx > 0 {
                    player.addToQueue([track])
                    player.errorMessage = "Added to queue"
                } else if !track.isLocal {
                    let on = !starred
                    player.setStarred([track], on)
                    player.errorMessage = on ? "Added to Favorites" : "Removed from Favorites"
                }
            }
    }
}

/// Asks the app to show "Add to Playlist" for these songs (menus can't present sheets themselves).
@Observable final class PlaylistPicker {
    static let shared = PlaylistPicker()
    struct Request: Identifiable { let id = UUID(); let tracks: [Track] }
    var request: Request?
    /// Bumped after a playlist is made or changed, so open playlist screens reload.
    var changed = 0
    func show(_ tracks: [Track]) { request = Request(tracks: tracks) }
}

/// "Add to Playlist": your playlists, plus a box to make a new one with these songs in it.
struct PlaylistPickerSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(Player.self) private var player
    @Environment(\.dismiss) private var dismiss
    let tracks: [Track]
    @State private var loader = Loader<[Playlist]>()
    @State private var newName = ""
    @State private var busy = false
    @FocusState private var typing: Bool

    private var subject: String { tracks.count == 1 ? "“\(tracks[0].title)”" : "\(tracks.count) songs" }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "plus").font(.title3).foregroundStyle(Theme.accent).frame(width: 44, height: 44)
                            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        TextField("New playlist", text: $newName)
                            .focused($typing)
                            .submitLabel(.done)
                            .onSubmit(create)
                        if !newName.trimmingCharacters(in: .whitespaces).isEmpty {
                            Button("Create", action: create).buttonStyle(.borderedProminent).tint(Theme.accent).foregroundStyle(.black)
                        }
                    }
                    .listRowBackground(Color.clear)
                }
                Section {
                    ForEach(mine) { p in
                        Button { add(to: p) } label: {
                            HStack(spacing: 12) {
                                ArtworkView(track: nil, coverArt: p.coverArt ?? p.id, size: 44, corner: 6)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(p.name).foregroundStyle(.white).lineLimit(1)
                                    Text("\(p.songCount ?? 0) songs").font(.caption).foregroundStyle(Theme.secondary)
                                }
                            }
                        }
                        .listRowBackground(Color.clear)
                    }
                } footer: {
                    if loader.value?.isEmpty == true { Text("No playlists yet. Name one above to make it.") }
                    if let e = loader.error { Text(e) }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .disabled(busy)
            .navigationTitle("Add \(subject)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task { await loader.load { try await app.client.playlists() } }
        }
        .presentationDetents([.medium, .large])
        .preferredColorScheme(.dark)
    }

    private var mine: [Playlist] {
        let me = app.settings.config.username
        return (loader.value ?? []).filter { $0.owner == nil || $0.owner == me }
    }

    private func add(to p: Playlist) {
        busy = true
        let c = app.client, ids = tracks.map(\.id)
        Task {
            do {
                try await c.addToPlaylist(p.id, songIds: ids)
                player.errorMessage = "Added to \(p.name)"
                PlaylistPicker.shared.changed += 1
                dismiss()
            } catch {
                player.errorMessage = "Couldn't add it. \(error.localizedDescription)"
                busy = false
            }
        }
    }

    private func create() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        busy = true
        let c = app.client, ids = tracks.map(\.id)
        Task {
            do {
                try await c.createPlaylist(name: name, songIds: ids)
                player.errorMessage = "Made “\(name)”"
                PlaylistPicker.shared.changed += 1
                dismiss()
            } catch {
                player.errorMessage = "Couldn't make the playlist. \(error.localizedDescription)"
                busy = false
            }
        }
    }
}

struct TrackMenu: View {
    @Environment(Player.self) private var player
    @Environment(Downloads.self) private var downloads
    let tracks: [Track]
    var onRemove: (() -> Void)? = nil

    var body: some View {
        Button { player.playNext(tracks) } label: { Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") }
        Button { player.addToQueue(tracks) } label: { Label("Add to Queue", systemImage: "text.append") }
        let remote = tracks.filter { !$0.isLocal }
        if !remote.isEmpty {
            Button { PlaylistPicker.shared.show(remote) } label: { Label("Add to Playlist…", systemImage: "text.badge.plus") }
            let allStarred = remote.allSatisfy { player.isStarred($0) }
            Button { player.setStarred(remote, !allStarred) } label: {
                Label(allStarred ? "Remove from Favorites" : "Add to Favorites", systemImage: allStarred ? "heart.slash" : "heart")
            }
            if let onRemove {
                Button(role: .destructive, action: onRemove) { Label("Remove from This Playlist", systemImage: "minus.circle") }
            }
            if remote.allSatisfy({ downloads.isSaved($0.id) }) {
                Button(role: .destructive) { downloads.remove(remote) } label: { Label("Remove Download", systemImage: "trash") }
            } else {
                Button { downloads.save(remote) } label: { Label("Download", systemImage: "arrow.down.circle") }
            }
        }
    }
}

struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color.white.opacity(0.06) : .clear)
    }
}

struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Little bouncing bars next to the song that's playing.
struct NowPlayingBars: View {
    let playing: Bool
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 24, paused: !playing)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<3, id: \.self) { i in
                    let h = playing ? 0.35 + 0.65 * abs(sin(t * (5.2 + Double(i) * 1.7) + Double(i))) : 0.3
                    Capsule().fill(Theme.accent).frame(width: 3).frame(height: 14 * h)
                }
            }
            .frame(height: 14, alignment: .bottom)
        }
    }
}

/// Play + Shuffle buttons used at the top of albums and playlists.
struct PlayButtons: View {
    var tint: Color = Theme.accent
    let play: () -> Void
    let shuffle: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            Button(action: play) {
                Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(FilledPill(fill: tint, text: .black))
            Button(action: shuffle) {
                Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity)
            }
            .buttonStyle(FilledPill(fill: Color.white.opacity(0.1), text: .white))
        }
        .font(.headline)
        .padding(.horizontal, 20)
    }
}

struct FilledPill: ButtonStyle {
    let fill: Color
    let text: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(text)
            .padding(.vertical, 13)
            .background(fill, in: Capsule())
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

/// Shown while loading or when something goes wrong.
struct StatusView: View {
    let icon: String
    let title: String
    var message: String? = nil
    var retry: (() -> Void)? = nil
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 34, weight: .light)).foregroundStyle(Theme.tertiary)
            Text(title).font(.headline)
            if let message { Text(message).font(.subheadline).foregroundStyle(Theme.secondary).multilineTextAlignment(.center) }
            if let retry { Button("Try Again", action: retry).buttonStyle(.bordered).padding(.top, 4) }
        }
        .padding(40)
        .frame(maxWidth: .infinity)
    }
}

/// Loads data for a screen and remembers the error if it fails.
@MainActor @Observable
final class Loader<T> {
    var value: T?
    var error: String?
    var loading = false

    func load(_ work: @escaping () async throws -> T) async {
        loading = true
        defer { loading = false }
        do {
            value = try await work()
            error = nil
        } catch is CancellationError {
        } catch let e as URLError where e.code == .cancelled {
        } catch {
            self.error = error.localizedDescription
        }
    }
}
