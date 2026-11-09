import SwiftUI
import UIKit

// MARK: - Colors you can save

/// A color as numbers, so a theme can be saved and edited.
struct RGBA: Codable, Equatable, Hashable {
    var r: Double
    var g: Double
    var b: Double
    var a: Double = 1

    init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    init(_ color: Color) {
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        if !UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a) {
            var w: CGFloat = 0
            UIColor(color).getWhite(&w, alpha: &a)
            r = w
            g = w
            b = w
        }
        self.r = Double(min(max(r, 0), 1))
        self.g = Double(min(max(g, 0), 1))
        self.b = Double(min(max(b, 0), 1))
        self.a = Double(min(max(a, 0), 1))
    }

    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }

    /// Blend toward another color (t = 0 is this one, 1 is the other).
    func mixed(_ o: RGBA, _ t: Double) -> RGBA {
        RGBA(r + (o.r - r) * t, g + (o.g - g) * t, b + (o.b - b) * t, a + (o.a - a) * t)
    }

    /// How bright it looks (0 black ... 1 white).
    var luminance: Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }

    static let white = RGBA(1, 1, 1)
    static let black = RGBA(0, 0, 0)
}

extension Color {
    func lighter(_ t: Double) -> Color { RGBA(self).mixed(.white, t).color }
    func darker(_ t: Double) -> Color { RGBA(self).mixed(.black, t).color }
}

// MARK: - The choices

enum LookFont: String, Codable, CaseIterable, Identifiable {
    case wide, rounded, serif, mono, condensed, classic
    var id: String { rawValue }
    var label: String {
        switch self {
        case .wide: return "Wide"
        case .rounded: return "Bubbly"
        case .serif: return "Serif"
        case .mono: return "Typewriter"
        case .condensed: return "Tall"
        case .classic: return "Classic"
        }
    }
    var design: Font.Design {
        switch self {
        case .rounded: return .rounded
        case .serif: return .serif
        case .mono: return .monospaced
        default: return .default
        }
    }
    /// The width used for big titles.
    var titleWidth: Font.Width {
        switch self {
        case .wide: return .expanded
        case .condensed: return .compressed
        default: return .standard
        }
    }
    var titleWeight: Font.Weight {
        switch self {
        case .rounded, .condensed: return .heavy
        case .mono: return .semibold
        default: return .bold
        }
    }
    func title(_ size: CGFloat) -> Font {
        .system(size: self == .condensed ? size * 1.12 : size, weight: titleWeight, design: design).width(titleWidth)
    }
}

/// How buttons, pills and bars are finished.
enum LookFinish: String, Codable, CaseIterable, Identifiable {
    case flat, glossy, glass
    var id: String { rawValue }
    var label: String {
        switch self {
        case .flat: return "Flat"
        case .glossy: return "Glossy"
        case .glass: return "Glass"
        }
    }
}

/// What's behind every screen.
enum LookBackdrop: String, Codable, CaseIterable, Identifiable {
    case solid, gradient, albumGlow, grid, stars, iridescent
    var id: String { rawValue }
    var label: String {
        switch self {
        case .solid: return "Solid"
        case .gradient: return "Glow"
        case .albumGlow: return "Album Colors"
        case .grid: return "Neon Grid"
        case .stars: return "Sparkles"
        case .iridescent: return "Burned CD"
        }
    }
}

enum LookTabBar: String, Codable, CaseIterable, Identifiable {
    case classic, floating, dock
    var id: String { rawValue }
    var label: String {
        switch self {
        case .classic: return "Classic"
        case .floating: return "Floating"
        case .dock: return "Dock"
        }
    }
}

enum LookMini: String, Codable, CaseIterable, Identifiable {
    case album, glass, accent
    var id: String { rawValue }
    var label: String {
        switch self {
        case .album: return "Album Colors"
        case .glass: return "Glass"
        case .accent: return "Accent"
        }
    }
}

enum NowPlayingStyle: String, Codable, CaseIterable, Identifiable {
    case art, vinyl, cd, cassette, visualizer
    var id: String { rawValue }
    var label: String {
        switch self {
        case .art: return "Big Art"
        case .vinyl: return "Vinyl"
        case .cd: return "CD"
        case .cassette: return "Cassette"
        case .visualizer: return "Visualizer"
        }
    }
    var icon: String {
        switch self {
        case .art: return "photo"
        case .vinyl: return "record.circle"
        case .cd: return "opticaldisc"
        case .cassette: return "recordingtape"
        case .visualizer: return "waveform"
        }
    }
}

// MARK: - A whole look

struct LookStyle: Codable, Equatable, Identifiable, Hashable {
    var id: String
    var name: String
    var background: RGBA
    var accent: RGBA
    var followArt: Bool
    var font: LookFont
    /// 0 square ... 1 normal ... 2 extra round.
    var roundness: Double
    var finish: LookFinish
    var backdrop: LookBackdrop
    var tabBar: LookTabBar
    var mini: LookMini
    var nowPlaying: NowPlayingStyle
    /// Made or changed by you (not one of the built-in looks).
    var custom: Bool = false

