import SwiftUI

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
            Text(title).font(Theme.title(20))
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

/// Only one song row has its swipe buttons showing at a time.
@Observable final class RowSwipe {
    static let shared = RowSwipe()
    var open: UUID?
}

/// One song in a list. Swipe left to show Favorite and Add to Queue (swipe all the way to queue it right away);
/// swiping right is left alone so it always means "go back". ••• (or a long press) has everything else.
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

    @State private var me = UUID()
    @State private var dx: CGFloat = 0
    @State private var start: CGFloat = 0
    @State private var horizontal: Bool? = nil
    @State private var full = false
    @State private var fired = 0
    @State private var width: CGFloat = 390
    @State private var swipedAt = Date.distantPast
    @State private var dragging = false

    private var isCurrent: Bool { player.current?.id == track.id }
    private var starred: Bool { player.isStarred(track) }
    /// How far the buttons slide out.
    static let reveal: CGFloat = 148
    /// Drags that start this close to the left edge belong to the system's back swipe.
    static let edge: CGFloat = 28

    var body: some View {
        if Deleter.shared.deleted.contains(track.id) {
            EmptyView()
        } else {
            row
        }
    }

    private var row: some View {
        ZStack(alignment: .trailing) {
            if dx < 0 { actions.transition(.identity) }
            HStack(spacing: 0) {
                Button {
                    // a swipe can end with the finger still on the row: that isn't a tap
                    if dragging || Date().timeIntervalSince(swipedAt) < 0.4 { return }
                    if dx != 0 { close(); return }
                    action()
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
                .accessibilityIdentifier("track-more")
            }
            .background(Theme.background.opacity(dx == 0 ? 0 : 1))
            .offset(x: dx)
        }
        .clipped()
        .background(GeometryReader { g in Color.clear.onAppear { width = g.size.width }.onChange(of: g.size.width) { _, w in width = w } })
        .contextMenu { TrackMenu(tracks: [track], onRemove: onRemove) }
        .simultaneousGesture(swipe, including: swipes ? .all : .subviews)
        .onChange(of: RowSwipe.shared.open) { _, id in if id != me && dx != 0 { close() } }
        .sensoryFeedback(.impact(weight: .medium), trigger: full) { _, now in now }
        .sensoryFeedback(.success, trigger: fired)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("track-row")
        .accessibilityAction(named: "Add to Queue") { queue() }
        .accessibilityAction(named: starred ? "Remove from Favorites" : "Add to Favorites") { favorite() }
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

    /// Favorite and Add to Queue, under the row on the right.
    private var actions: some View {
        let shown = min(-dx, max(Self.reveal, -dx))
        return HStack(spacing: 0) {
            Button { favorite(); close() } label: {
                VStack(spacing: 3) {
                    Image(systemName: starred ? "heart.slash.fill" : "heart.fill").font(.body.weight(.semibold))
                    Text(starred ? "Unfavorite" : "Favorite").font(.caption2.weight(.bold))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.accent)
                .foregroundStyle(Color.black)
            }
            .frame(width: full ? 0 : shown / 2)
            .opacity(full || track.isLocal ? 0 : 1)
            .accessibilityIdentifier("swipe-favorite")
            Button { queue(); close() } label: {
                VStack(spacing: 3) {
                    Image(systemName: "text.append").font(.body.weight(.semibold))
                    Text("Queue").font(.caption2.weight(.bold))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(red: 0.12, green: 0.62, blue: 0.33))
                .foregroundStyle(Color.white)
            }
            .frame(width: full ? shown : shown / 2)
            .accessibilityIdentifier("swipe-queue")
        }
        .buttonStyle(.plain)
        .frame(width: shown)
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: full)
    }

    private var swipe: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .onChanged { v in
                let w = v.translation.width, h = v.translation.height
                if horizontal == nil {
                    // decide once per drag: up/down is the list scrolling; a drag from the left edge, or a
                    // rightward drag on a closed row, is the back swipe; only a leftward drag (or closing) is ours
                    let sideways = abs(w) > abs(h) * 1.4
                    let fromEdge = v.startLocation.x < Self.edge
                    horizontal = sideways && !fromEdge && (w < 0 || dx < 0)
                    start = dx
                    if horizontal == true { RowSwipe.shared.open = me }
                }
                guard horizontal == true else { return }
                dragging = true
                var x = min(0, start + w)
                let limit = width * 0.92
                if -x > limit { x = -(limit + (-x - limit) * 0.2) }
                dx = x
                let f = -x > max(Self.reveal + 60, width * 0.55)
                if f != full { full = f }
            }
            .onEnded { v in
                defer { horizontal = nil; dragging = false }
                guard horizontal == true else { return }
                swipedAt = Date()
                let fling = v.predictedEndTranslation.width - v.translation.width
                if full {
                    queue()
                    close()
                } else if -dx > Self.reveal * 0.45 || (fling < -120 && -dx > 30) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) { dx = -Self.reveal }
                } else {
                    close()
                }
            }
    }

    private func close() {
        full = false
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { dx = 0 }
        if RowSwipe.shared.open == me { RowSwipe.shared.open = nil }
    }

    private func queue() {
        fired += 1
        player.addToQueue([track])
        player.errorMessage = "Added to queue"
    }

    private func favorite() {
        guard !track.isLocal else { return }
        fired += 1
        let on = !starred
        player.setStarred([track], on)
        player.errorMessage = on ? "Added to Favorites" : "Removed from Favorites"
    }
}

