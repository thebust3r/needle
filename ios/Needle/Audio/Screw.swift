import Accelerate
import Foundation
import Observation
import os

// MARK: - Settings

/// Slowed / chopped & screwed. Speed changes the whole sound like a record turning slower
/// (pitch drops with it); chops cut back a beat on the rhythm, the way DJ Screw switched between
/// two copies of the same record playing a beat apart.
enum ScrewSpeed: String, CaseIterable, Identifiable, Codable {
    case off, slowed, screwed, syrup, spedUp
    var id: String { rawValue }
    var rate: Float {
        switch self {
        case .off: return 1
        case .slowed: return 0.88
        case .screwed: return 0.80
        case .syrup: return 0.72
        case .spedUp: return 1.18
        }
    }
    var label: String {
        switch self {
        case .off: return "Off"
        case .slowed: return "Slowed"
        case .screwed: return "Screwed"
        case .syrup: return "Syrup"
        case .spedUp: return "Sped Up"
        }
    }
    var detail: String {
        switch self {
        case .off: return "Normal speed"
        case .slowed: return "A little slower and deeper"
        case .screwed: return "DJ Screw speed"
        case .syrup: return "Extra slow and heavy"
        case .spedUp: return "Faster and higher"
        }
    }
}

enum ChopAmount: String, CaseIterable, Identifiable, Codable {
    case off, light, heavy, live   // live = no automatic chops, you tap them
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    /// How many beats between chances to chop, and how likely a chop is at each chance.
    var every: Int { 4 }
    var chance: Double { self == .heavy ? 1 : 0.45 }
    /// Which moves, and how often: heavy picks the wilder ones more.
    var picks: [(ChopMove, Double)] {
        switch self {
        case .off, .live: return []
        case .light: return [(.runBack, 0.45), (.repeatBeat, 0.3), (.stutter, 0.15), (.doubleUp, 0.1)]
        case .heavy: return [(.stutter, 0.3), (.runBack, 0.25), (.doubleUp, 0.2), (.repeatBeat, 0.1), (.backItUp, 0.15)]
        }
    }
}

/// The moves, as cuts between the live record and copies that are behind. Each cut is (length, delay) in beats;
/// the song keeps running underneath, like the second deck.
enum ChopMove: Int, CaseIterable {
    case repeatBeat, runBack, stutter, doubleUp, backItUp, loop
    var cuts: [(Double, Double)] {
        switch self {
        case .repeatBeat: return [(1, 1)]                          // hear the last beat again
        case .runBack: return [(2, 2)]                             // run back the last two beats (about a line)
        case .stutter: return [(0.5, 0.5), (0.5, 1), (0.5, 1.5)]   // "ch-ch-ch": the same half beat three times
        case .doubleUp: return [(1, 1), (1, 2)]                    // the last beat twice
        case .backItUp: return [(4, 4)]                            // back up a whole bar
        case .loop: return [(1, 1)]                                // live: the last beat, over and over while held
        }
    }
    var label: String {
        switch self {
        case .repeatBeat: return "Repeat"
        case .runBack: return "Run it back"
        case .stutter: return "Stutter"
        case .doubleUp: return "Double up"
        case .backItUp: return "Back it up"
        case .loop: return "Loop"
        }
    }
}

/// What the chopper is doing right now, for the Screw sheet ("Locked on beat · 72 BPM").
struct ScrewStatus: Equatable {
    var bpm: Double = 0
    var confidence: Double = 0
    var chops = 0
    var last: ChopMove?
    var locked: Bool { confidence > 0.15 && bpm > 0 }
}

/// Shared by the UI (main thread) and the audio thread. Reads are cheap and lock-protected.
final class ScrewSettings: @unchecked Sendable {
    static let shared = ScrewSettings()
    private var lock = os_unfair_lock()
    private var _speed: ScrewSpeed
    private var _chops: ChopAmount

    init() {
        let d = UserDefaults.standard
        _speed = ScrewSpeed(rawValue: d.string(forKey: "screw.speed") ?? "") ?? .off
        _chops = ChopAmount(rawValue: d.string(forKey: "screw.chops") ?? "") ?? .off
    }

