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
    /// Seconds (of the song) you're behind it because of chops; the player plays that much more before moving on.
    var lag: Double = 0
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
    private var _reset = false
    /// The player jumped (skip, seek, new queue): start the chops fresh instead of carrying on.
    func requestReset() { os_unfair_lock_lock(&lock); _reset = true; _pending = nil; os_unfair_lock_unlock(&lock) }
    func tap(_ move: ChopMove, hold: Bool = false) {
        os_unfair_lock_lock(&lock); _pending = move; _pendingHold = hold; _release = false; os_unfair_lock_unlock(&lock)
    }
    func release() { os_unfair_lock_lock(&lock); _release = true; os_unfair_lock_unlock(&lock) }
    /// Audio thread: what was tapped since last time.
    func takeTaps() -> (move: ChopMove?, hold: Bool, release: Bool, reset: Bool) {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        let r = (_pending, _pendingHold, _release, _reset)
        _pending = nil; _release = false; _reset = false
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
    private var log = [Double](repeating: 0, count: 512)   // beats already found, in song samples (chops play the past)
    private var logCount = 0
    private var logEnd = 0.0

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
        estimates = 0; histSum = 0; logCount = 0; logEnd = 0
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
        // write down the beats that are settled now (a little behind the newest audio)
        if confidence > 0.15 {
            let until = Double(samplesSeen) - 0.3 * sampleRate
            var b = grid(max(logEnd, until - 4 * sampleRate))
            while b < until {
                let last = logCount > 0 ? log[(logCount - 1) % 512] : -Double.infinity
                if b - last > period * 0.5 { log[logCount % 512] = b; logCount += 1 }
                b += period
            }
            logEnd = until
        }
    }

    private func grid(_ sample: Double) -> Double { anchor + ((sample - anchor) / period).rounded(.up) * period }

    /// The first beat at or after `sample`: from the beats already found if it's in the past, else from the grid.
    func nextBeat(atOrAfter sample: Double) -> Double? {
        guard period > 0 else { return nil }
        let n = min(logCount, 512)
        if n > 0, sample <= log[(logCount - 1) % 512], sample >= log[(logCount - n) % 512] {
            var k = logCount - 1
            while k > logCount - n, log[(k - 1) % 512] >= sample { k -= 1 }
            return log[k % 512]
        }
        return grid(sample)
    }
}

// MARK: - Chops

/// A playhead over a memory of the song. A chop jumps the playhead back a beat or two (with a 6 ms crossfade into the
/// jump, landing right on the beat), and the song then carries on from where the chop ends: every chop adds its length
/// to the song, like pausing the record and running it back. `lag` is how far behind the incoming audio you are.
/// Same as the web player's chop-worklet.js.
final class Chopper {
    struct Jump: Equatable { var oc: Int; var J: Double }                     // when (samples played) and how far back
    struct Played: Equatable { var oc: Int; var at: Int; var from: Int; var len: Int }   // for tests and the status line
    struct Chop: Equatable {
        var move: ChopMove
        var start: Int
        var jumps: [Jump]
        var end: Int
        var next = 0
        var played: [Played] = []
    }

    let sampleRate: Double
    let tracker: BeatTracker
    private var rings: [[Float]] = []
    private let cap: Int
    private(set) var wp = 0          // write position (song samples)
    private(set) var rp = 0          // play position (song samples)
    private(set) var oc = 0          // samples played
    private var beatsSeen = 0
    private var lastBeat: Double = -1
    private var cooldownUntil = 0
    private var rng: UInt64
    private let fade: Int
    private(set) var holding = false
    private(set) var active: Chop?
    private(set) var history: [Chop] = []
    private(set) var count = 0

    var lag: Int { wp - rp }

    init(sampleRate: Double, seed: UInt64 = UInt64(Date().timeIntervalSince1970 * 1000), seconds: Double = 90) {
        self.sampleRate = sampleRate
        tracker = BeatTracker(sampleRate: sampleRate)
        cap = Int(sampleRate * seconds)            // memory: chops can push the song back up to about a minute
        fade = max(64, Int(sampleRate * 0.006))
        rng = seed | 1
        history.reserveCapacity(65)
    }

    /// Sets up memory ahead of time (not on the audio thread).
    func prepare(channels: Int) {
        if rings.count != channels { rings = Array(repeating: [Float](repeating: 0, count: cap), count: max(1, channels)) }
    }
    var channelCount: Int { rings.count }

