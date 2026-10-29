import Foundation

/// Wrapped: your listening for this month, this year or all time, from the play history the app and the web player
/// share (through the helper on the NAS). Same rules as the web player's wrapped.js.
enum WrappedPeriod: String, CaseIterable, Identifiable, Hashable {
    case month, year, all
    var id: String { rawValue }
}

struct WrappedRoute: Hashable { var period: WrappedPeriod = .month }

struct WrappedStats {
    struct SongStat: Identifiable { var id: String; var title: String; var artist: String; var album: String; var albumId: String?
                                    var coverArt: String?; var duration: Double; var plays: Int; var minutes: Double }
    struct ArtistStat: Identifiable { var id: String { name }; var name: String; var plays: Int; var minutes: Double; var coverArt: String? }
    struct AlbumStat { var name: String; var artist: String; var albumId: String?; var coverArt: String?; var minutes: Double }
    struct Persona { var name: String; var line: String; var share: Double }

    var period: WrappedPeriod
    var label: String
    var plays = 0
    var minutes = 0
    var songs = 0
    var artists = 0
    var topSongs: [SongStat] = []
    var playlist: [SongStat] = []
    var topArtists: [ArtistStat] = []
    var topAlbum: AlbumStat?
    var persona: Persona?
    var hours = [Int](repeating: 0, count: 24)
    var longestStreak = 0
    var activeDays = 0
    var biggestDay: (at: Date, minutes: Int)?
    var newArtists: (count: Int, names: [String]) = (0, [])
    var slowedShare = 0.0
    var favoriteSpeed: String?
}

enum Wrapped {
    static let slowed: Set<String> = ["slowed", "screwed", "syrup"]
    static let personas: [(from: Int, to: Int, name: String, line: String)] = [
        (5, 12, "Early Bird", "of your listening happens in the morning"),
        (12, 17, "Afternoon Cruiser", "of your listening happens in the afternoon"),
        (17, 22, "Evening Rider", "of your listening happens in the evening"),
        (22, 29, "Night Owl", "of your listening happens after 10 PM"),
    ]

    static func range(_ p: WrappedPeriod, now: Date = .now, calendar: Calendar = .current) -> (from: Date, to: Date, label: String) {
        switch p {
        case .month:
            let from = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? now
            return (from, now, now.formatted(.dateTime.month(.wide)))
        case .year:
            let from = calendar.date(from: calendar.dateComponents([.year], from: now)) ?? now
            return (from, now, now.formatted(.dateTime.year()))
        case .all:
            return (.distantPast, now, "All Time")
        }
    }

    /// How long each play really lasted: what was recorded, or until the next play started, at most the song.
    static func listenedSeconds(_ recs: [PlayRecord]) -> [Double] {
        recs.enumerated().map { i, r in
            if let l = r.listened { return max(0, min(l, r.duration > 0 ? r.duration : l)) }
            let gap = i + 1 < recs.count ? recs[i + 1].at.timeIntervalSince(r.at) : .infinity
            return max(0, min(r.duration, gap))
        }
    }

