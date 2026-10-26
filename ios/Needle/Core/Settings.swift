import Foundation
import Observation
import Security

/// Server address and login. Saved in the iPhone Keychain, never in plain files.
struct ServerConfig: Codable, Equatable {
    var url: String = ""
    var username: String = ""
    var password: String = ""
    var accessClientId: String = ""
    var accessClientSecret: String = ""

    var isComplete: Bool { baseURL != nil && !username.isEmpty && !password.isEmpty }

    var baseURL: URL? {
        var s = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.lowercased().hasPrefix("http") { s = "https://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        return URL(string: s)
    }
}

enum StreamQuality: String, Codable, CaseIterable, Identifiable {
    case original, high, saver
    var id: String { rawValue }
    var label: String {
        switch self {
        case .original: return "Original"
        case .high: return "High (320 kbps)"
        case .saver: return "Data Saver (160 kbps)"
        }
    }
    var maxBitRate: Int? {
        switch self {
        case .original: return nil
        case .high: return 320
        case .saver: return 160
        }
    }
}

@Observable
final class AppSettings {
    var config: ServerConfig {
        didSet { Keychain.save(config, key: "server-config") }
    }
    var quality: StreamQuality {
        didSet { UserDefaults.standard.set(quality.rawValue, forKey: "quality") }
    }
    var cacheLimitGB: Double {
        didSet { UserDefaults.standard.set(cacheLimitGB, forKey: "cacheLimitGB") }
    }
    /// Where the Needle web player runs (for playlist import). Blank = the server's host on port 8795.
    var helperAddress: String {
        didSet { UserDefaults.standard.set(helperAddress, forKey: "helperAddress") }
    }

    init() {
        config = Keychain.load(ServerConfig.self, key: "server-config") ?? ServerConfig()
        quality = StreamQuality(rawValue: UserDefaults.standard.string(forKey: "quality") ?? "") ?? .original
        let limit = UserDefaults.standard.double(forKey: "cacheLimitGB")
        cacheLimitGB = limit > 0 ? limit : 2
        helperAddress = UserDefaults.standard.string(forKey: "helperAddress") ?? ""
    }
}

enum Keychain {
    static func save<T: Encodable>(_ value: T, key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrAccount as String: key]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrAccount as String: key,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
