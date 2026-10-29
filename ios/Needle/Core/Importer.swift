import Foundation

/// One Spotify playlist (or pasted list) being turned into a Navidrome playlist by the helper on the NAS.
struct ImportJob: Decodable, Identifiable, Equatable {
    struct Progress: Decodable, Equatable { var done: Int; var total: Int }
    let id: String
    var name: String
    var state: String               // reading, matching, ready, error
    var error: String?
    var note: String?
    var playlistId: String?
    var found: Int
    var active: Bool
    var counts: [String: Int]?
    var progress: Progress?
    var tracks: [ImportTrack]?
    var created: Double?

    var isWorking: Bool { state == "reading" || state == "matching" }
    var missing: [ImportTrack] { (tracks ?? []).filter { $0.status == "missing" || $0.status == "failed" } }
    var total: Int { tracks?.count ?? counts?.values.reduce(0, +) ?? progress?.total ?? 0 }

    var summary: String {
        switch state {
        case "error": return error ?? "Didn't work"
        case "reading": return "Reading the playlist…"
        case "matching": return "Checking your library… \(progress?.done ?? 0) of \(progress?.total ?? 0)"
        default:
            let c = counts ?? [:]
            let busy = ImportTrack.activeStates.reduce(0) { $0 + (c[$1] ?? 0) }
            var s = "\(found) of \(total) in your library"
            if busy > 0 { s += " · \(busy) on the way" }
            if let f = c["failed"], f > 0 { s += " · \(f) not found" }
            return s
        }
    }

    var fraction: Double {
        if isWorking { return Double(progress?.done ?? 0) / Double(max(1, progress?.total ?? 0)) }
        return Double(found) / Double(max(1, total))
    }
}

struct ImportTrack: Decodable, Identifiable, Equatable {
    static let activeStates = ["queued", "searching", "downloading", "importing", "requesting", "album"]
    let i: Int
    var title: String
    var artists: [String]?
    var status: String
    var note: String?
    var progress: Int?
    var id: Int { i }

    var isActive: Bool { Self.activeStates.contains(status) }
    var artist: String { artists?.first ?? "" }

    var label: String {
        switch status {
        case "found": return note != nil ? "Added" : ""
        case "missing": return "Missing"
        case "matching": return "Checking…"
        case "queued": return "Waiting…"
        case "searching": return "Searching…"
        case "downloading": return (note ?? "").hasPrefix("Waiting") ? "In their queue" : "Downloading \(progress ?? 0)%"
        case "importing": return "Adding…"
        case "requesting": return "Asking Lidarr…"
        case "album": return "Getting album…"
        case "failed": return "Not found"
        default: return status
        }
    }
}

struct HelperStatus: Decodable { var soulseek: Bool; var lidarr: Bool }

enum HelperProblem: LocalizedError {
    case notRunning, noAddress, message(String)
    var errorDescription: String? {
        switch self {
        case .notRunning: return "The import helper isn't running. Update the Platter project on the NAS (the one called needle) with the new compose file, and check the Platter web address in Settings."
        case .noAddress: return "Add your server in Settings first."
        case .message(let m): return m
        }
    }
}

/// Talks to the helper that runs next to the Needle web player (http://NAS:8795/helper/).
struct HelperClient {
    let config: ServerConfig
    let address: String
    var session: URLSession = .shared

    /// The web player's address: the one typed in Settings, or the server's host on port 8795.
    static func baseURL(address: String, config: ServerConfig) -> URL? {
        var s = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty {
            guard let server = config.baseURL, let host = server.host else { return nil }
            // Navidrome straight on its own port (at home): the web player is next door on 8795.
            // Anything else (a Cloudflare tunnel to the web player) already serves the helper too.
            if server.port == 4533 { return URL(string: "http://\(host):8795") }
            return server
        }
        if !s.lowercased().hasPrefix("http") { s = "http://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        return URL(string: s)
    }

    func url(_ path: String) -> URL? {
        guard let base = Self.baseURL(address: address, config: config),
              var comps = URLComponents(url: base.appendingPathComponent("helper/" + path), resolvingAgainstBaseURL: false)
        else { return nil }
        comps.queryItems = SubsonicClient(config: config).authItems()
        return comps.url
    }

    private func send<T: Decodable>(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> T {
        guard config.isComplete, let url = url(path) else { throw HelperProblem.noAddress }
        var req = SubsonicClient(config: config).request(for: url)
        req.httpMethod = method
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: req) } catch let e as URLError where e.code != .cancelled {
            throw HelperProblem.notRunning
        }
        let http = response as? HTTPURLResponse
        guard (http?.value(forHTTPHeaderField: "Content-Type") ?? "").contains("json") else { throw HelperProblem.notRunning }
        if let code = http?.statusCode, !(200..<300).contains(code) {
            let msg = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
            throw HelperProblem.message(msg ?? "The helper answered with error \(code).")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    struct JobList: Decodable { var jobs: [ImportJob] }
    struct OK: Decodable { var ok: Bool? }

    func status() async throws -> HelperStatus { try await send("status") }
    func jobs() async throws -> [ImportJob] { (try await send("jobs") as JobList).jobs }
    func job(_ id: String) async throws -> ImportJob { try await send("jobs/\(id)") }
    func start(source: String, name: String) async throws -> ImportJob {
        try await send("import", method: "POST", body: ["source": source, "name": name])
    }
    func download(_ id: String, method: String, indexes: [Int]) async throws -> ImportJob {
        try await send("jobs/\(id)/download", method: "POST", body: ["method": method, "indexes": indexes])
    }
    func remove(_ id: String) async throws { _ = try await send("jobs/\(id)", method: "DELETE") as OK }

    // the listening history shared by the app and the web (for Wrapped)
    struct Plays: Decodable { var plays: [SharedPlay] }
    func history() async throws -> [SharedPlay] { (try await send("history") as Plays).plays }
    func uploadHistory(_ plays: [SharedPlay]) async throws {
        let body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(["plays": plays]))
        _ = try await send("history", method: "POST", body: body as? [String: Any]) as OK
    }
}