    var speed: ScrewSpeed {
        get { os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }; return _speed }
        set { os_unfair_lock_lock(&lock); _speed = newValue; os_unfair_lock_unlock(&lock); UserDefaults.standard.set(newValue.rawValue, forKey: "screw.speed") }
    }
    var chops: ChopAmount {
        get { os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }; return _chops }
        set { os_unfair_lock_lock(&lock); _chops = newValue; os_unfair_lock_unlock(&lock); UserDefaults.standard.set(newValue.rawValue, forKey: "screw.chops") }
    }
    var isOn: Bool { speed != .off || chops != .off }

    // live chops: taps from the UI, picked up by the audio thread on its next block
    private var _pending: ChopMove?
    private var _pendingHold = false
    private var _release = false
    func tap(_ move: ChopMove, hold: Bool = false) {
        os_unfair_lock_lock(&lock); _pending = move; _pendingHold = hold; _release = false; os_unfair_lock_unlock(&lock)
    }
    func release() { os_unfair_lock_lock(&lock); _release = true; os_unfair_lock_unlock(&lock) }
    /// Audio thread: what was tapped since last time.
    func takeTaps() -> (move: ChopMove?, hold: Bool, release: Bool) {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        let r = (_pending, _pendingHold, _release)
        _pending = nil; _release = false
        return r
    }

    private var _status = ScrewStatus()
    /// Written by the audio thread about once a second, read by the UI.
    var status: ScrewStatus {
        get { os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }; return _status }
        set { os_unfair_lock_lock(&lock); _status = newValue; os_unfair_lock_unlock(&lock) }
    }
}

// MARK: - Beat tracking

/// Finds the tempo and where the beats fall, from the audio as it plays (same as the web player's chop-worklet.js).
/// Onsets: spectral flux (1024-point FFT every 512 samples, 24 log-spaced bands). Tempo: an autocorrelation of that,
/// averaged over ~6 s so it doesn't flip between tempos, with votes from half a beat, 2 and 4 beats so it picks the
/// real pulse. Beats: the offset whose evenly spaced hits are strongest over the last 12 beats.
/// Tuned on real songs: see web/tests/beats/README-beats.md.
final class BeatTracker {
    let sampleRate: Double
    static let hop = 512
    static let N = 1024
    private let maxHops: Int
    private var env: [Float]
    private var buf: [Float]
    private var re: [Float], im: [Float]
    private let window: [Float]
    private let fftSetup: FFTSetup?
    private let edges: [Int]
    private var prevBands = [Float](repeating: 0, count: 24)
    private var hist = [Float](repeating: 0, count: 16)
    private var histSum: Float = 0
    private var fill = 0
    private var A: [Double]
    private var lin: [Double]
    private var sc: [Double]
    private var ph: [Double]
    private var envCount = 0
    private var sinceEstimate = 0
    private var estimates = 0
    private let minLag: Int, maxLag: Int
    private(set) var level: Float = 0        // slow running loudness

    // tuning (same as the web)
    private let ema = 0.96, center = 107.0, sigma = 0.6, hyst = 1.12, combBeats = 12, conf0 = 0.06, conf1 = 0.2
    private let harm = (0.25, 0.5, 0.25)     // votes from half a beat, 2 beats, 4 beats

    /// Samples per beat, or 0 while still listening.
    private(set) var period: Double = 0
    /// Sample index of a beat (any beat; the others are this plus whole periods).
    private(set) var anchor: Double = 0
    /// 0...1: how clearly the music has a steady beat.
    private(set) var confidence: Double = 0
    private(set) var samplesSeen = 0

