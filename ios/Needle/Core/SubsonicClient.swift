import CryptoKit
import Foundation

enum ServerProblem: LocalizedError {
    case notConfigured
    case server(String)
    case http(Int)
    case blockedByCloudflare
    case unreadable

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Add your server in Settings first."
        case .server(let m): return m
        case .http(let code): return "The server answered with error \(code)."
        case .blockedByCloudflare: return "Cloudflare blocked the app. Check the Access Client ID and Secret in Settings."
        case .unreadable: return "The server sent something unexpected. Check the server address."
        }
    }
}

/// Talks to Navidrome using the Subsonic API.
struct SubsonicClient {
    let config: ServerConfig
    var session: URLSession = .shared

    static let apiVersion = "1.16.1"

    // MARK: building requests

    func authItems() -> [URLQueryItem] {
        let salt = String(UUID().uuidString.prefix(8)).lowercased()
        let digest = Insecure.MD5.hash(data: Data((config.password + salt).utf8))
        let token = digest.map { String(format: "%02x", $0) }.joined()
        return [
            URLQueryItem(name: "u", value: config.username),
            URLQueryItem(name: "t", value: token),
            URLQueryItem(name: "s", value: salt),
            URLQueryItem(name: "v", value: Self.apiVersion),
            URLQueryItem(name: "c", value: "Platter"),
            URLQueryItem(name: "f", value: "json"),
        ]
    }

    func url(_ endpoint: String, _ params: [String: String] = [:]) -> URL? {
        guard let base = config.baseURL,
              var comps = URLComponents(url: base.appendingPathComponent("rest/\(endpoint)"),
                                        resolvingAgainstBaseURL: false) else { return nil }
        comps.queryItems = authItems() + params.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return comps.url
    }

    /// Every request carries the Cloudflare Access service token when one is set.
    func request(for url: URL) -> URLRequest {
        var r = URLRequest(url: url)
        r.timeoutInterval = 30
        if !config.accessClientId.isEmpty {
            r.setValue(config.accessClientId, forHTTPHeaderField: "CF-Access-Client-Id")
            r.setValue(config.accessClientSecret, forHTTPHeaderField: "CF-Access-Client-Secret")
        }
        return r
    }

    func call(_ endpoint: String, _ params: [String: String] = [:]) async throws -> SubsonicResponse {
        guard config.isComplete, let url = url(endpoint, params) else { throw ServerProblem.notConfigured }
        let (data, response) = try await session.data(for: request(for: url))
        try Self.check(response)
        guard let env = try? JSONDecoder().decode(SubsonicEnvelope.self, from: data) else {
            throw ServerProblem.unreadable
        }
        if env.response.status != "ok" {
            throw ServerProblem.server(env.response.error?.message ?? "The server reported an error.")
        }
        return env.response
    }

