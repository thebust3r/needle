import Foundation
import simd
import UIKit

/// What the visualizer hears each frame.
struct VizInput {
    var levels: [Float]      // 0...1, log-spaced bands, bass first
    var wave: [Float]        // -1...1 waveform samples
    var live: Bool           // false = nothing playing, show calm idle motion
}

/// How the visualizer looks: picked in the Customize sheet, remembered.
struct VizLook: Codable, Equatable {
    var theme: VizTheme = .album
    var intensity: Float = 1      // reactivity: 0.4 chill ... 2 max
    var trails: Float = 0.6       // 0 short ... 1 long
    var speed: Float = 1          // 0.4 slow ... 2 fast
    var mirror = false            // kaleidoscope
}

enum VizTheme: String, Codable, CaseIterable, Identifiable {
    case album, neon, fire, ice, vapor, toxic, mono
    var id: String { rawValue }
    var name: String {
        switch self {
        case .album: return "Album Colors"
        case .neon: return "Neon"
        case .fire: return "Fire"
        case .ice: return "Ice"
        case .vapor: return "Vaporwave"
        case .toxic: return "Toxic"
        case .mono: return "Mono"
        }
    }
    /// Fixed colors, or nil to follow the album.
    var colors: [SIMD3<Float>]? {
        switch self {
        case .album: return nil
        case .neon: return [[0.1, 0.95, 1], [1, 0.2, 0.85], [0.6, 1, 0.2]]
        case .fire: return [[1, 0.25, 0.05], [1, 0.62, 0.1], [1, 0.95, 0.5]]
        case .ice: return [[0.2, 0.55, 1], [0.35, 0.95, 1], [0.92, 0.97, 1]]
        case .vapor: return [[1, 0.42, 0.75], [0.62, 0.38, 1], [0.25, 0.95, 0.9]]
        case .toxic: return [[0.45, 1, 0.1], [0.1, 1, 0.55], [0.95, 1, 0.2]]
        case .mono: return [[1, 1, 1], [0.75, 0.78, 0.85], [0.5, 0.52, 0.6]]
        }
    }
}

/// Everything the shaders need for one frame (layout matches `struct U` in VizShaders).
struct VizUniforms {
    var res = SIMD4<Float>()      // width, height, time, flow
    var band = SIMD4<Float>()     // bass, mid, high, energy
    var look = SIMD4<Float>()     // beat, mode, trails, speed
    var more = SIMD4<Float>()     // mirror, calm
    var c1 = SIMD4<Float>(), c2 = SIMD4<Float>(), c3 = SIMD4<Float>()
    var touch = SIMD4<Float>(0.5, 0.5, 0, 10)
    var tap = SIMD4<Float>(0.5, 0.5, 0, 0)
}

/// The visualizer's brain: listens to the music and decides what the picture does. Drawing is done on the
/// graphics chip by `VizRenderer`. Same behavior as the web version:
/// - flashes are capped at 3 per second and kept soft (WCAG 2.3.1)
/// - Reduce Motion slows everything down and turns flashes off
/// - quiet songs are boosted so they react too; hits are instant and fall off smoothly
final class VizEngine {
    enum Mode: Int, CaseIterable {
        case tunnel, prism, hyper, melt, bars, nebula, mandala
        var name: String {
            switch self {
            case .tunnel: return "Warp Ring"
            case .prism: return "Prism"
            case .hyper: return "Hyperspace"
            case .melt: return "Melt"
            case .bars: return "Equalizer"
            case .nebula: return "Nebula"
            case .mandala: return "Mandala"
            }
        }
    }

    struct Stats {
        var frames = 0
        var beats = 0
        var flashes = 0
        var flashLog: [Double] = []
        var modeSwitches = 0
    }

    static let bins = 48

    var mode: Mode = .tunnel
    var auto = false
    var reducedMotion = false
    var look = VizLook()
    var onModeChange: ((Mode) -> Void)?