    var bpm: Double { period > 0 ? 60 * sampleRate / period : 0 }

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        let N = Self.N
        maxHops = Int(8.0 * sampleRate / Double(Self.hop))
        env = [Float](repeating: 0, count: maxHops)
        buf = [Float](repeating: 0, count: N)
        re = [Float](repeating: 0, count: N); im = [Float](repeating: 0, count: N)
        window = (0..<N).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(N - 1))) }
        fftSetup = vDSP_create_fftsetup(vDSP_Length(log2(Double(N))), FFTRadix(kFFTRadix2))
        let binHz = sampleRate / Double(N)
        edges = (0...24).map { b in max(1, Int((40 * pow(11000.0 / 40, Double(b) / 24) / binHz).rounded())) }
        let hps = sampleRate / Double(Self.hop)
        minLag = Int(hps * 60 / 190); maxLag = Int((hps * 60 / 50).rounded(.up))
        A = [Double](repeating: 0, count: 4 * maxLag + 4)
        lin = [Double](repeating: 0, count: maxHops)
        sc = [Double](repeating: 0, count: maxLag + 2)
        ph = [Double](repeating: 0, count: maxLag + 2)
    }

    func reset() {
        envCount = 0; fill = 0; period = 0; anchor = 0; confidence = 0; samplesSeen = 0; sinceEstimate = 0; level = 0
        estimates = 0; histSum = 0
        for i in env.indices { env[i] = 0 }
        for i in buf.indices { buf[i] = 0 }
        for i in prevBands.indices { prevBands[i] = 0 }
        for i in hist.indices { hist[i] = 0 }
        for i in A.indices { A[i] = 0 }
    }

    func feed(_ x: UnsafePointer<Float>, count: Int, stride: Int = 1) {
        let N = Self.N, hop = Self.hop
        for i in 0..<count {
            let s = x[i * stride]
            level = level * 0.99998 + s * s * 0.00002
            buf[fill] = s; fill += 1
            if fill == N {
                frame()
                for j in 0..<(N - hop) { buf[j] = buf[j + hop] }
                fill = N - hop
            }
        }
        samplesSeen += count
    }

    deinit { if let fftSetup { vDSP_destroy_fftsetup(fftSetup) } }

    /// In-place complex FFT of re/im (unscaled, like the web version's).
    private func fft() {
        guard let fftSetup else { return }
        re.withUnsafeMutableBufferPointer { r in
            im.withUnsafeMutableBufferPointer { i in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                vDSP_fft_zip(fftSetup, &split, 1, vDSP_Length(log2(Double(Self.N))), FFTDirection(kFFTDirection_Forward))
            }
        }
    }

    private func frame() {
        for i in 0..<Self.N { re[i] = buf[i] * window[i]; im[i] = 0 }
        fft()
        var flux: Float = 0
        for b in 0..<24 {
            let a = edges[b], e = max(a + 1, edges[b + 1])
            var s: Float = 0
            for k in a..<e { s += (re[k] * re[k] + im[k] * im[k]).squareRoot() }
            let v = log1p(10 * s / Float(e - a))
            flux += max(0, v - prevBands[b])
            prevBands[b] = v
        }
        flux /= 24
        // take away the slowly-moving part (busy passages vs sparse ones), keep the hits
        let k = envCount % 16
        histSum += flux - hist[k]; hist[k] = flux
        env[envCount % maxHops] = max(0, flux - histSum / 16)
        envCount += 1
        sinceEstimate += 1
        let hps = sampleRate / Double(Self.hop)
        if sinceEstimate >= Int(0.25 * hps), envCount >= Int(3 * hps) { sinceEstimate = 0; estimate() }
    }

    private func e(_ i: Int) -> Double {     // onset at an absolute hop index (0 if forgotten or not yet here)
        guard i >= 0, i < envCount, envCount - i <= maxHops else { return 0 }
        return Double(env[i % maxHops])
    }

    private func estimate() {
        let n = min(envCount, maxHops), hps = sampleRate / Double(Self.hop), start = envCount - n
        var mean = 0.0
        for i in start..<envCount { mean += e(i) }
        mean /= Double(n)
        // lightly smoothed, so a beat that falls between two analysis steps (e.g. 120 BPM at 48 kHz) still counts fully
        var var0 = 0.0
        for k in 0..<n {
            let i = start + k
            let v = 0.25 * e(i - 1) + 0.5 * e(i) + 0.25 * e(i + 1) - mean
            lin[k] = v; var0 += v * v
        }
        var0 /= Double(n)
        let loud = level > 0.0001                 // about -40 dB: actual music, not hiss or a fade
        guard var0 > 1e-12, loud else {           // too quiet to learn from: forget, start fresh when it comes in
            confidence = 0; estimates = 0; period = 0; return
        }
        // average evenly while warming up, then a ~6 s memory
        let w = min(ema, Double(estimates) / Double(estimates + 1))
        lin.withUnsafeBufferPointer { x in
            A.withUnsafeMutableBufferPointer { A in
                for lag in (minLag / 2)...(4 * maxLag + 3) {
                    var r = 0.0
                    if lag < n {
                        var s = 0.0, i = lag
                        while i < n { s += x[i] * x[i - lag]; i += 1 }
                        r = s / Double(n - lag) / var0
                    }
                    A[lag] = A[lag] * w + r * (1 - w)
                }
            }
        }
        estimates += 1
        let cur = period > 0 ? period / Double(Self.hop) : 0
        func at(_ l: Double) -> Double { max(0, A[Int(l.rounded(.down))], A[Int(l.rounded(.up))]) }
        var best = -1.0, bestLag = 0
        for lag in minLag...maxLag {
            var v = (A[lag] + harm.0 * at(Double(lag) / 2) + harm.1 * max(0, A[2 * lag]) + harm.2 * max(0, A[4 * lag]))
                / (1 + harm.0 + harm.1 + harm.2)
            let oct = log2(60 * hps / Double(lag) / center)
            v *= exp(-0.5 * oct * oct / (sigma * sigma))
            if cur > 0, abs(Double(lag) / cur - 1) < 0.04 { v *= hyst }    // stick with the tempo we have unless something's clearly better
            sc[lag] = v
            if v > best { best = v; bestLag = lag }
        }
        guard bestLag > minLag, bestLag < maxLag else { confidence = 0; return }
        let l = sc[bestLag - 1], r = sc[bestLag + 1], den = l - 2 * best + r
        var lag = Double(bestLag)
        if den < 0 { lag += max(-0.5, min(0.5, 0.5 * (l - r) / den)) }
        let peak = A[bestLag]
        // real music has sharp hits; steady tones, noise and room sound only make small, even ripples
        var hit = 0.0
        for i in (envCount - Int(2 * hps))..<envCount { hit = max(hit, e(i)) }
        let hits = max(0, min(1, (hit - 0.4) / 0.12))
        let settled = min(1, Double(estimates) / 12)         // ~3 s of listening before trusting the tempo
        confidence = settled * hits * max(0, min(1, (peak - conf0) / (conf1 - conf0)))

        // beats: the offset whose evenly spaced hits are strongest over the last few beats (recent ones count more)
        let steps = max(1, min(Int(lag), ph.count))
        var bp = 0, bs = -1.0
        for off in 0..<steps {
            var s = 0.0
            for k in 0..<combBeats {
                let idx = envCount - 1 - off - Int((Double(k) * lag).rounded())
                let wk = 1 - Double(k) / (Double(combBeats) * 1.5)
                s += wk * (e(idx) + 0.5 * (e(idx - 1) + e(idx + 1)))
            }
            ph[off] = s
            if s > bs { bs = s; bp = off }
        }
        let pl = ph[(bp - 1 + steps) % steps], pr = ph[(bp + 1) % steps], pd = pl - 2 * bs + pr
        let frac = pd < 0 ? max(-0.5, min(0.5, 0.5 * (pl - pr) / pd)) : 0
        let newPeriod = lag * Double(Self.hop)
        // a flux frame ends at hop end; the hit started about where the frame's newest half begins
        let newAnchor = (Double(envCount - 1) - (Double(bp) + frac)) * Double(Self.hop) + Double(Self.N - Self.hop)
        let sameTempo = period > 0 && abs(newPeriod / period - 1) < 0.04
        period = sameTempo ? period * 0.6 + newPeriod * 0.4 : newPeriod
        if sameTempo {
            // nudge the grid toward the new estimate instead of jumping (unless it's far off)
            var d = (newAnchor - anchor).truncatingRemainder(dividingBy: period)
            if d > period / 2 { d -= period }
            if d < -period / 2 { d += period }
            anchor = abs(d) < period * 0.15 ? anchor + d * 0.5 : newAnchor
        } else {
            anchor = newAnchor
        }
    }

    /// The first beat at or after `sample`.
    func nextBeat(atOrAfter sample: Double) -> Double? {
        guard period > 0 else { return nil }
        let k = ((sample - anchor) / period).rounded(.up)
        return anchor + k * period
    }
}

