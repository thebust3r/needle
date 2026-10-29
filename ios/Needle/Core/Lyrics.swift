import Foundation
import Observation

struct LyricLine: Codable, Equatable {
    var t: Double
    var text: String
}

struct Lyrics: Codable, Equatable {
    var synced: Bool
    var source: String
    var lines: [LyricLine]
    var instrumental = false

    /// "[01:23.45]text" lines → timed lines, sorted. Handles [offset:±ms] and several stamps per line.
    static func parseLRC(_ lrc: String) -> [LyricLine] {
        var out: [LyricLine] = []
        var offset = 0.0
        let stamp = try! NSRegularExpression(pattern: #"\[(\d{1,3}):(\d{1,2}(?:[.:]\d{1,3})?)\]"#)
        let anyTag = try! NSRegularExpression(pattern: #"\[[^\]]*\]"#)
        let offsetTag = try! NSRegularExpression(pattern: #"^\[offset:\s*([+-]?\d+)\s*\]"#, options: .caseInsensitive)
        for raw in lrc.components(separatedBy: .newlines) {
            let ns = raw as NSString
            let full = NSRange(location: 0, length: ns.length)
            if let m = offsetTag.firstMatch(in: raw, range: full) {
                offset = (Double(ns.substring(with: m.range(at: 1))) ?? 0) / 1000
                continue
            }
            let stamps = stamp.matches(in: raw, range: full)
            if stamps.isEmpty { continue }
            let text = anyTag.stringByReplacingMatches(in: raw, range: full, withTemplate: "").trimmingCharacters(in: .whitespaces)
            for s in stamps {
                let minutes = Double(ns.substring(with: s.range(at: 1))) ?? 0
                let seconds = Double(ns.substring(with: s.range(at: 2)).replacingOccurrences(of: ":", with: ".")) ?? 0
                out.append(LyricLine(t: minutes * 60 + seconds, text: text))
            }
        }
        return out.map { LyricLine(t: max(0, $0.t - offset), text: $0.text) }.sorted { $0.t < $1.t }
    }

    /// From Navidrome's getLyricsBySongId (lyrics embedded in your files or .lrc files beside them).
    static func from(navidrome list: [SubsonicResponse.StructuredLyrics]) -> Lyrics? {
        if let s = list.first(where: { $0.synced == true && !($0.line ?? []).isEmpty }) {
            let off = Double(s.offset ?? 0) / 1000
            return Lyrics(synced: true, source: "your files",
                          lines: (s.line ?? []).map { LyricLine(t: max(0, Double($0.start ?? 0) / 1000 - off), text: $0.value ?? "") })
        }
        if let s = list.first(where: { !($0.line ?? []).isEmpty }) {
            return Lyrics(synced: false, source: "your files", lines: (s.line ?? []).map { LyricLine(t: 0, text: $0.value ?? "") })
        }
        return nil
    }

    static func from(lrclib r: LRCLIBResult) -> Lyrics? {
        if r.instrumental == true { return Lyrics(synced: false, source: "LRCLIB", lines: [], instrumental: true) }
        if let s = r.syncedLyrics, !s.isEmpty {
            let lines = parseLRC(s)
            if !lines.isEmpty { return Lyrics(synced: true, source: "LRCLIB", lines: lines) }
        }
        if let p = r.plainLyrics, !p.isEmpty {
            return Lyrics(synced: false, source: "LRCLIB", lines: p.components(separatedBy: .newlines).map { LyricLine(t: 0, text: $0) })
        }
        return nil
    }

    /// Index of the line being sung at `time` (binary search), or -1 before the first line.
    func index(at time: Double) -> Int {
        var lo = 0, hi = lines.count - 1, found = -1
        while lo <= hi {
            let m = (lo + hi) / 2
            if lines[m].t <= time { found = m; lo = m + 1 } else { hi = m - 1 }
        }
        return found
    }
}

struct LRCLIBResult: Decodable {
    var duration: Double?
    var instrumental: Bool?
    var plainLyrics: String?
    var syncedLyrics: String?
}

/// Finds lyrics for the current song: Navidrome first, then LRCLIB. Results are cached on the phone.
@Observable @MainActor
final class LyricsStore {
    enum State: Equatable { case idle, loading, loaded(Lyrics), none, failed }

    private(set) var state: State = .idle
    private(set) var trackId: String?

    private struct Cached: Codable { var lyrics: Lyrics?; var at: Date }
    private static let folder: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("lyrics")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    func load(_ track: Track?, client: SubsonicClient) async {
        guard let track else { state = .idle; trackId = nil; return }
        if trackId == track.id, state != .failed { return }
        trackId = track.id
        let file = LyricsStore.folder.appendingPathComponent(track.id.replacingOccurrences(of: "/", with: "_") + ".json")
        if let data = try? Data(contentsOf: file), let c = try? JSONDecoder().decode(Cached.self, from: data),
           c.lyrics != nil || Date().timeIntervalSince(c.at) < 7 * 86400 {
            state = c.lyrics.map { .loaded($0) } ?? .none
            return
        }
        state = .loading
        do {
            var found: Lyrics?
            if !track.isLocal, let list = try? await client.lyrics(songId: track.id) { found = Lyrics.from(navidrome: list) }
            if found == nil { found = try await LyricsStore.fromLRCLIB(track) }
            guard trackId == track.id else { return }          // song changed while loading
            state = found.map { .loaded($0) } ?? .none
            try? JSONEncoder().encode(Cached(lyrics: found, at: Date())).write(to: file)
        } catch {
            guard trackId == track.id else { return }
            state = .failed
        }
    }

    private static func fromLRCLIB(_ t: Track) async throws -> Lyrics? {
        func get<T: Decodable>(_ path: String, _ items: [URLQueryItem], type: T.Type) async throws -> T? {
            var c = URLComponents(string: "https://lrclib.net/api/" + path)!
            c.queryItems = items.filter { !($0.value ?? "").isEmpty }
            var req = URLRequest(url: c.url!)
            req.timeoutInterval = 15
            req.setValue("Platter/1.0 (personal music player)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: req)
            if (response as? HTTPURLResponse)?.statusCode == 404 { return nil }
            return try JSONDecoder().decode(T.self, from: data)
        }
        let duration = t.duration > 0 ? String(Int(t.duration.rounded())) : ""
        if let hit = try await get("get", [.init(name: "artist_name", value: t.artist), .init(name: "track_name", value: t.title),
                                           .init(name: "album_name", value: t.album), .init(name: "duration", value: duration)],
                                   type: LRCLIBResult.self),
           let lyrics = Lyrics.from(lrclib: hit) {
            return lyrics
        }
        let results = try await get("search", [.init(name: "artist_name", value: t.artist), .init(name: "track_name", value: t.title)],
                                    type: [LRCLIBResult].self) ?? []
        let best = results.first { $0.syncedLyrics != nil && (t.duration == 0 || abs(($0.duration ?? 0) - t.duration) < 4) }
            ?? results.first { $0.syncedLyrics != nil } ?? results.first { $0.plainLyrics != nil }
        return best.flatMap { Lyrics.from(lrclib: $0) }
    }
}