/// "Delete from Library": asks first, then has the helper on the NAS remove the files (into its trash folder).
@Observable final class Deleter {
    static let shared = Deleter()
    struct Request: Identifiable { let id = UUID(); let tracks: [Track]; let what: String }
    var request: Request?
    /// Songs deleted this session, so lists hide them right away (the library catches up after its scan).
    private(set) var deleted: Set<String> = []

    func ask(_ tracks: [Track], what: String? = nil) {
        let remote = tracks.filter { !$0.isLocal }
        guard !remote.isEmpty else { return }
        request = Request(tracks: remote, what: what ?? (remote.count == 1 ? "“\(remote[0].title)”" : "\(remote.count) songs"))
    }

    @MainActor func perform(_ r: Request, helper: HelperClient, player: Player) {
        let ids = r.tracks.map(\.id)
        Task { @MainActor in
            do {
                let res = try await helper.delete(songIds: ids)
                if res.deleted > 0 { deleted.formUnion(ids) }
                if res.deleted == 0 {
                    player.errorMessage = "Couldn't find the file\(ids.count == 1 ? "" : "s") on the NAS"
                } else {
                    let what = res.deleted == 1 ? "Deleted it" : "Deleted \(res.deleted) songs"
                    player.errorMessage = res.missing.isEmpty ? what : "\(what) · couldn't find \(res.missing.count)"
                }
            } catch {
                player.errorMessage = error.localizedDescription
            }
        }
    }
}

/// The "are you sure" for Deleter, attached to the app's root and to Now Playing.
struct DeleteConfirm: ViewModifier {
    @Environment(AppModel.self) private var app
    @Environment(Player.self) private var player
    var enabled = true

    func body(content: Content) -> some View {
        let d = Deleter.shared
        return content.alert("Delete from your library?",
                      isPresented: Binding(get: { enabled && d.request != nil }, set: { if !$0 { d.request = nil } }),
                      presenting: d.request) { r in
            Button("Delete", role: .destructive) { d.perform(r, helper: app.helper, player: player) }
            Button("Cancel", role: .cancel) {}
        } message: { r in
            Text("\(r.what) will be removed from your NAS. The files go to the trash folder there (helper-data/trash), so you can get them back.")
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
                            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.corner(8), style: .continuous))
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
            .themedBackground()
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
            Button(role: .destructive) { Deleter.shared.ask(remote) } label: { Label("Delete from Library…", systemImage: "trash.slash") }
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
            .finish(fill, in: Capsule())
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