    private(set) var stats = Stats()
    private(set) var bass: Float = 0
    private(set) var mid: Float = 0
    private(set) var high: Float = 0
    private(set) var energy: Float = 0
    private(set) var beat: Float = 0
    /// 0...1 strength of the soft beat flash. Shown on a separate layer, never drawn into the trails.
    private(set) var flash: Float = 0
    private(set) var live = false
    private(set) var flow: Double = 0
    /// What gets drawn per band (after the quiet-song boost and smoothing), 0...~1.2.
    private(set) var shown = [Float](repeating: 0, count: VizEngine.bins)
    private(set) var wave = [Float](repeating: 0, count: 128)

    private var levels = [Float](repeating: 0, count: VizEngine.bins)
    private var peaks = [Float](repeating: 0.3, count: VizEngine.bins)
    private var rawBass: Float = 0
    private var baseHue: Double = 175
    private var bassAvg: Float = 0
    private var longAvg: Float = 0
    private var lastBeat: Double = -10
    private var quietSince: Double?
    private var lastSwitch: Double = 0
    private var flashTimes: [Double] = []

    // touch (fullscreen): drag swirls, tap bursts
    private(set) var touchSwirl: Float = 0
    private var touchPoint = SIMD2<Float>(0.5, 0.5)
    private var tapPoint = SIMD2<Float>(0.5, 0.5)
    private var tapTime: Double = -10
    private var clock: Double = 0

    func resetStats() { stats = Stats() }

    func setColor(_ color: UIColor) {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        if color.getHue(&h, saturation: &s, brightness: &b, alpha: &a), s > 0.05 { baseHue = Double(h) * 360 }
    }

    func next(_ step: Int = 1) {
        let all = Mode.allCases
        mode = all[((mode.rawValue + step) % all.count + all.count) % all.count]
    }

    /// Finger position in 0...1 screen coordinates (y down). `moved` is how far it went since the last call.
    func drag(to x: Float, _ y: Float, moved: Float) {
        touchPoint = SIMD2(x, 1 - y)
        touchSwirl = min(1.5, touchSwirl + moved * 6)
    }

    func tap(at x: Float, _ y: Float) {
        tapPoint = SIMD2(x, 1 - y)
        tapTime = clock
    }

    // MARK: - Listening

    /// Takes in one frame of sound. `time` and `dt` are in seconds.
    func update(time t: Double, dt: Double, input: VizInput) {
        clock = t
        let k = min(dt, 0.06) / (1.0 / 60.0)
        live = input.live
        if live, input.levels.count >= VizEngine.bins {
            for b in 0..<VizEngine.bins {
                let v = max(0, min(1, input.levels[b]))
                levels[b] = v > levels[b] ? v : levels[b] * 0.82 + v * 0.18
            }
            if input.wave.count > 1 {
                for i in 0..<128 { wave[i] = input.wave[Int(Double(i) / 127 * Double(input.wave.count - 1))] }
            }
        } else {
            for b in 0..<VizEngine.bins {
                levels[b] = Float(0.1 + 0.07 * sin(t * 1.1 + Double(b) * 0.35) * sin(t * 0.7 + Double(b) * 0.13))
            }
            for i in 0..<128 { wave[i] = Float(sin(Double(i) / 127 * .pi * 4 + t * 2) * 0.12) }
        }
        prepare(t, k: k)
        stats.frames += 1
    }

