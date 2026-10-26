import Foundation

// MARK: - Things that come from the music server (Subsonic API, served by Navidrome)

struct Album: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    var artist: String?
    var artistId: String?
    var coverArt: String?
    var songCount: Int?
    var duration: Int?
    var year: Int?
    var genre: String?
    var created: String?
}

struct Song: Identifiable, Codable, Hashable {
    let id: String
    let title: String
    var album: String?
    var artist: String?
    var albumId: String?
    var artistId: String?
    var track: Int?
    var discNumber: Int?
    var year: Int?
    var genre: String?
    var coverArt: String?
    var suffix: String?
    var duration: Int?
    var bitRate: Int?
    var starred: String?
}

struct Artist: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    var coverArt: String?
    var albumCount: Int?
    var artistImageUrl: String?
}

struct Playlist: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    var songCount: Int?
    var duration: Int?
    var coverArt: String?
    var owner: String?
}

// MARK: - Response wrappers

struct SubsonicEnvelope: Decodable {
    let response: SubsonicResponse
    enum CodingKeys: String, CodingKey { case response = "subsonic-response" }
}

struct SubsonicResponse: Decodable {
    struct ServerError: Decodable { let code: Int?; let message: String? }
    struct AlbumList: Decodable { var album: [Album]? }
    struct AlbumWithSongs: Decodable {
        let id: String
        let name: String
        var artist: String?
        var artistId: String?
        var coverArt: String?
        var year: Int?
        var genre: String?
        var duration: Int?
        var song: [Song]?
        var asAlbum: Album {
            Album(id: id, name: name, artist: artist, artistId: artistId, coverArt: coverArt,
                  songCount: song?.count, duration: duration, year: year, genre: genre)
        }
    }
    struct ArtistIndex: Decodable { var artist: [Artist]? }
    struct ArtistsList: Decodable { var index: [ArtistIndex]? }
    struct ArtistWithAlbums: Decodable {
        let id: String
        let name: String
        var coverArt: String?
        var artistImageUrl: String?
        var album: [Album]?
    }
    struct SearchResult: Decodable { var artist: [Artist]?; var album: [Album]?; var song: [Song]? }
    struct PlaylistList: Decodable { var playlist: [Playlist]? }
    struct PlaylistWithSongs: Decodable {
        let id: String
        let name: String
        var coverArt: String?
        var entry: [Song]?
    }
    struct SongList: Decodable { var song: [Song]? }

    let status: String
    var error: ServerError?
    var albumList2: AlbumList?
    var album: AlbumWithSongs?
    var artists: ArtistsList?
    var artist: ArtistWithAlbums?
    var searchResult3: SearchResult?
    var playlists: PlaylistList?
    var playlist: PlaylistWithSongs?
    var randomSongs: SongList?
    var starred2: SearchResult?
}

// MARK: - Something the player can play: a server song or a file on this iPhone

struct Track: Identifiable, Codable, Hashable {
    enum Source: Codable, Hashable {
        case remote(suffix: String?)
        case local(filename: String)
    }

    let id: String
    var title: String
    var artist: String
    var album: String
    var albumId: String?
    var artistId: String?
    var duration: Double
    var coverArt: String?          // server artwork id
    var localArtwork: String?      // artwork file name for imported songs
    var trackNumber: Int?
    var disc: Int?
    var starred = false
    var source: Source

    var isLocal: Bool { if case .local = source { return true } else { return false } }

    // Two tracks are the same song if their ids match, even if details like the heart differ.
    static func == (a: Track, b: Track) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
    var artworkKey: String { localArtwork.map { "local-\($0)" } ?? coverArt ?? albumId ?? id }

    init(song: Song) {
        id = song.id
        title = song.title
        artist = song.artist ?? "Unknown Artist"
        album = song.album ?? "Unknown Album"
        albumId = song.albumId
        artistId = song.artistId
        duration = Double(song.duration ?? 0)
        coverArt = song.coverArt ?? song.albumId
        trackNumber = song.track
        disc = song.discNumber
        starred = song.starred != nil
        source = .remote(suffix: song.suffix)
    }

    init(id: String, title: String, artist: String, album: String, duration: Double,
         localArtwork: String?, filename: String) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.localArtwork = localArtwork
        self.source = .local(filename: filename)
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

/// Album order: disc, then track number, then title.
func albumOrder(_ a: Track, _ b: Track) -> Bool {
    let da = a.disc ?? 1, db = b.disc ?? 1
    if da != db { return da < db }
    let ta = a.trackNumber ?? 0, tb = b.trackNumber ?? 0
    if ta != tb { return ta < tb }
    return a.title < b.title
}

/// Library order: artist, album, then album order.
func libraryOrder(_ a: Track, _ b: Track) -> Bool {
    if a.artist != b.artist { return a.artist.localizedCaseInsensitiveCompare(b.artist) == .orderedAscending }
    if a.album != b.album { return a.album.localizedCaseInsensitiveCompare(b.album) == .orderedAscending }
    return albumOrder(a, b)
}

func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let s = Int(seconds.rounded(.down))
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
                     : String(format: "%d:%02d", s / 60, s % 60)
}

func formatDuration(_ seconds: Int) -> String {
    let m = seconds / 60
    return m >= 60 ? "\(m / 60) hr \(m % 60) min" : "\(m) min"
}