// MARK: - Chops

/// Copies of the song a little behind the live one: cutting to a late copy repeats what just played,
/// cutting back catches up. Cuts land on the beat and fade over 6 ms so they never click.
final class Chopper {
    struct Cut: Equatable { var at: Double; var length: Double; var delay: Double }   // in samples
    struct Chop: Equatable {
        var move: ChopMove
        var start: Double
        var length: Double
        var cuts: [Cut]
    }

    let sampleRate: Double
    let tracker: BeatTracker
    private var rings: [[Float]] = []
    private let cap: Int
    private var written = 0                     // samples written per channel (absolute index)
    private var beatsSeen = 0
    private var lastBeatCounted: Double = -1
    private var cooldownUntil: Double = 0
    private(set) var holding = false
    private var queued: (ChopMove, Bool)?
    private var rng: UInt64
    private let fade: Int
    private(set) var active: Chop?
    private(set) var history: [Chop] = []        // for tests and the status line
    private(set) var count = 0

    init(sampleRate: Double, seed: UInt64 = UInt64(Date().timeIntervalSince1970 * 1000)) {
        self.sampleRate = sampleRate
        tracker = BeatTracker(sampleRate: sampleRate)
        cap = Int(sampleRate * 12)               // 12 s of memory: room to hold a loop for a few bars
        fade = max(64, Int(sampleRate * 0.006))
        rng = seed | 1
        history.reserveCapacity(65)
    }