    private func prepare(_ t: Double, k: Double) {
        let I = look.intensity
        let fall = Float(pow(0.86, k)), idle = Float(pow(0.9, k)), peakFall = Float(pow(0.996, k))
        for b in 0..<VizEngine.bins {
            let v = levels[b]
            if !live { shown[b] = shown[b] * idle + v * 0.6 * (1 - idle); continue }   // paused: calm idle motion only
            peaks[b] = max(v, peaks[b] * peakFall, 0.12)                               // each band's recent loudest
            let norm = min(1.2, max(0, v * 0.3 + (v / peaks[b]) * 0.7 * min(1, v * 10))) * I   // boost quiet songs, keep silence dark
            shown[b] = norm > shown[b] ? norm : shown[b] * fall + norm * (1 - fall)
        }
        rawBass = levels[0..<6].reduce(0, +) / 6
        bass = shown[0..<6].reduce(0, +) / 6
        mid = shown[6..<25].reduce(0, +) / 19
        high = shown[25...].reduce(0, +) / Float(VizEngine.bins - 25)
        energy = (bass * 2 + mid + high) / 4

        // a beat = bass jumping clearly above its recent average (on the raw level, so safety limits never change)
        bassAvg = bassAvg * 0.9 + rawBass * 0.1
        longAvg = longAvg * 0.995 + rawBass * 0.005
        if live && rawBass > bassAvg * 1.12 + 0.035 && rawBass > 0.28 && t - lastBeat > 0.24 {
            lastBeat = t
            beat = 1
            stats.beats += 1
            onBeat(t)
        }
        beat *= Float(pow(reducedMotion ? 0.82 : 0.9, k))
        flash *= Float(pow(0.8, k))
        touchSwirl *= Float(pow(0.9, k))

        // a "drop": quiet for a while, then the bass slams back in
        if live && rawBass < longAvg * 0.6 {
            if quietSince == nil { quietSince = t }
        } else if let q = quietSince {
            if auto && t - q > 1.5 && rawBass > longAvg * 1.3 { switchMode(t) }
            quietSince = nil
        }
        // the slow current everything drifts along: always moving, faster when the music is busy
        flow += (k / 60) * Double(0.25 + 1.6 * energy) * Double(look.speed) * (reducedMotion ? 0.35 : 1)
        baseHue += (reducedMotion ? 0.05 : 0.15) * k
    }

    private func onBeat(_ t: Double) {
        flashTimes.removeAll { t - $0 > 1 }
        if !reducedMotion && flashTimes.count < 3 && energy > 0.35 {
            flashTimes.append(t)
            flash = 1
            stats.flashes += 1
            stats.flashLog.append(t)
            if stats.flashLog.count > 200 { stats.flashLog.removeFirst() }
        }
        if auto && t - lastSwitch > 45 { switchMode(t) }
    }

    private func switchMode(_ t: Double) {
        next()
        lastSwitch = t
        stats.modeSwitches += 1
        onModeChange?(mode)
    }

    // MARK: - For the renderer

    func palette() -> [SIMD3<Float>] {
        if let c = look.theme.colors { return c }
        return [Self.hsv(baseHue, 0.85, 1), Self.hsv(baseHue + 120, 0.85, 1), Self.hsv(baseHue + 220, 0.75, 1)]
    }

    func flashColor() -> CGColor {
        let c = palette()[1]
        return UIColor(red: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: 1).cgColor
    }

    func uniforms(width: Int, height: Int) -> VizUniforms {
        let c = palette()
        var u = VizUniforms()
        u.res = SIMD4(Float(width), Float(height), Float(clock.truncatingRemainder(dividingBy: 10_000)), Float(flow.truncatingRemainder(dividingBy: 10_000)))
        u.band = SIMD4(bass, mid, high, energy)
        u.look = SIMD4(reducedMotion ? beat * 0.4 : beat, Float(mode.rawValue), 0.80 + look.trails * 0.17, look.speed)
        u.more = SIMD4(look.mirror ? 1 : 0, reducedMotion ? 0.35 : 1, 0, 0)
        u.c1 = SIMD4(c[0], 1); u.c2 = SIMD4(c[1], 1); u.c3 = SIMD4(c[2], 1)
        u.touch = SIMD4(touchPoint.x, touchPoint.y, touchSwirl, Float(clock - tapTime))
        u.tap = SIMD4(tapPoint.x, tapPoint.y, 0, 0)
        return u
    }

    static func hsv(_ h: Double, _ s: Double, _ v: Double) -> SIMD3<Float> {
        let c = UIColor(hue: CGFloat(((h.truncatingRemainder(dividingBy: 360)) + 360).truncatingRemainder(dividingBy: 360) / 360),
                        saturation: CGFloat(s), brightness: CGFloat(v), alpha: 1)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        return SIMD3(Float(r), Float(g), Float(b))
    }
}
