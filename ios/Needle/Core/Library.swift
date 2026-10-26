import AVFoundation
import Foundation
import Observation
import UIKit

private let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
private let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "flac", "wav", "aif", "aiff", "alac", "caf", "mp4"]

// MARK: - Songs saved for offline listening

@Observable
final class Downloads {
    static let folder: URL = {
        let dir = documents.appendingPathComponent(".downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    private static let index = folder.appendingPathComponent("index.json")

    private(set) var saved: [String: Track] = [:]
    private(set) var active: Set<String> = []
    private(set) var failed: Set<String> = []
    @ObservationIgnored private var files: [String: String] = [:]   // id -> file name
    @ObservationIgnored var client: () -> SubsonicClient = { SubsonicClient(config: ServerConfig()) }
    @ObservationIgnored private var pending: [Track] = []
    @ObservationIgnored private var running = false

    var tracks: [Track] { saved.values.sorted(by: libraryOrder) }
    var totalBytes: Int64 {
        files.values.reduce(0) { sum, f in
            sum + ((try? FileManager.default.attributesOfItem(atPath: Self.folder.appendingPathComponent(f).path)[.size] as? Int64) ?? 0)
        }
    }

    init() {
        struct Saved: Codable { var track: Track; var file: String }
        if let data = try? Data(contentsOf: Self.index), let list = try? JSONDecoder().decode([Saved].self, from: data) {
            for s in list where FileManager.default.fileExists(atPath: Self.folder.appendingPathComponent(s.file).path) {
                saved[s.track.id] = s.track
                files[s.track.id] = s.file
            }
        }
    }

    func isSaved(_ id: String) -> Bool { saved[id] != nil }

    func fileURL(for id: String) -> URL? {
        files[id].map { Self.folder.appendingPathComponent($0) }
    }

    func save(_ tracks: [Track]) {
        let new = tracks.filter { !$0.isLocal && saved[$0.id] == nil && !active.contains($0.id) }
        pending.append(contentsOf: new)
        new.forEach { active.insert($0.id); failed.remove($0.id) }
        if !running { Task { await runQueue() } }
    }

    func remove(_ tracks: [Track]) {
        for t in tracks {
            if let f = files[t.id] { try? FileManager.default.removeItem(at: Self.folder.appendingPathComponent(f)) }
            files[t.id] = nil
            saved[t.id] = nil
        }
        persist()
    }

    @MainActor
    private func runQueue() async {
        running = true
        while !pending.isEmpty {
            let track = pending.removeFirst()
            do {
                let c = client()
                guard case .remote(let suffix) = track.source else { continue }
                let (url, ext) = c.streamURL(id: track.id, quality: .original, suffix: suffix)
                guard let url else { throw ServerProblem.notConfigured }
                let (temp, response) = try await c.session.download(for: c.request(for: url))
                try SubsonicClient.check(response)
                let name = track.id.replacingOccurrences(of: "/", with: "_") + "." + ext
                let dest = Self.folder.appendingPathComponent(name)
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: temp, to: dest)
                files[track.id] = name
                saved[track.id] = track
                persist()
                // keep a full-size cover for offline use
                if let art = track.coverArt { _ = await ArtworkStore.shared.image(coverArt: art, size: 900) }
            } catch {
                failed.insert(track.id)
            }
            active.remove(track.id)
        }
        running = false
    }

    private func persist() {
        struct Saved: Codable { var track: Track; var file: String }
        let list = saved.values.compactMap { t in files[t.id].map { Saved(track: t, file: $0) } }
        try? JSONEncoder().encode(list).write(to: Self.index)
    }
}

struct LocalAlbum: Identifiable, Hashable {
    var id: String { name + "\u{1}" + artist }
    let name: String
    let artist: String
    let tracks: [Track]
}

// MARK: - Music files on this iPhone (imported from Files, or dropped in the app's folder)

@Observable
final class LocalLibrary {
    /// Shows up in the Files app under On My iPhone > Needle. Drop music here.
    static let inbox = documents
    static let folder: URL = {
        let dir = documents.appendingPathComponent(".library", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    private static let index = folder.appendingPathComponent("index.json")

    private(set) var tracks: [Track] = []
    private(set) var isImporting = false

    var albums: [LocalAlbum] {
        Dictionary(grouping: tracks, by: { "\($0.album)\u{1}\($0.artist)" })
            .map { (_, list) in
                LocalAlbum(name: list[0].album, artist: list[0].artist,
                           tracks: list.sorted(by: albumOrder))
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    init() {
        if let data = try? Data(contentsOf: Self.index), let list = try? JSONDecoder().decode([Track].self, from: data) {
            tracks = list.filter { t in
                if case .local(let f) = t.source { return FileManager.default.fileExists(atPath: Self.folder.appendingPathComponent(f).path) }
                return false
            }
        }
    }

    func fileURL(for track: Track) -> URL? {
        if case .local(let f) = track.source { return Self.folder.appendingPathComponent(f) }
        return nil
    }

    /// Picks up any music files sitting in the app's Files folder.
    @MainActor
    func scanInbox() async {
        let items = (try? FileManager.default.contentsOfDirectory(at: Self.inbox, includingPropertiesForKeys: nil)) ?? []
        let audio = items.filter { audioExtensions.contains($0.pathExtension.lowercased()) }
        guard !audio.isEmpty else { return }
        await importFiles(audio, move: true)
    }

    /// Copies files chosen in the Files app into the library and reads their tags.
    @MainActor
    func importFiles(_ urls: [URL], move: Bool = false) async {
        isImporting = true
        defer { isImporting = false }
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard audioExtensions.contains(url.pathExtension.lowercased()) else { continue }
            let id = "local-" + UUID().uuidString
            let file = id + "." + url.pathExtension.lowercased()
            let dest = Self.folder.appendingPathComponent(file)
            do {
                if move { try FileManager.default.moveItem(at: url, to: dest) }
                else { try FileManager.default.copyItem(at: url, to: dest) }
            } catch { continue }
            let track = await Self.readTags(dest, id: id, file: file,
                                            fallbackTitle: url.deletingPathExtension().lastPathComponent)
            tracks.append(track)
        }
        persist()
    }

    func remove(_ list: [Track]) {
        for t in list {
            if case .local(let f) = t.source { try? FileManager.default.removeItem(at: Self.folder.appendingPathComponent(f)) }
            if let art = t.localArtwork { try? FileManager.default.removeItem(at: Self.folder.appendingPathComponent(art)) }
        }
        let ids = Set(list.map(\.id))
        tracks.removeAll { ids.contains($0.id) }
        persist()
    }

    private func persist() {
        try? JSONEncoder().encode(tracks).write(to: Self.index)
    }

    private static func readTags(_ url: URL, id: String, file: String, fallbackTitle: String) async -> Track {
        let asset = AVURLAsset(url: url)
        var title = fallbackTitle, artist = "Unknown Artist", album = "Unknown Album"
        var artFile: String?
        var trackNo: Int?
        let duration = (try? await asset.load(.duration))?.seconds ?? 0
        let items = (try? await asset.load(.commonMetadata)) ?? []
        for item in items {
            switch item.commonKey {
            case .commonKeyTitle?: if let v = try? await item.load(.stringValue), !v.isEmpty { title = v }
            case .commonKeyArtist?: if let v = try? await item.load(.stringValue), !v.isEmpty { artist = v }
            case .commonKeyAlbumName?: if let v = try? await item.load(.stringValue), !v.isEmpty { album = v }
            case .commonKeyArtwork?:
                if let data = try? await item.load(.dataValue), let img = UIImage(data: data),
                   let jpg = img.jpegData(compressionQuality: 0.9) {
                    let name = id + ".jpg"
                    try? jpg.write(to: folder.appendingPathComponent(name))
                    artFile = name
                }
            default: break
            }
        }
        // track number lives outside the common keys
        if let formats = try? await asset.load(.availableMetadataFormats) {
            for format in formats {
                let meta = (try? await asset.loadMetadata(for: format)) ?? []
                for item in meta where trackNo == nil {
                    let key = (item.key as? String) ?? ""
                    if item.identifier == .id3MetadataTrackNumber || item.identifier == .iTunesMetadataTrackNumber || key.uppercased() == "TRACKNUMBER" {
                        if let s = try? await item.load(.stringValue) {
                            trackNo = Int(s.split(separator: "/").first ?? "")
                        } else if let n = try? await item.load(.numberValue) {
                            trackNo = n.intValue
                        }
                    }
                }
            }
        }
        var t = Track(id: id, title: title, artist: artist, album: album, duration: duration.isFinite ? duration : 0,
                      localArtwork: artFile, filename: file)
        t.trackNumber = trackNo
        return t
    }
}