    func reset() {
        tracker.reset()
        wp = 0; rp = 0; oc = 0; beatsSeen = 0; lastBeat = -1; cooldownUntil = 0; active = nil; holding = false
        history.removeAll(keepingCapacity: true); count = 0
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
        // 1. remember what came in (the record)
        for (c, (p, stride)) in channels.enumerated() {
            rings[c].withUnsafeMutableBufferPointer { ring in
                var w = wp % cap
                for i in 0..<frames { ring[w] = p[i * stride]; w += 1; if w == cap { w = 0 } }
            }
        }
        tracker.feed(first.0, count: frames, stride: first.1)
        wp += frames
        // 2. plan the next chop on an upcoming beat
        if active == nil, !amount.picks.isEmpty { plan(frames: frames, amount: amount) }
        // holding the loop pad: one more pass of the same beat just before the current one runs out
        if var a = active, a.move == .loop, holding, a.next >= a.jumps.count, a.end - oc < max(frames * 2, fade * 2) {
            let p0 = a.jumps[0].J
            if Double(lag) + p0 < Double(cap - 8192 - frames) {
                a.jumps.append(Jump(oc: a.end, J: p0)); a.end += Int(p0.rounded()); update(a)
            } else { holding = false }
        }
        // 3. play from the playhead (every channel walks the same jumps)
        let f = fade
        let jl = active?.jumps ?? [], aEnd = active?.end ?? 0, next0 = active?.next ?? 0
        var played: [Played] = []
        var rpEnd = rp, ocEnd = oc, nextEnd = next0
        for (c, (p, stride)) in channels.enumerated() {
            var rpc = rp, occ = oc, next = next0
            rings[c].withUnsafeBufferPointer { ring in
                for i in 0..<frames {
                    var J = 0, m: Float = 0
                    if next < jl.count {
                        let j = jl[next]
                        if occ >= j.oc {                                   // the jump: land on the beat
                            let jr = Int(j.J.rounded())
                            if c == 0 {
                                let len = (next + 1 < jl.count ? jl[next + 1].oc : aEnd) - occ
                                played.append(Played(oc: occ, at: rpc, from: rpc - jr, len: len))
                            }
                            rpc -= jr
                            next += 1
                        } else if occ >= j.oc - f {                        // fading into it
                            J = Int(j.J.rounded()); m = Float(occ - (j.oc - f)) / Float(f)
                        }
                    }
                    let r0 = rpc % cap
                    if J != 0 {
                        let r1 = ((rpc - J) % cap + cap) % cap
                        p[i * stride] = ring[r0] * (1 - m) + ring[r1] * m
                    } else {
                        p[i * stride] = ring[r0]
                    }
                    rpc += 1; occ += 1
                }
            }
            rpEnd = rpc; ocEnd = occ; nextEnd = next
        }
        rp = rpEnd; oc = ocEnd
        if active != nil { active!.next = nextEnd; if !played.isEmpty { active!.played += played } }
        if let a = active, a.next >= a.jumps.count, oc >= a.end, !(a.move == .loop && holding) {
            if let i = history.indices.last, history[i].start == a.start { history[i] = a }
            active = nil
            cooldownUntil = oc + Int(tracker.period)
        }
    }

    private func update(_ c: Chop) {
        if let i = history.indices.last, let a = active, history[i].start == a.start { history[i] = c }
        active = c
    }

    /// A move as jumps for the playhead, starting at `at` (samples played).
    private func jumps(_ move: ChopMove, at start: Int, period p: Double) -> (jumps: [Jump], end: Int) {
        var prev = 0.0, at = Double(start), out: [Jump] = []
        for (len, delay) in move.cuts { out.append(Jump(oc: Int(at.rounded()), J: (delay - prev) * p)); prev = delay; at += len * p }
        return (out, Int(at.rounded()))
    }
    private func fits(_ extra: Double) -> Bool { Double(lag) + extra < Double(cap - 8192 - 4096) && extra <= Double(rp) }

    /// Live mode: play a move now (or on the beat if it's only a moment away). Tapping during a chop lines the move
    /// up right after it. Returns false if the beat isn't found yet.
    @discardableResult
    func trigger(_ move: ChopMove, hold: Bool = false) -> Bool {
        let t = tracker, p = t.period
        guard p > 0, t.confidence > 0.15 else { return false }
        let f = fade
        if var a = active {
            guard a.jumps.count <= 24 else { return false }            // don't stack up forever
            let start = max(a.end, oc + f)
            let (more, end) = jumps(move, at: start, period: p)
            guard fits(more.reduce(0) { $0 + $1.J } + Double(a.end - oc)) else { return false }
            a.jumps += more; a.end = end
            if move == .loop { a.move = .loop }
            holding = hold
            update(a)
            return true
        }
        // land on a beat that's about to come (in the song as you hear it), else right away
        var start = oc + f
        let pos = Double(rp + f)
        if let nb = t.nextBeat(atOrAfter: pos), nb - pos < 0.12 * sampleRate { start = oc + Int((nb - Double(rp)).rounded()) }
        let (j, end) = jumps(move, at: start, period: p)
        guard fits(j.reduce(0) { $0 + $1.J }) else { return false }
        let chop = Chop(move: move, start: start, jumps: j, end: end)
        active = chop
        holding = hold
        history.append(chop)
        if history.count > 64 { history.removeFirst() }
        count += 1
        return true
    }

    func release() { holding = false }

    private func plan(frames: Int, amount: ChopAmount) {
        let t = tracker
        guard t.confidence > 0.15, t.period > 0, t.samplesSeen > Int(sampleRate * 4) else { return }
        // beats in the song as you hear it (the playhead), counted as they go by
        let horizon = Double(rp + frames) + max(Double(fade * 2), min(t.period * 0.5, 8192))
        guard var beat = t.nextBeat(atOrAfter: max(Double(rp), lastBeat + t.period * 0.5)) else { return }
        while beat < horizon {
            if beat > lastBeat + t.period * 0.5 {
                lastBeat = beat
                beatsSeen += 1
                let start = oc + Int((beat - Double(rp)).rounded())
                if beatsSeen % amount.every == 0, beat - Double(rp) > Double(fade), start >= cooldownUntil, random() < amount.chance {
                    var roll = random()
                    var move = amount.picks[0].0
                    for (m, w) in amount.picks { if roll < w { move = m; break }; roll -= w }
                    let (j, end) = jumps(move, at: start, period: t.period)
                    if fits(j.reduce(0) { $0 + $1.J }) {
                        let chop = Chop(move: move, start: start, jumps: j, end: end)
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
