import CoreGraphics
import Foundation
import UIKit

/// What the visualizer hears each frame.
struct VizInput {
    var levels: [Float]      // 0...1, log-spaced bands, bass first
    var wave: [Float]        // -1...1 waveform samples
    var live: Bool           // false = nothing playing, show calm idle motion
}

/// The visualizer: an original, Neon-spirited light show driven by the music.
/// Same behavior as the web version:
/// - flashes are capped at 3 per second and kept soft (WCAG 2.3.1)
/// - Reduce Motion slows everything down and turns flashes off
/// Drawing is plain Core Graphics into a bitmap, so it's easy to test and runs anywhere.
final class VizEngine {
    enum Mode: Int, CaseIterable {
        case tunnel, prism, hyper, melt
        var name: String {
            switch self {
            case .tunnel: return "Warp Ring"
            case .prism: return "Prism"
            case .hyper: return "Hyperspace"
            case .melt: return "Melt"
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
    var onModeChange: ((Mode) -> Void)?

    private(set) var stats = Stats()
    private(set) var width = 0
    private(set) var height = 0
    private(set) var bass: Float = 0
    private(set) var mid: Float = 0
    private(set) var high: Float = 0
    private(set) var energy: Float = 0
    private(set) var beat: Float = 0
    /// 0...1 strength of the soft beat flash. Shown on a separate layer, never drawn into the trails.
    private(set) var flash: Float = 0
    private(set) var live = false

    private var ctx: CGContext?
    private var levels = [Float](repeating: 0, count: VizEngine.bins)
    private var wave: [Float] = []
    private var baseHue: Double = 175
    private var bassAvg: Float = 0
    private var longAvg: Float = 0
    private var lastBeat: Double = -10
    private var quietSince: Double?
    private var lastSwitch: Double = 0
    private var flashTimes: [Double] = []

    private struct Star { var x: Double; var y: Double; var z: Double; var hue: Double }
    private var stars: [Star] = []

    private static let neon: [CGColor] = (0..<360).map {
        UIColor(hue: CGFloat($0) / 360, saturation: 0.82, brightness: 1, alpha: 1).cgColor
    }
    private static let neonDim: [CGColor] = (0..<360).map {
        UIColor(hue: CGFloat($0) / 360, saturation: 0.82, brightness: 1, alpha: 0.55).cgColor
    }

    init() {
        stars = (0..<260).map { _ in VizEngine.newStar(z: .random(in: 0...1)) }
    }

    private static func newStar(z: Double = 1) -> Star {
        Star(x: .random(in: -1...1), y: .random(in: -1...1), z: z, hue: .random(in: 0...120))
    }

    func resetStats() { stats = Stats() }

    func setColor(_ color: UIColor) {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        if color.getHue(&h, saturation: &s, brightness: &b, alpha: &a), s > 0.05 { baseHue = Double(h) * 360 }
    }

    func next(_ step: Int = 1) {
        let all = Mode.allCases
        mode = all[((mode.rawValue + step) % all.count + all.count) % all.count]
    }

    func flashColor() -> CGColor { VizEngine.neon[hueAt(200)] }

    // MARK: - Canvas

    func resize(width w: Int, height h: Int) {
        let w = max(32, w), h = max(32, h)
        guard w != width || h != height || ctx == nil else { return }
        width = w; height = h
        ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        ctx?.interpolationQuality = .low
        ctx?.setFillColor(UIColor.black.cgColor)
        ctx?.fill(CGRect(x: 0, y: 0, width: w, height: h))
    }

    /// Draws one frame. `time` and `dt` are in seconds.
    @discardableResult
    func render(time t: Double, dt: Double, input: VizInput) -> CGImage? {
        guard let g = ctx else { return nil }
        let k = min(dt, 0.06) / (1.0 / 60.0)
        listen(t, k: k, input: input)
        baseHue += (reducedMotion ? 0.05 : 0.15) * k
        let m = Double(min(width, height))
        switch mode {
        case .tunnel: drawTunnel(g, t, k, m)
        case .prism: drawPrism(g, t, k, m)
        case .hyper: drawHyper(g, t, k, m)
        case .melt: drawMelt(g, t, k, m)
        }
        g.setBlendMode(.normal)
        g.setAlpha(1)
        stats.frames += 1
        return g.makeImage()
    }

    // MARK: - Listening

    private func listen(_ t: Double, k: Double, input: VizInput) {
        live = input.live
        if live, input.levels.count >= VizEngine.bins {
            for b in 0..<VizEngine.bins {
                let v = max(0, min(1, input.levels[b]))
                levels[b] = v > levels[b] ? v : levels[b] * 0.82 + v * 0.18
            }
            wave = input.wave
        } else {
            for b in 0..<VizEngine.bins {
                levels[b] = Float(0.1 + 0.07 * sin(t * 1.1 + Double(b) * 0.35) * sin(t * 0.7 + Double(b) * 0.13))
            }
            wave = []
        }
        bass = levels[0..<6].reduce(0, +) / 6
        mid = levels[6..<25].reduce(0, +) / 19
        high = levels[25...].reduce(0, +) / Float(VizEngine.bins - 25)
        energy = (bass * 2 + mid + high) / 4

        // a beat = bass jumping clearly above its recent average
        bassAvg = bassAvg * 0.9 + bass * 0.1
        longAvg = longAvg * 0.995 + bass * 0.005
        if live && bass > bassAvg * 1.12 + 0.035 && bass > 0.28 && t - lastBeat > 0.24 {
            lastBeat = t
            beat = 1
            stats.beats += 1
            onBeat(t)
        }
        beat *= Float(pow(reducedMotion ? 0.82 : 0.9, k))
        flash *= Float(pow(0.8, k))

        // a "drop": quiet for a while, then the bass slams back in
        if live && bass < longAvg * 0.6 {
            if quietSince == nil { quietSince = t }
        } else if let q = quietSince {
            if auto && t - q > 1.5 && bass > longAvg * 1.3 { switchMode(t) }
            quietSince = nil
        }
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

    // MARK: - Drawing

    private func hueAt(_ offset: Double) -> Int { ((Int((baseHue + offset).rounded()) % 360) + 360) % 360 }

    private func sample(_ i: Int, _ count: Int) -> Double {
        guard live, wave.count > 1 else {
            return sin(Double(i) / Double(count) * .pi * 4 + Date().timeIntervalSinceReferenceDate * 2) * 0.15
        }
        return Double(wave[Int(Double(i) / Double(count) * Double(wave.count - 1))])
    }

    private func feedback(_ g: CGContext, zoom: Double, rot: Double, decay: Double, dx: Double = 0, dy: Double = 0) {
        guard let prev = g.makeImage() else { return }
        let w = Double(width), h = Double(height)
        g.setBlendMode(.copy)
        g.setFillColor(UIColor.black.cgColor)
        g.fill(CGRect(x: 0, y: 0, width: w, height: h))
        g.setBlendMode(.normal)
        g.saveGState()
        g.translateBy(x: w / 2 + dx, y: h / 2 + dy)
        g.rotate(by: rot)
        g.scaleBy(x: zoom, y: zoom)
        g.translateBy(x: -w / 2, y: -h / 2)
        g.setAlpha(decay)
        g.draw(prev, in: CGRect(x: 0, y: 0, width: w, height: h))
        g.restoreGState()
        g.setAlpha(1)
    }

    private func drawTunnel(_ g: CGContext, _ t: Double, _ k: Double, _ m: Double) {
        let slow = reducedMotion ? 0.35 : 1
        let b = Double(bass), be = Double(beat)
        feedback(g, zoom: 1 + (0.022 + b * 0.06 + be * 0.035) * slow, rot: (0.003 + Double(mid) * 0.012) * k * slow, decay: 0.84)
        g.setBlendMode(.plusLighter)
        let cx = Double(width) / 2, cy = Double(height) / 2
        let r0 = m * (0.1 + b * 0.07 + be * 0.05), len = m * 0.27
        g.setLineWidth(max(1.5, m * 0.009))
        g.setLineCap(.round)
        let spin = t * 0.4 * slow
        for side in 0..<2 {
            for i in 0..<VizEngine.bins {
                let a = spin + (side == 1 ? -1 : 1) * (Double(i) / Double(VizEngine.bins)) * .pi
                let l = r0 + Double(levels[i]) * len
                g.setStrokeColor(VizEngine.neonDim[hueAt(Double(i) * 2.5 + Double(side) * 40)])
                g.move(to: CGPoint(x: cx + cos(a) * r0, y: cy + sin(a) * r0))
                g.addLine(to: CGPoint(x: cx + cos(a) * l, y: cy + sin(a) * l))
                g.strokePath()
            }
        }
        if beat > 0.05 {
            g.setStrokeColor(VizEngine.neonDim[hueAt(180)])
            g.setAlpha(CGFloat(beat))
            g.setLineWidth(m * 0.012)
            let r = r0 * (1.3 + (1 - be) * 1.6)
            g.strokeEllipse(in: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
            g.setAlpha(1)
        }
    }

    private func drawPrism(_ g: CGContext, _ t: Double, _ k: Double, _ m: Double) {
        let slow = reducedMotion ? 0.35 : 1
        feedback(g, zoom: 0.982 - Double(beat) * 0.02 * slow, rot: -(0.005 + Double(high) * 0.02) * k * slow, decay: 0.82)
        g.setBlendMode(.plusLighter)
        let R = m * 0.48, pts = 48, amp = R * (0.18 + Double(energy) * 0.5)
        g.setLineWidth(max(1.5, m * 0.007))
        g.setLineJoin(.round)
        let turn = t * 0.25 * slow
        for s in 0..<6 {
            for mirror in 0..<2 {
                g.saveGState()
                g.translateBy(x: Double(width) / 2, y: Double(height) / 2)
                g.rotate(by: turn + Double(s) * .pi / 3)
                if mirror == 1 { g.scaleBy(x: 1, y: -1) }
                g.setStrokeColor(VizEngine.neon[hueAt(Double(s) * 60 + Double(mirror) * 25)])
                for i in 0...pts {
                    let x = Double(i) / Double(pts) * R, y = sample(i, pts) * amp * Double(i) / Double(pts)
                    i == 0 ? g.move(to: CGPoint(x: x, y: y)) : g.addLine(to: CGPoint(x: x, y: y))
                }
                g.strokePath()
                let r = m * (0.006 + Double(high) * 0.03 + Double(beat) * 0.012)
                g.setFillColor(VizEngine.neon[hueAt(Double(s) * 60 + 180)])
                g.fillEllipse(in: CGRect(x: R * 0.62 - r, y: sample(30, pts) * amp * 0.62 - r, width: r * 2, height: r * 2))
                g.restoreGState()
            }
        }
    }

    private func drawHyper(_ g: CGContext, _ t: Double, _ k: Double, _ m: Double) {
        let slow = reducedMotion ? 0.4 : 1
        feedback(g, zoom: 1, rot: 0.0012 * k * slow, decay: 0.74)
        g.setBlendMode(.plusLighter)
        let speed = (0.004 + Double(bass) * 0.028 + Double(beat) * 0.02) * k * slow
        let cx = Double(width) / 2, cy = Double(height) / 2, f = m * 0.5 * 0.35
        g.setLineCap(.round)
        for i in stars.indices {
            let z0 = stars[i].z
            stars[i].z -= speed
            if stars[i].z <= 0.03 { stars[i] = VizEngine.newStar(); continue }
            let st = stars[i]
            let x0 = cx + st.x / z0 * f, y0 = cy + st.y / z0 * f
            let x1 = cx + st.x / st.z * f, y1 = cy + st.y / st.z * f
            if x1 < -20 || x1 > Double(width) + 20 || y1 < -20 || y1 > Double(height) + 20 { stars[i] = VizEngine.newStar(); continue }
            g.setStrokeColor(VizEngine.neon[hueAt(st.hue + Double(high) * 90)])
            g.setLineWidth(max(1, (1 - st.z) * m * 0.009))
            g.move(to: CGPoint(x: x0, y: y0))
            g.addLine(to: CGPoint(x: x1, y: y1))
            g.strokePath()
        }
        g.setFillColor(VizEngine.neonDim[hueAt(0)])
        g.setAlpha(CGFloat(0.25 + Double(bass) * 0.5))
        let r = m * (0.02 + Double(bass) * 0.05 + Double(beat) * 0.03)
        g.fillEllipse(in: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
        g.setAlpha(1)
    }

    private func drawMelt(_ g: CGContext, _ t: Double, _ k: Double, _ m: Double) {
        let slow = reducedMotion ? 0.35 : 1
        let h = Double(height), w = Double(width)
        // Core Graphics has y pointing up, so a positive dy drifts the picture upward
        feedback(g, zoom: 1 + (0.01 + Double(bass) * 0.02) * slow, rot: sin(t * 0.5) * 0.004 * slow, decay: 0.88,
                 dy: 1.4 * k * slow * (h / 600))
        g.setBlendMode(.plusLighter)
        let pts = 64
        g.setLineJoin(.round)
        for line in 0..<3 {
            let yBase = h * (0.62 - Double(line) * 0.13)
            let amp = h * (0.08 + Double(mid) * 0.22 + Double(beat) * 0.05)
            g.setStrokeColor(VizEngine.neon[hueAt(Double(line) * 110 + t * 10)])
            g.setLineWidth(max(1.5, m * (0.006 + Double(line) * 0.002)))
            for i in 0...pts {
                let x = Double(i) / Double(pts) * w, y = yBase + sample((i + line * 9) % (pts + 1), pts) * amp
                i == 0 ? g.move(to: CGPoint(x: x, y: y)) : g.addLine(to: CGPoint(x: x, y: y))
            }
            g.strokePath()
        }
    }
}