    init(id: String, name: String, background: RGBA, accent: RGBA, followArt: Bool, font: LookFont, roundness: Double,
         finish: LookFinish, backdrop: LookBackdrop, tabBar: LookTabBar, mini: LookMini, nowPlaying: NowPlayingStyle,
         custom: Bool = false) {
        self.id = id
        self.name = name
        self.background = background
        self.accent = accent
        self.followArt = followArt
        self.font = font
        self.roundness = roundness
        self.finish = finish
        self.backdrop = backdrop
        self.tabBar = tabBar
        self.mini = mini
        self.nowPlaying = nowPlaying
        self.custom = custom
    }

    // Saved looks from older versions may be missing newer settings: fill those in from the default look.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = LookStyle.chrome
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "My Look"
        background = try c.decodeIfPresent(RGBA.self, forKey: .background) ?? d.background
        accent = try c.decodeIfPresent(RGBA.self, forKey: .accent) ?? d.accent
        followArt = try c.decodeIfPresent(Bool.self, forKey: .followArt) ?? d.followArt
        font = (try? c.decodeIfPresent(LookFont.self, forKey: .font)) ?? d.font
        roundness = try c.decodeIfPresent(Double.self, forKey: .roundness) ?? d.roundness
        finish = (try? c.decodeIfPresent(LookFinish.self, forKey: .finish)) ?? d.finish
        backdrop = (try? c.decodeIfPresent(LookBackdrop.self, forKey: .backdrop)) ?? d.backdrop
        tabBar = (try? c.decodeIfPresent(LookTabBar.self, forKey: .tabBar)) ?? d.tabBar
        mini = (try? c.decodeIfPresent(LookMini.self, forKey: .mini)) ?? d.mini
        nowPlaying = (try? c.decodeIfPresent(NowPlayingStyle.self, forKey: .nowPlaying)) ?? d.nowPlaying
        custom = try c.decodeIfPresent(Bool.self, forKey: .custom) ?? true
    }

    /// Keeps text readable: the white text needs a dark background.
    var safeBackground: RGBA {
        background.luminance > 0.22 ? background.mixed(.black, min(0.85, (background.luminance - 0.22) / max(0.01, background.luminance))) : background
    }

    // The built-in looks
    static let chrome = LookStyle(id: "chrome", name: "Chrome", background: RGBA(0.05, 0.07, 0.14), accent: RGBA(0.50, 0.90, 1.0),
                                  followArt: false, font: .rounded, roundness: 1.45, finish: .glossy, backdrop: .stars,
                                  tabBar: .dock, mini: .glass, nowPlaying: .cd)
    static let burned = LookStyle(id: "burned", name: "Burned CD", background: RGBA(0.07, 0.05, 0.11), accent: RGBA(1.0, 0.56, 0.86),
                                  followArt: false, font: .wide, roundness: 1.1, finish: .glass, backdrop: .iridescent,
                                  tabBar: .floating, mini: .glass, nowPlaying: .cd)
    static let neon = LookStyle(id: "neon", name: "Neon Night", background: RGBA(0.03, 0.02, 0.06), accent: RGBA(1.0, 0.26, 0.64),
                                followArt: false, font: .condensed, roundness: 0.55, finish: .flat, backdrop: .grid,
                                tabBar: .floating, mini: .accent, nowPlaying: .visualizer)
    static let analog = LookStyle(id: "analog", name: "Analog", background: RGBA(0.09, 0.07, 0.05), accent: RGBA(1.0, 0.62, 0.30),
                                  followArt: false, font: .serif, roundness: 0.8, finish: .glossy, backdrop: .gradient,
                                  tabBar: .classic, mini: .album, nowPlaying: .cassette)
    static let glow = LookStyle(id: "glow", name: "Album Glow", background: RGBA(0.05, 0.05, 0.07), accent: RGBA(0.43, 0.91, 0.85),
                                followArt: true, font: .rounded, roundness: 1.3, finish: .glass, backdrop: .albumGlow,
                                tabBar: .floating, mini: .album, nowPlaying: .art)
    static let vinylRoom = LookStyle(id: "vinyl", name: "Record Room", background: RGBA(0.06, 0.06, 0.06), accent: RGBA(0.95, 0.80, 0.35),
                                     followArt: false, font: .mono, roundness: 0.7, finish: .flat, backdrop: .solid,
                                     tabBar: .classic, mini: .album, nowPlaying: .vinyl)
    static let classic = LookStyle(id: "classic", name: "Classic", background: RGBA(0.055, 0.058, 0.075), accent: RGBA(0.43, 0.91, 0.85),
                                   followArt: false, font: .wide, roundness: 1.0, finish: .flat, backdrop: .solid,
                                   tabBar: .classic, mini: .album, nowPlaying: .art)

    static let presets: [LookStyle] = [.chrome, .burned, .neon, .analog, .glow, .vinylRoom, .classic]
}

// MARK: - The look in use

/// The look the app is wearing right now, and the looks you saved. Views that read it redraw when it changes.
@Observable final class Look {
    static let shared = Look()

