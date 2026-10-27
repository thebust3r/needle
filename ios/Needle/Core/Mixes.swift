import Foundation
import Observation

// MARK: - Listening history (kept on this iPhone)

/// One song you started playing. Kept on the phone so the daily mixes can learn what you like,
/// what you skip, what you play at night, and what you played on this day last year.
struct PlayRecord: Codable, Hashable {
    var id: String
    var title: String
    var artist: String
    var album: String
    var albumId: String?
    var coverArt: String?
    var duration: Double
    var at: Date
    var listened: Double?          // seconds actually heard (filled in when the next song starts)

    var skipped: Bool { (listened ?? duration) < min(30, duration * 0.5) }

    var asSong: Song {
        Song(id: id, title: title, album: album, artist: artist, albumId: albumId, coverArt: coverArt, duration: Int(duration))
    }
}

@MainActor @Observable
final class PlayHistory {
    static let shared = PlayHistory()
    private(set) var records: [PlayRecord] = []
    @ObservationIgnored private var startedAt: Date?
    @ObservationIgnored private let file: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }()

    init(load: Bool = true) {
        if load, let data = try? Data(contentsOf: file),
           let r = try? JSONDecoder().decode([PlayRecord].self, from: data) { records = r }
    }

    func started(_ t: Track, now: Date = .now) {
        guard !t.isLocal else { return }
        if let last = records.indices.last, records[last].listened == nil, let s = startedAt {
            records[last].listened = min(records[last].duration, now.timeIntervalSince(s))
        }
        if let last = records.last, last.id == t.id, now.timeIntervalSince(last.at) < 20 { return }
        records.append(PlayRecord(id: t.id, title: t.title, artist: t.artist, album: t.album, albumId: t.albumId,
                                  coverArt: t.coverArt, duration: t.duration, at: now))
        startedAt = now
        if records.count > 5000 { records.removeFirst(records.count - 5000) }
        save()
    }

    func save() {
        let snapshot = records, file = file
        Task.detached(priority: .utility) { try? JSONEncoder().encode(snapshot).write(to: file, options: .atomic) }
    }

    /// Only for tests and previews.
    func replace(_ r: [PlayRecord]) { records = r }
}

// MARK: - Mixes

struct Mix: Identifiable, Codable, Hashable {
    enum Kind: String, Codable { case daily, rediscover, fresh, timeOfDay, onThisDay }
    var id: String
    var kind: Kind
    var title: String
    var subtitle: String
    var hue: Double                 // 0...1, the card's color
    var songs: [Song]
    var covers: [String] {          // up to four different album covers for the card
        var seen = Set<String>(), out: [String] = []
        for s in songs {
            guard let c = s.coverArt ?? s.albumId, !seen.contains(s.albumId ?? c) else { continue }
            seen.insert(s.albumId ?? c); out.append(c)
            if out.count == 4 { break }
        }
        return out
    }
}

/// A small random number generator that gives the same answers for the same seed,
/// so today's mixes stay the same all day and change tomorrow.
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64
    init(_ seed: String) {
        var h: UInt64 = 1469598103934665603
        for b in seed.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        state = h == 0 ? 0x9E3779B97F4A7C15 : h
    }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}

enum DayPart: String, Codable {
    case morning, afternoon, evening, lateNight
    init(hour: Int) {
        switch hour {
        case 5..<11: self = .morning
        case 11..<17: self = .afternoon
        case 17..<22: self = .evening
        default: self = .lateNight
        }
    }
    var mixTitle: String {
        switch self {
        case .morning: return "Morning Mix"
        case .afternoon: return "Afternoon Mix"
        case .evening: return "Evening Mix"
        case .lateNight: return "Late Night Mix"
        }
    }
    func contains(hour h: Int) -> Bool { DayPart(hour: h) == self }
}

/// Everything the mixer looks at. Gathered from Navidrome by `MixStore`, or made up in tests.
struct MixLibrary {
    var frequent: [Album] = []       // most played albums, most first
    var recent: [Album] = []         // recently played albums
    var sample: [Song] = []          // a big random sample of the whole library
    var starred: [Song] = []
    var fresh: [Song] = []           // songs from recently added albums
    var pools: [String: [Song]] = [:] // songs by genre ("genre:Rock") or by artist ("artist:Name")
}

/// Builds the mixes. Pure: same library + history + day = same mixes.
enum Mixer {
    static let size = 30

    struct Plan: Equatable {
        struct Daily: Equatable { var genre: String?; var seeds: [String] }
        var dailies: [Daily]
        var poolKeys: [String] {
            dailies.flatMap { d in d.genre.map { ["genre:" + $0] } ?? d.seeds.map { "artist:" + $0 } }
        }
    }

    static func key(_ s: String) -> String { s.lowercased().trimmingCharacters(in: .whitespaces) }