    static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        let host = http.url?.host ?? ""
        let type = http.value(forHTTPHeaderField: "Content-Type") ?? ""
        if host.contains("cloudflareaccess.com") || (http.statusCode == 403 && type.contains("html")) {
            throw ServerProblem.blockedByCloudflare
        }
        guard (200..<300).contains(http.statusCode) else { throw ServerProblem.http(http.statusCode) }
    }

    // MARK: library

    func ping() async throws { _ = try await call("ping") }

    func albums(_ type: String, size: Int = 40, offset: Int = 0) async throws -> [Album] {
        try await call("getAlbumList2", ["type": type, "size": "\(size)", "offset": "\(offset)"]).albumList2?.album ?? []
    }

    func album(_ id: String) async throws -> (Album, [Song]) {
        guard let a = try await call("getAlbum", ["id": id]).album else { throw ServerProblem.unreadable }
        let songs = (a.song ?? []).sorted { x, y in
            let dx = x.discNumber ?? 1, dy = y.discNumber ?? 1
            return dx != dy ? dx < dy : (x.track ?? 0) < (y.track ?? 0)
        }
        return (a.asAlbum, songs)
    }

    func artists() async throws -> [Artist] {
        (try await call("getArtists").artists?.index ?? []).flatMap { $0.artist ?? [] }
    }

    func artist(_ id: String) async throws -> (Artist, [Album]) {
        guard let a = try await call("getArtist", ["id": id]).artist else { throw ServerProblem.unreadable }
        let albums = (a.album ?? []).sorted { ($0.year ?? 0) > ($1.year ?? 0) }
        return (Artist(id: a.id, name: a.name, coverArt: a.coverArt, artistImageUrl: a.artistImageUrl), albums)
    }

    func search(_ query: String) async throws -> SubsonicResponse.SearchResult {
        try await call("search3", ["query": query, "artistCount": "8", "albumCount": "20", "songCount": "40"]).searchResult3
            ?? .init()
    }

    func playlists() async throws -> [Playlist] {
        try await call("getPlaylists").playlists?.playlist ?? []
    }

    func playlist(_ id: String) async throws -> [Song] {
        try await call("getPlaylist", ["id": id]).playlist?.entry ?? []
    }

    func songs(genre: String, count: Int = 300) async throws -> [Song] {
        try await call("getSongsByGenre", ["genre": genre, "count": "\(count)"]).songsByGenre?.song ?? []
    }

    func songs(matching query: String, count: Int = 60) async throws -> [Song] {
        try await call("search3", ["query": query, "artistCount": "0", "albumCount": "0", "songCount": "\(count)"]).searchResult3?.song ?? []
    }

    func artistInfo(_ id: String) async throws -> SubsonicResponse.ArtistInfo? {
        try await call("getArtistInfo2", ["id": id, "count": "12", "includeNotPresent": "false"]).artistInfo2
    }

    /// A call where one parameter repeats (songId=1&songId=2…).
    private func call(_ endpoint: String, _ params: [String: String], repeating key: String, _ values: [String]) async throws {
        guard config.isComplete, let base = url(endpoint, params),
              var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) else { throw ServerProblem.notConfigured }
        comps.queryItems = (comps.queryItems ?? []) + values.map { URLQueryItem(name: key, value: $0) }
        guard let url = comps.url else { throw ServerProblem.notConfigured }
        let (data, response) = try await session.data(for: request(for: url))
        try Self.check(response)
        let env = try? JSONDecoder().decode(SubsonicEnvelope.self, from: data)
        if let r = env?.response, r.status != "ok" { throw ServerProblem.server(r.error?.message ?? "Couldn't change the playlist.") }
    }

    /// Saves songs as a new playlist on the server.
    func createPlaylist(name: String, songIds: [String]) async throws {
        try await call("createPlaylist", ["name": name], repeating: "songId", songIds)
    }

    func addToPlaylist(_ id: String, songIds: [String]) async throws {
        try await call("updatePlaylist", ["playlistId": id], repeating: "songIdToAdd", songIds)
    }

    func removeFromPlaylist(_ id: String, index: Int) async throws {
        try await call("updatePlaylist", ["playlistId": id], repeating: "songIndexToRemove", [String(index)])
    }

    func song(_ id: String) async throws -> Song? {
        try await call("getSong", ["id": id]).song
    }

    func randomSongs(_ count: Int = 50) async throws -> [Song] {
        try await call("getRandomSongs", ["size": "\(count)"]).randomSongs?.song ?? []
    }

    func starred() async throws -> SubsonicResponse.SearchResult {
        try await call("getStarred2").starred2 ?? .init()
    }

    func setStarred(_ id: String, _ on: Bool) async throws {
        _ = try await call(on ? "star" : "unstar", ["id": id])
    }

    /// Lyrics stored in your music files or .lrc files beside them (Navidrome 0.53+).
    func lyrics(songId: String) async throws -> [SubsonicResponse.StructuredLyrics] {
        try await call("getLyricsBySongId", ["id": songId]).lyricsList?.structuredLyrics ?? []
    }

    /// Tells the server a song was played, so "most played" lists stay accurate.
    func scrobble(_ id: String) async {
        _ = try? await call("scrobble", ["id": id, "submission": "true"])
    }

    // MARK: files

    func streamURL(id: String, quality: StreamQuality, suffix: String?) -> (URL?, String) {
        // Formats iOS can play directly are sent as-is; anything else is converted to MP3 by the server.
        let playable: Set<String> = ["mp3", "m4a", "aac", "flac", "wav", "aif", "aiff", "alac", "caf"]
        let ext = (suffix ?? "").lowercased()
        if quality == .original, playable.contains(ext) {
            return (url("stream", ["id": id, "format": "raw"]), ext)
        }
        var params = ["id": id, "format": "mp3"]
        params["maxBitRate"] = "\(quality.maxBitRate ?? 320)"
        return (url("stream", params), "mp3")
    }

    func coverURL(_ id: String, size: Int) -> URL? {
        url("getCoverArt", ["id": id, "size": "\(size)"])
    }
}