    static func compute(_ all: [PlayRecord], period: WrappedPeriod, now: Date = .now, calendar: Calendar = .current) -> WrappedStats {
        let recs = all.sorted { $0.at < $1.at }
        let secs = listenedSeconds(recs)
        let r = range(period, now: now, calendar: calendar)
        var firstPlay: [String: Date] = [:]
        for x in recs { let k = x.artist.trimmingCharacters(in: .whitespaces).lowercased(); if !k.isEmpty, firstPlay[k] == nil { firstPlay[k] = x.at } }

        var w = WrappedStats(period: period, label: r.label)
        var songs: [String: WrappedStats.SongStat] = [:]
        var artists: [String: (name: String, plays: Int, minutes: Double, covers: [String: Int])] = [:]
        var albums: [String: WrappedStats.AlbumStat] = [:]
        var hours = [Double](repeating: 0, count: 24)
        var days: [Date: (at: Date, minutes: Double)] = [:]
        var minutes = 0.0, slowedMin = 0.0
        var speeds: [String: Double] = [:]
        for (i, x) in recs.enumerated() where x.at >= r.from && x.at <= r.to {
            let s = secs[i], m = s / 60
            if s < min(30, (x.duration > 0 ? x.duration : 60) * 0.5) { continue }     // skips don't count
            w.plays += 1; minutes += m
            var song = songs[x.id] ?? .init(id: x.id, title: x.title, artist: x.artist, album: x.album, albumId: x.albumId,
                                            coverArt: x.coverArt, duration: x.duration, plays: 0, minutes: 0)
            song.plays += 1; song.minutes += m; songs[x.id] = song
            let ak = x.artist.isEmpty ? "Unknown" : x.artist.trimmingCharacters(in: .whitespaces)
            var a = artists[ak.lowercased()] ?? (ak, 0, 0, [:])
            a.plays += 1; a.minutes += m; a.covers[x.coverArt ?? "", default: 0] += 1; artists[ak.lowercased()] = a
            if !x.album.isEmpty {
                var b = albums["\(x.album)|\(x.artist)"] ?? .init(name: x.album, artist: x.artist, albumId: x.albumId, coverArt: x.coverArt, minutes: 0)
                b.minutes += m; albums["\(x.album)|\(x.artist)"] = b
            }
            hours[calendar.component(.hour, from: x.at)] += m
            let day = calendar.startOfDay(for: x.at)
            days[day] = (x.at, (days[day]?.minutes ?? 0) + m)
            if let sp = x.speed { speeds[sp, default: 0] += m; if slowed.contains(sp) { slowedMin += m } }
        }
        let ranked = songs.values.sorted { $0.plays != $1.plays ? $0.plays > $1.plays : $0.minutes > $1.minutes }
        w.topSongs = Array(ranked.prefix(5))
        w.playlist = Array(ranked.prefix(50))
        let rankedArtists = artists.values.sorted { $0.minutes != $1.minutes ? $0.minutes > $1.minutes : $0.plays > $1.plays }
        w.topArtists = rankedArtists.prefix(5).map { a in
            WrappedStats.ArtistStat(name: a.name, plays: a.plays, minutes: a.minutes, coverArt: a.covers.max { $0.value < $1.value }?.key)
        }
        w.topAlbum = albums.values.max { $0.minutes < $1.minutes }
        w.minutes = Int(minutes.rounded())
        w.songs = songs.count; w.artists = artists.count
        w.hours = hours.map { Int($0.rounded()) }
        if minutes > 0 {
            w.persona = personas.map { p -> WrappedStats.Persona in
                var m = 0.0
                for h in p.from..<p.to { m += hours[h % 24] }
                return .init(name: p.name, line: p.line, share: m / minutes)
            }.max { $0.share < $1.share }
        }
        let dayList = days.keys.sorted()
        var run = 0, prev: Date?
        for d in dayList {
            if let p = prev, calendar.dateComponents([.day], from: p, to: d).day == 1 { run += 1 } else { run = 1 }
            w.longestStreak = max(w.longestStreak, run); prev = d
        }
        w.activeDays = days.count
        if let big = days.values.max(by: { $0.minutes < $1.minutes }) { w.biggestDay = (big.at, Int(big.minutes.rounded())) }
        let fresh = artists.values.filter { (firstPlay[$0.name.lowercased()] ?? .distantPast) >= r.from }.sorted { $0.minutes > $1.minutes }
        w.newArtists = (fresh.count, fresh.prefix(3).map { $0.name })
        w.slowedShare = minutes > 0 ? slowedMin / minutes : 0
        w.favoriteSpeed = speeds.filter { slowed.contains($0.key) }.max { $0.value < $1.value }?.key
        return w
    }
}