    /// How much you like each artist: plays (minus skips) in the last 90 days, most played albums, favorites.
    static func artistWeights(_ lib: MixLibrary, _ history: [PlayRecord], now: Date) -> [String: Double] {
        var w: [String: Double] = [:]
        for r in history where now.timeIntervalSince(r.at) < 90 * 86400 {
            w[key(r.artist), default: 0] += r.skipped ? -0.4 : 1
        }
        for (i, a) in lib.frequent.enumerated() { if let ar = a.artist { w[key(ar), default: 0] += max(1, 4 - Double(i) * 0.1) } }
        for a in lib.recent { if let ar = a.artist { w[key(ar), default: 0] += 1.5 } }
        for s in lib.starred { if let ar = s.artist { w[key(ar), default: 0] += 0.8 } }
        if w.values.filter({ $0 > 0 }).count < 3 {   // brand-new library: lean on what's in it
            for s in lib.sample { if let ar = s.artist { w[key(ar), default: 0] += 0.05 } }
        }
        return w
    }

    /// Picks what each Daily Mix is about: up to four of your genres, or groups of artists if your music has no genres.
    static func plan(_ lib: MixLibrary, _ history: [PlayRecord], now: Date = .now) -> Plan {
        let weights = artistWeights(lib, history, now: now)
        var display: [String: String] = [:]
        var genreOf: [String: [String: Int]] = [:]
        func note(_ artist: String?, _ genre: String?) {
            guard let a = artist, !a.isEmpty else { return }
            display[key(a)] = display[key(a)] ?? a
            if let g = genre?.trimmingCharacters(in: .whitespaces), !g.isEmpty { genreOf[key(a), default: [:]][g, default: 0] += 1 }
        }
        lib.frequent.forEach { note($0.artist, $0.genre) }
        lib.recent.forEach { note($0.artist, $0.genre) }
        (lib.sample + lib.starred + lib.fresh).forEach { note($0.artist, $0.genre) }
        history.forEach { note($0.artist, nil) }

        var genreWeight: [String: Double] = [:]
        var artistsByGenre: [String: [(String, Double)]] = [:]
        for (a, wt) in weights where wt > 0 {
            guard let g = genreOf[a]?.max(by: { $0.value < $1.value })?.key else { continue }
            genreWeight[g, default: 0] += wt
            artistsByGenre[g, default: []].append((a, wt))
        }
        var dailies: [Plan.Daily] = []
        let genres = genreWeight.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(4).map(\.key)
        var used = Set<String>()
        for g in genres {
            let seeds = (artistsByGenre[g] ?? []).sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }.prefix(3).map { display[$0.0] ?? $0.0 }
            seeds.forEach { used.insert(key($0)) }
            dailies.append(.init(genre: g, seeds: seeds))
        }
        // not enough genres: fill up with groups of three favorite artists
        let rest = weights.filter { $0.value > 0 && !used.contains($0.key) }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map { display[$0.key] ?? $0.key }
        var i = 0
        while dailies.count < 4, i + 1 < rest.count {
            dailies.append(.init(genre: nil, seeds: Array(rest[i..<min(i + 3, rest.count)])))
            i += 3
        }
        return Plan(dailies: dailies)
    }

    static func build(_ lib: MixLibrary, history: [PlayRecord], now: Date = .now, calendar: Calendar = .current) -> [Mix] {
        let day = dayKey(now, calendar)
        let weights = artistWeights(lib, history, now: now)
        let recentlyPlayed = Set(history.filter { now.timeIntervalSince($0.at) < 3 * 86400 }.map(\.id))
        let skippedOften = Dictionary(grouping: history.filter(\.skipped), by: \.id).filter { $0.value.count >= 2 }.keys
        let starredIds = Set(lib.starred.map(\.id))
        var mixes: [Mix] = []

        // Daily Mix 1-4
        for (n, d) in plan(lib, history, now: now).dailies.enumerated() {
            var pool = d.genre.flatMap { lib.pools["genre:" + $0] } ?? []
            for s in d.seeds { pool += lib.pools["artist:" + s] ?? [] }
            pool += lib.sample.filter { s in d.seeds.contains { key($0) == key(s.artist ?? "") } || (d.genre != nil && s.genre == d.genre) }
            let seedKeys = Set(d.seeds.map(key))
            var rng = SeededRandom("\(day)-daily-\(n)")
            let songs = pick(pool, count: size, rng: &rng) { s in
                var score = 1.0
                let a = key(s.artist ?? "")
                if seedKeys.contains(a) { score += 3 }
                score += max(-0.5, min(2, (weights[a] ?? 0) * 0.3))
                if starredIds.contains(s.id) { score += 1 }
                if let pc = s.playCount, pc > 0 { score += min(1, Double(pc) * 0.1) }
                if recentlyPlayed.contains(s.id) { score *= 0.25 }
                if skippedOften.contains(s.id) { score *= 0.2 }
                return score
            }
            guard songs.count >= 8 else { continue }
            let names = d.seeds.prefix(2).joined(separator: ", ")
            mixes.append(Mix(id: "daily-\(mixes.count + 1)", kind: .daily, title: "Daily Mix \(mixes.count + 1)",
                             subtitle: d.seeds.count > 2 ? "\(names) and more" : (names.isEmpty ? (d.genre ?? "Your favorites") : names),
                             hue: hue(d.genre ?? d.seeds.joined()), songs: songs))
        }

        // Time of day
        let hour = calendar.component(.hour, from: now)
        let part = DayPart(hour: hour)
        let atThisTime = history.filter { part.contains(hour: calendar.component(.hour, from: $0.at)) && !$0.skipped }
        var partWeights: [String: Double] = [:]
        for r in atThisTime { partWeights[key(r.artist), default: 0] += 1 }
        let usePart = atThisTime.count >= 15
        var timePool = usePart ? Array(Set(atThisTime.map(\.asSong))) : []
        timePool += lib.sample.filter { (usePart ? partWeights : weights)[key($0.artist ?? ""), default: 0] > 0 }
        timePool += lib.starred
        var trng = SeededRandom("\(day)-\(part.rawValue)")
        let timeSongs = pick(timePool, count: size, rng: &trng) { s in
            let a = key(s.artist ?? "")
            var score = 1 + min(3, (usePart ? partWeights[a] ?? 0 : weights[a] ?? 0) * 0.4)
            if starredIds.contains(s.id) { score += 0.8 }
            if recentlyPlayed.contains(s.id) { score *= 0.5 }
            return score
        }
        if timeSongs.count >= 8 {
            mixes.append(Mix(id: "time-\(part.rawValue)", kind: .timeOfDay, title: part.mixTitle,
                             subtitle: usePart ? "What you play around this time" : "Your favorites for right now",
                             hue: hue(part.rawValue), songs: timeSongs))
        }

        // Rediscover: songs you played a lot, but not lately
        let old = now.addingTimeInterval(-45 * 86400)
        let heardLately = Set(history.filter { $0.at > old }.map(\.id))
        let rediscoverPool = (lib.sample + lib.starred).filter { s in
            guard !heardLately.contains(s.id) else { return false }
            let pc = s.playCount ?? 0
            if let p = s.played.flatMap(parseDate) { return pc >= 2 && p < old }
            return pc >= 4 || (starredIds.contains(s.id) && pc >= 1)
        }
        var rrng = SeededRandom("\(day)-rediscover")
        let rediscover = pick(rediscoverPool, count: 25, rng: &rrng) { s in 1 + min(3, Double(s.playCount ?? 0) * 0.2) + (starredIds.contains(s.id) ? 1 : 0) }
        if rediscover.count >= 8 {
            mixes.append(Mix(id: "rediscover", kind: .rediscover, title: "Rediscover", subtitle: "Old favorites you haven't played lately",
                             hue: 0.08, songs: rediscover))
        }

        // Fresh Finds: new to your library, not played much yet
        let everHeard = Set(history.map(\.id))
        let freshPool = lib.fresh.filter { ($0.playCount ?? 0) <= 1 && !everHeard.contains($0.id) }
        var frng = SeededRandom("\(day)-fresh")
        let fresh = pick(freshPool, count: 25, rng: &frng, perAlbum: 3) { _ in 1 }
        if fresh.count >= 6 {
            mixes.append(Mix(id: "fresh", kind: .fresh, title: "Fresh Finds", subtitle: "New in your library", hue: 0.33, songs: fresh))
        }

        // On This Day: what you played on this date in earlier years
        let md = calendar.dateComponents([.month, .day, .year], from: now)
        let thatDay = history.filter {
            let c = calendar.dateComponents([.month, .day, .year], from: $0.at)
            return c.month == md.month && c.day == md.day && (c.year ?? 0) < (md.year ?? 0) && !$0.skipped
        }
        if thatDay.count >= 5 {
            var seen = Set<String>()
            let songs = thatDay.filter { seen.insert($0.id).inserted }.map(\.asSong)
            let year = thatDay.compactMap { calendar.dateComponents([.year], from: $0.at).year }.max() ?? 0
            mixes.append(Mix(id: "onthisday", kind: .onThisDay, title: "On This Day",
                             subtitle: "What you played on \(now.formatted(.dateTime.month(.wide).day())), \(year)",
                             hue: 0.75, songs: Array(songs.prefix(40))))
        }
        return mixes
    }

    /// Weighted random picks without repeats, at most 4 songs per artist and 2 per album,
    /// then spread out so the same artist doesn't play twice in a row.
    static func pick(_ pool: [Song], count: Int, rng: inout SeededRandom, perAlbum: Int = 2,
                     score: (Song) -> Double) -> [Song] {
        var seen = Set<String>()
        var items: [(Song, Double)] = []
        for s in pool where seen.insert(s.id).inserted {
            items.append((s, max(0.01, score(s))))
        }
        items.sort { $0.0.id < $1.0.id }           // stable order before the seeded draw
        var out: [Song] = []
        var perArtist: [String: Int] = [:], albums: [String: Int] = [:]
        while out.count < count, !items.isEmpty {
            let total = items.reduce(0) { $0 + $1.1 }
            var r = rng.unit() * total
            var idx = items.count - 1
            for (i, it) in items.enumerated() { r -= it.1; if r <= 0 { idx = i; break } }
            let s = items.remove(at: idx).0
            let a = key(s.artist ?? ""), al = s.albumId ?? s.album ?? s.id
            if perArtist[a, default: 0] >= 4 || albums[al, default: 0] >= perAlbum { continue }
            perArtist[a, default: 0] += 1; albums[al, default: 0] += 1
            out.append(s)
        }
        return spread(out)
    }

    static func spread(_ songs: [Song]) -> [Song] {
        var rest = songs, out: [Song] = []
        while !rest.isEmpty {
            let last = key(out.last?.artist ?? "")
            let i = rest.firstIndex { key($0.artist ?? "") != last } ?? 0
            out.append(rest.remove(at: i))
        }
        return out
    }

    static func hue(_ s: String) -> Double {
        var h: UInt32 = 2166136261
        for b in s.utf8 { h = (h ^ UInt32(b)) &* 16777619 }
        return Double(h % 1000) / 1000
    }

    static func dayKey(_ d: Date, _ cal: Calendar = .current) -> String {
        let c = cal.dateComponents([.year, .month, .day], from: d)
        return "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
    }

    static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