    var style: LookStyle {
        didSet { if style != oldValue { save() } }
    }
    private(set) var saved: [LookStyle]

    private static let styleKey = "look.style"
    private static let savedKey = "look.saved"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let env = ProcessInfo.processInfo.environment
        if let id = env["UITEST_LOOK"], let p = LookStyle.presets.first(where: { $0.id == id }) {
            style = p
        } else if let d = defaults.data(forKey: Self.styleKey), let s = try? JSONDecoder().decode(LookStyle.self, from: d) {
            style = s
        } else {
            style = .chrome
        }
        if let d = defaults.data(forKey: Self.savedKey), let s = try? JSONDecoder().decode([LookStyle].self, from: d) {
            saved = s
        } else {
            saved = []
        }
    }

    @ObservationIgnored private let defaults: UserDefaults

    private func save() {
        if let d = try? JSONEncoder().encode(style) { defaults.set(d, forKey: Self.styleKey) }
        if let d = try? JSONEncoder().encode(saved) { defaults.set(d, forKey: Self.savedKey) }
    }

    /// Changes one setting; the look becomes your own (custom) from then on.
    func edit(_ change: (inout LookStyle) -> Void) {
        var s = style
        change(&s)
        if !s.custom {
            s.custom = true
            s.id = UUID().uuidString
            s.name = "My \(style.name)"
        }
        style = s
    }

    func use(_ s: LookStyle) { style = s }

    /// Keeps the current look in "Your Looks" (replacing an older copy of it).
    func saveCurrent(named name: String) {
        var s = style
        s.name = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "My Look" : name.trimmingCharacters(in: .whitespacesAndNewlines)
        s.custom = true
        if let i = saved.firstIndex(where: { $0.id == s.id }) {
            saved[i] = s
        } else {
            saved.insert(s, at: 0)
        }
        style = s
        save()
    }

    func delete(_ s: LookStyle) {
        saved.removeAll { $0.id == s.id }
        save()
    }

    var background: Color { style.safeBackground.color }
    var surface: Color { style.safeBackground.mixed(.white, 0.07).color }
    var accent: Color {
        if style.followArt, let c = AccentStore.shared.albumColor { return c }
        return style.accent.color
    }
}

// MARK: - What the screens use

enum Theme {
    static var background: Color { Look.shared.background }
    static var surface: Color { Look.shared.surface }
    static let line = Color.white.opacity(0.08)
    static let secondary = Color.white.opacity(0.62)
    static let tertiary = Color.white.opacity(0.38)
    /// Your look's accent, or the playing album's color when it follows the art.
    static var accent: Color { Look.shared.accent }

    static func title(_ size: CGFloat) -> Font { Look.shared.style.font.title(size) }
    /// A corner radius scaled by how round your look is.
    static func corner(_ base: CGFloat) -> CGFloat { base * CGFloat(Look.shared.style.roundness) }
}

// MARK: - Home layout

/// The sections on Home, in the order you put them; hidden ones don't show.
enum HomeSection: String, Codable, CaseIterable, Identifiable {
    case continueListening, quickPicks, madeForYou, newInLibrary, wrapped, onThisIPhone
    var id: String { rawValue }
    var label: String {
        switch self {
        case .continueListening: return "Continue Listening"
        case .quickPicks: return "Quick Picks"
        case .madeForYou: return "Made for You"
        case .newInLibrary: return "New in Your Library"
        case .wrapped: return "Your Wrapped"
        case .onThisIPhone: return "On This iPhone"
        }
    }
    var icon: String {
        switch self {
        case .continueListening: return "play.circle"
        case .quickPicks: return "square.grid.2x2"
        case .madeForYou: return "sparkles.rectangle.stack"
        case .newInLibrary: return "clock.arrow.circlepath"
        case .wrapped: return "sparkles"
        case .onThisIPhone: return "iphone"
        }
    }
}

@Observable final class HomeLayout {
    static let shared = HomeLayout()

    private(set) var order: [HomeSection]
    private(set) var hidden: Set<HomeSection>

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = (defaults.stringArray(forKey: "home.order") ?? []).compactMap(HomeSection.init(rawValue:))
        // keep what you arranged, and add any sections newer versions brought in
        order = saved + HomeSection.allCases.filter { !saved.contains($0) }
        hidden = Set((defaults.stringArray(forKey: "home.hidden") ?? []).compactMap(HomeSection.init(rawValue:)))
    }

    var visible: [HomeSection] { order.filter { !hidden.contains($0) } }

    func move(from: IndexSet, to: Int) {
        order.move(fromOffsets: from, toOffset: to)
        save()
    }

    func setShown(_ s: HomeSection, _ shown: Bool) {
        if shown { hidden.remove(s) } else { hidden.insert(s) }
        save()
    }

    func reset() {
        order = HomeSection.allCases
        hidden = []
        save()
    }

    private func save() {
        defaults.set(order.map(\.rawValue), forKey: "home.order")
        defaults.set(hidden.map(\.rawValue).sorted(), forKey: "home.hidden")
    }
}