    /// Sets up memory ahead of time (called before playback starts, not on the audio thread).
    func prepare(channels: Int) {
        if rings.count != channels { rings = Array(repeating: [Float](repeating: 0, count: cap), count: max(1, channels)) }
    }

    func reset() {
        tracker.reset()
        written = 0; beatsSeen = 0; lastBeatCounted = -1; cooldownUntil = 0; active = nil; holding = false; queued = nil; history.removeAll(keepingCapacity: true); count = 0
        for c in rings.indices { for i in rings[c].indices { rings[c][i] = 0 } }
    }

    var status: ScrewStatus { ScrewStatus(bpm: tracker.bpm, confidence: tracker.confidence, chops: count, last: history.last?.move) }

    private func random() -> Double {
        rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17
        return Double(rng >> 11) / Double(1 << 53)
    }

    /// Processes one block in place. `channels` are (pointer, stride) pairs.
    func process(_ channels: [(UnsafeMutablePointer<Float>, Int)], frames: Int, amount: ChopAmount) {
        guard frames > 0, let first = channels.first else { return }
        if rings.count != channels.count { rings = Array(repeating: [Float](repeating: 0, count: cap), count: channels.count) }
        let blockStart = written

        // remember the incoming audio (the "second record")
        for (c, (p, stride)) in channels.enumerated() {
            rings[c].withUnsafeMutableBufferPointer { ring in
                var w = blockStart % cap
                for i in 0..<frames {
                    ring[w] = p[i * stride]
                    w += 1; if w == cap { w = 0 }
                }
            }
        }
        tracker.feed(first.0, count: frames, stride: first.1)
        written += frames

        // keep counting beats (even during a chop) and plan the next chop on an upcoming beat
        if amount != .off { plan(from: Double(blockStart), to: Double(written), amount: amount) }

        guard var chop = active else { return }
        // holding the loop pad: add one more pass of the same beat just before the current one runs out
        if chop.move == .loop, holding, let last = chop.cuts.last {
            let p = chop.cuts[0].length          // the beat length it started with, so every pass is the same beat
            if chop.start + chop.length - Double(written) < Double(max(frames * 2, fade * 2)),
               last.delay + p < min(Double(cap - 8192), Double(written)) {
                chop.cuts.append(Cut(at: last.at + last.length, length: p, delay: last.delay + p))
                chop.length += p
                update(chop)
            } else if last.delay + p >= Double(cap - 8192) { holding = false }
        }
        let f = fade
        let end = chop.start + chop.length
        if Double(blockStart) >= end + Double(f) {
            active = nil; cooldownUntil = end + tracker.period
            if let q = queued { queued = nil; _ = trigger(q.0, hold: q.1) }
            return
        }
        let s0 = Int(chop.start.rounded()), e0 = Int(end.rounded())
        let cuts = chop.cuts
        let lastD = Int(cuts[cuts.count - 1].delay.rounded())
        for (c, (p, stride)) in channels.enumerated() {
            rings[c].withUnsafeBufferPointer { ring in
                @inline(__always) func read(_ n: Int, _ d: Int, _ live: Float) -> Float { d == 0 ? live : ring[((n - d) % cap + cap) % cap] }
                // cuts follow one after another, so walk through them with a cursor
                var j = 0
                var a = Int(cuts[0].at.rounded()), d = Int(cuts[0].delay.rounded()), prevD = 0
                for i in 0..<frames {
                    let n = blockStart + i
                    guard n >= s0, n < e0 + f else { continue }
                    let live = p[i * stride]
                    if n < e0 {
                        while j + 1 < cuts.count, n >= Int(cuts[j + 1].at.rounded()) {
                            j += 1; prevD = d
                            a = Int(cuts[j].at.rounded()); d = Int(cuts[j].delay.rounded())
                        }
                        var v = read(n, d, live)
                        if n < a + f {
                            // the cut before this sample: fade over 6 ms from what was playing to the new copy
                            let m = Float(n - a) / Float(f)
                            v = read(n, prevD, live) * (1 - m) + v * m
                        }
                        p[i * stride] = v
                    } else {
                        let m = Float(n - e0) / Float(f)                                  // fade back to live
                        p[i * stride] = read(n, lastD, live) * (1 - m) + live * m
                    }
                }
            }
        }
    }