// MARK: - Loading and keeping today's mixes

@MainActor @Observable
final class MixStore {
    static let shared = MixStore()
    private(set) var mixes: [Mix] = []
    private(set) var loading = false
    var error: String?
    @ObservationIgnored private var builtFor = ""
    @ObservationIgnored private let file: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("mixes.json")

    private struct Saved: Codable { var key: String; var mixes: [Mix] }

    init() {
        if let data = try? Data(contentsOf: file), let s = try? JSONDecoder().decode(Saved.self, from: data) {
            mixes = s.mixes; builtFor = s.key
        }
    }

    /// The mixes change once a day, plus the time-of-day mix when the part of the day changes.
    static func currentKey(_ now: Date = .now) -> String {
        "\(Mixer.dayKey(now))-\(DayPart(hour: Calendar.current.component(.hour, from: now)).rawValue)"
    }

    func refresh(client: SubsonicClient, force: Bool = false) async {
        let key = Self.currentKey()
        guard force || key != builtFor || mixes.isEmpty, !loading, client.config.isComplete else { return }
        loading = true
        defer { loading = false }
        do {
            var lib = MixLibrary()
            async let frequent = client.albums("frequent", size: 40)
            async let recent = client.albums("recent", size: 30)
            async let newest = client.albums("newest", size: 12)
            async let sample = client.randomSongs(500)
            async let starred = client.starred()
            lib.frequent = (try? await frequent) ?? []
            lib.recent = (try? await recent) ?? []
            lib.sample = try await sample
            lib.starred = (try? await starred)?.song ?? []
            let newAlbums = (try? await newest) ?? []
            lib.fresh = await withTaskGroup(of: [Song].self) { g in
                for a in newAlbums { g.addTask { (try? await client.album(a.id).1) ?? [] } }
                var all: [Song] = []
                for await s in g { all += s }
                return all
            }
            let history = PlayHistory.shared.records
            let plan = Mixer.plan(lib, history)
            lib.pools = await withTaskGroup(of: (String, [Song]).self) { g in
                for k in plan.poolKeys {
                    g.addTask {
                        if k.hasPrefix("genre:") { return (k, (try? await client.songs(genre: String(k.dropFirst(6)), count: 300)) ?? []) }
                        let name = String(k.dropFirst(7))
                        let found = (try? await client.songs(matching: name, count: 80)) ?? []
                        return (k, found.filter { Mixer.key($0.artist ?? "").contains(Mixer.key(name)) })
                    }
                }
                var out: [String: [Song]] = [:]
                for await (k, v) in g { out[k] = v }
                return out
            }
            let built = Mixer.build(lib, history: history)
            mixes = built
            builtFor = key
            error = nil
            let saved = Saved(key: key, mixes: built), file = file
            Task.detached(priority: .utility) { try? JSONEncoder().encode(saved).write(to: file, options: .atomic) }
        } catch {
            if mixes.isEmpty { self.error = error.localizedDescription }
        }
    }
}
