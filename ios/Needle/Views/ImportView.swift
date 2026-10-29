import SwiftUI
import UIKit

struct ImportRoute: Hashable { let id: String }

/// Paste a Spotify link (or a song list) and see recent imports.
struct ImportView: View {
    @Environment(AppModel.self) private var app
    @State private var source = ""
    @State private var name = ""
    @State private var error: String?
    @State private var starting = false
    @State private var recent = Loader<[ImportJob]>()
    @State private var opened: ImportRoute?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Paste a Spotify playlist or album link. Platter finds the songs you already have and makes a playlist in the same order, then can download the rest.")
                    .font(.subheadline).foregroundStyle(Theme.secondary)

                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Spotify link or song list").font(.caption).foregroundStyle(Theme.secondary)
                        ZStack(alignment: .topLeading) {
                            if source.isEmpty {
                                Text("https://open.spotify.com/playlist/…\n\nor one song per line:  Artist - Song")
                                    .foregroundStyle(Theme.tertiary).padding(.top, 8).padding(.leading, 5)
                            }
                            TextEditor(text: $source)
                                .scrollContentBackground(.hidden)
                                .frame(minHeight: 96)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    Theme.line.frame(height: 1)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Playlist name (optional)").font(.caption).foregroundStyle(Theme.secondary)
                        TextField("Uses the Spotify name", text: $name)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                }
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))

                HStack(spacing: 12) {
                    Button { Task { await start() } } label: {
                        Label(starting ? "Importing…" : "Import", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(FilledPill(fill: Theme.accent, text: .black))
                    .disabled(starting)
                    Button {
                        if let s = UIPasteboard.general.string { source = s }
                    } label: { Label("Paste", systemImage: "doc.on.clipboard").frame(maxWidth: .infinity) }
                    .buttonStyle(FilledPill(fill: Color.white.opacity(0.1), text: .white))
                }
                .font(.headline)

                if let error { Text(error).font(.footnote).foregroundStyle(.red) }

                Text("Recent Imports").font(Theme.title(20)).padding(.top, 14)
                if let jobs = recent.value {
                    if jobs.isEmpty {
                        StatusView(icon: "music.note.list", title: "Nothing imported yet",
                                   message: "In Spotify, tap ••• on a playlist › Share › Copy link, then paste it above.")
                    }
                    ForEach(jobs) { j in
                        NavigationLink(value: ImportRoute(id: j.id)) {
                            HStack(spacing: 14) {
                                Image(systemName: j.state == "error" ? "xmark" : "music.note.list")
                                    .font(.title3).foregroundStyle(j.state == "error" ? .red : Theme.accent)
                                    .frame(width: 46, height: 46).background(Theme.surface, in: RoundedRectangle(cornerRadius: 6))
                                    .symbolEffect(.pulse, isActive: j.active)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(j.name.isEmpty ? "Import" : j.name).lineLimit(1)
                                    Text(j.summary).font(.caption).foregroundStyle(Theme.secondary).lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Theme.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } else if let e = recent.error {
                    StatusView(icon: "exclamationmark.triangle", title: "Import isn't ready", message: e)
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding()
                }
            }
            .padding(20)
        }
        .background(Theme.background)
        .navigationTitle("Import Playlist")
        .navigationDestination(item: $opened) { ImportJobView(id: $0.id) }
        .task { await recent.load { try await app.helper.jobs() } }
        .refreshable { await recent.load { try await app.helper.jobs() } }
    }

    private func start() async {
        let s = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { error = "Paste a Spotify link or a list of songs first."; return }
        starting = true
        defer { starting = false }
        do {
            let job = try await app.helper.start(source: s, name: name.trimmingCharacters(in: .whitespaces))
            error = nil
            source = ""; name = ""
            opened = ImportRoute(id: job.id)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// One import: progress, the songs, and the choice to download what's missing.
struct ImportJobView: View {
    @Environment(AppModel.self) private var app
    @Environment(Player.self) private var player
    @Environment(\.dismiss) private var dismiss
    let id: String
    @State private var job: ImportJob?
    @State private var status: HelperStatus?
    @State private var error: String?
    @State private var missingOnly = false
    @State private var retry: ImportTrack?

    var body: some View {
        ScrollView {
            if let job {
                content(job)
            } else if let error {
                StatusView(icon: "exclamationmark.triangle", title: "Couldn't load this import", message: error)
            } else {
                ProgressView().padding(60)
            }
        }
        .background(Theme.background)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if job != nil {
                Menu {
                    Button("Remove from Recent Imports", systemImage: "trash", role: .destructive) {
                        Task { try? await app.helper.remove(id); dismiss() }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .confirmationDialog(retry.map { "Try again: \($0.title)" } ?? "", isPresented: Binding(get: { retry != nil }, set: { if !$0 { retry = nil } }),
                            titleVisibility: .visible) {
            if let t = retry {
                Button("Just the Song (Soulseek)") { Task { await download("song", [t.i]) } }
                Button("Whole Album (Lidarr)") { Task { await download("album", [t.i]) } }
            }
        }
        .task { await poll() }
    }

    @ViewBuilder private func content(_ j: ImportJob) -> some View {
        let missing = j.missing
        VStack(alignment: .leading, spacing: 14) {
            Text(j.name.isEmpty ? "Importing…" : j.name).font(Theme.title(28))
            Text(j.summary).font(.subheadline).foregroundStyle(j.state == "error" ? .red : Theme.secondary)
            if j.state != "error" {
                ProgressView(value: j.fraction).tint(Theme.accent).animation(.easeOut, value: j.fraction)
            }
            if let note = j.note { Text(note).font(.footnote).foregroundStyle(Theme.secondary) }

            if let pid = j.playlistId, !j.isWorking {
                HStack(spacing: 12) {
                    Button { Task { await playAll(pid) } } label: { Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity) }
                        .buttonStyle(FilledPill(fill: Theme.accent, text: .black))
                    NavigationLink(value: PlaylistRoute(playlist: Playlist(id: pid, name: j.name))) {
                        Label("Open Playlist", systemImage: "music.note.list").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(FilledPill(fill: Color.white.opacity(0.1), text: .white))
                }
                .font(.headline).padding(.top, 4)
            }

            if !missing.isEmpty && !j.isWorking {
                missingCard(j, missing)
            }

            if let tracks = j.tracks, !tracks.isEmpty {
                HStack {
                    Text("Songs").font(Theme.title(20))
                    Spacer()
                    if !missing.isEmpty && !j.isWorking {
                        Button(missingOnly ? "Show all" : "Missing only") { missingOnly.toggle() }
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(missingOnly ? Theme.accent : Color.white.opacity(0.1), in: Capsule())
                            .foregroundStyle(missingOnly ? .black : .white)
                    }
                }
                .padding(.top, 10)
                LazyVStack(spacing: 0) {
                    ForEach(tracks.filter { !missingOnly || $0.status != "found" }) { t in row(t) }
                }
            }
        }
        .padding(20)
    }

    private func missingCard(_ j: ImportJob, _ missing: [ImportTrack]) -> some View {
        let n = missing.count
        return VStack(alignment: .leading, spacing: 6) {
            Text(n == 1 ? "1 song isn't in your library" : "\(n) songs aren't in your library").font(.headline)
            Text("Download \(n == 1 ? "it" : "them") and Platter adds \(n == 1 ? "it" : "them") to this playlist in the right spot\(n == 1 ? "" : "s").")
                .font(.subheadline).foregroundStyle(Theme.secondary)
            HStack(spacing: 10) {
                choice("Just the Songs", "Soulseek", primary: true, enabled: status?.soulseek ?? true) {
                    Task { await download("song", missing.map(\.i)) }
                }
                choice("Whole Albums", "Lidarr", primary: false, enabled: status?.lidarr ?? true) {
                    Task { await download("album", missing.map(\.i)) }
                }
            }
            .padding(.top, 8)
            if let s = status, !s.soulseek || !s.lidarr {
                Text("\(!s.soulseek ? "Soulseek" : "Lidarr") isn't connected to the helper yet. Add its address and API key in the compose file.")
                    .font(.caption).foregroundStyle(Theme.tertiary).padding(.top, 4)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LinearGradient(colors: [.white.opacity(0.09), .white.opacity(0.03)], startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.line))
    }

    private func choice(_ title: String, _ sub: String, primary: Bool, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 0) {
                Text(title).font(.headline)
                Text(sub).font(.caption2.weight(.medium)).opacity(0.7)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(FilledPill(fill: primary ? Theme.accent : Color.white.opacity(0.1), text: primary ? .black : .white))
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
    }

    private func row(_ t: ImportTrack) -> some View {
        let dim = t.status == "missing" || t.status == "failed"
        return HStack(spacing: 12) {
            Text("\(t.i + 1)").font(.subheadline.monospacedDigit()).foregroundStyle(Theme.tertiary).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(t.title).foregroundStyle(dim ? Theme.secondary : .white).lineLimit(1)
                Text(t.status != "found" && t.note != nil ? "\(t.artist) · \(t.note!)" : t.artist)
                    .font(.caption).foregroundStyle(Theme.secondary).lineLimit(2)
            }
            Spacer(minLength: 8)
            if t.status == "found" {
                HStack(spacing: 4) {
                    if !t.label.isEmpty { Text(t.label).font(.caption.weight(.semibold)) }
                    Image(systemName: "checkmark")
                }
                .foregroundStyle(Theme.accent)
            } else {
                Text(t.label).font(.caption.weight(.semibold))
                    .foregroundStyle(t.status == "failed" ? Color(red: 1, green: 0.48, blue: 0.48) : t.isActive ? Theme.accent : Theme.secondary)
                if t.status == "failed" {
                    Button { retry = t } label: { Image(systemName: "arrow.clockwise").foregroundStyle(Theme.tertiary) }
                        .buttonStyle(.plain).accessibilityLabel("Try again")
                }
            }
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { Theme.line.frame(height: 1).padding(.leading, 40) }
    }

    private func poll() async {
        if status == nil { status = try? await app.helper.status() }
        while !Task.isCancelled {
            do {
                let j = try await app.helper.job(id)
                if j != job { withAnimation(.easeOut(duration: 0.2)) { job = j } }
                error = nil
                guard j.isWorking || j.active else { return }
                try? await Task.sleep(for: .seconds(j.state == "matching" ? 0.7 : 2))
            } catch {
                if job == nil { self.error = error.localizedDescription }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func download(_ method: String, _ indexes: [Int]) async {
        do {
            job = try await app.helper.download(id, method: method, indexes: indexes)
            await poll()
        } catch {
            self.error = error.localizedDescription
            if job != nil { job?.note = error.localizedDescription }
        }
    }

    private func playAll(_ pid: String) async {
        if let songs = try? await app.client.playlist(pid) { player.play(songs.map(Track.init(song:))) }
    }
}
