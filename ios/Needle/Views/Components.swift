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

/// One song in a list. Long-press for queue and download options.
struct TrackRow: View {
    @Environment(Player.self) private var player
    @Environment(Downloads.self) private var downloads
    let track: Track
    var number: Int? = nil
    var showArtwork = true
    let action: () -> Void

    private var isCurrent: Bool { player.current?.id == track.id }

    var body: some View {
        Button(action: action) {
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
                Text(formatTime(track.duration)).font(.caption.monospacedDigit()).foregroundStyle(Theme.tertiary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
        .contextMenu { TrackMenu(tracks: [track]) }
    }
}

struct TrackMenu: View {
    @Environment(Player.self) private var player
    @Environment(Downloads.self) private var downloads
    let tracks: [Track]

    var body: some View {
        Button { player.playNext(tracks) } label: { Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") }
        Button { player.addToQueue(tracks) } label: { Label("Add to Queue", systemImage: "text.append") }
        let remote = tracks.filter { !$0.isLocal }
        if !remote.isEmpty {
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