    /// Live mode: play a move now (or on the beat if it's only a moment away). Every cut goes back whole or half
    /// beats, so it stays in time wherever you tap. Tapping during a chop lines the move up right after it.
    /// Returns false if the beat isn't found yet.
    @discardableResult
    func trigger(_ move: ChopMove, hold: Bool = false) -> Bool {
        let t = tracker, p = t.period
        guard p > 0, t.confidence > 0.15 else { return false }
        let limit = min(Double(cap - 8192), Double(written))
        func cuts(from start: Double) -> [Cut] {
            var at = start, out: [Cut] = []
            for (len, delay) in move.cuts { out.append(Cut(at: at, length: len * p, delay: delay * p)); at += len * p }
            return out
        }
        let now = Double(written)
        if var a = active {
            if now < a.start + a.length - Double(fade) {
                guard a.length <= 8 * p else { return false }          // don't stack up forever
                let more = cuts(from: a.start + a.length)
                guard (more.map(\.delay).max() ?? 0) < limit else { return false }
                a.cuts += more
                a.length = more[more.count - 1].at + more[more.count - 1].length - a.start
                if move == .loop { a.move = .loop }
                update(a)
                holding = hold
                return true
            }
            queued = (move, hold)                                      // last few ms of a chop fading out: go right after
            return true
        }
        var at = now
        if let b = t.nextBeat(atOrAfter: at), b - at < 0.12 * sampleRate { at = b }   // snap to a beat that's about to land
        let c = cuts(from: at)
        guard (c.map(\.delay).max() ?? 0) < limit else { return false }
        let chop = Chop(move: move, start: at, length: c[c.count - 1].at + c[c.count - 1].length - at, cuts: c)
        active = chop
        holding = hold
        history.append(chop)
        if history.count > 64 { history.removeFirst() }
        count += 1
        return true
    }

    /// Changes the chop that's playing (and its history entry, so tests and the status see the whole thing).
    private func update(_ c: Chop) {
        if let i = history.indices.last, let a = active, history[i].start == a.start { history[i] = c }
        active = c
    }

    func release() { holding = false; if queued != nil { queued?.1 = false } }

    private func plan(from: Double, to: Double, amount: ChopAmount) {
        guard !amount.picks.isEmpty else { return }
        let t = tracker
        guard t.confidence > 0.15, t.period > 0, t.samplesSeen > Int(sampleRate * 4) else { return }
        guard var beat = t.nextBeat(atOrAfter: max(from, lastBeatCounted + t.period * 0.5)) else { return }
        // plan just ahead (fresh beat estimates), but far enough to cover the next audio block
        let horizon = to + max(Double(fade * 2), min(t.period * 0.5, 8192))
        while beat < horizon {
            if beat > lastBeatCounted + t.period * 0.5 {
                lastBeatCounted = beat
                beatsSeen += 1
                if active == nil, beatsSeen % amount.every == 0, beat > to, beat >= cooldownUntil, random() < amount.chance {
                    let p = t.period
                    var roll = random()
                    var move = amount.picks[0].0
                    for (m, w) in amount.picks { if roll < w { move = m; break }; roll -= w }
                    var at = beat
                    var cuts: [Cut] = []
                    for (len, delay) in move.cuts { cuts.append(Cut(at: at, length: len * p, delay: delay * p)); at += len * p }
                    let maxDelay = cuts.map(\.delay).max() ?? 0
                    if maxDelay < Double(cap - 8192), maxDelay < Double(t.samplesSeen) {
                        let chop = Chop(move: move, start: beat, length: at - beat, cuts: cuts)
                        active = chop
                        history.append(chop)
                        if history.count > 64 { history.removeFirst() }
                        count += 1
                        return
                    }
                }
            }
            beat += t.period
        }
    }
}
