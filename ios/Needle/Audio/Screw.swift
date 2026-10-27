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
    case off, light, heavy
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    /// How many beats between chances to chop, and how likely a chop is at each chance.
    var every: Int { self == .heavy ? 8 : 16 }
    var chance: Double { self == .heavy ? 0.85 : 0.6 }
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
}

// MARK: - Beat tracking

/// Finds the tempo and where the beats fall, from the audio as it plays.
/// Onsets (sudden rises in low-end and overall energy) are collected every 512 samples;
/// the tempo is the spacing at which that pattern best repeats, and the beat position is the
/// offset that best lines up with the strongest hits.
final class BeatTracker {
    let sampleRate: Double
    static let hop = 512
    private let maxHops: Int
    private var env: [Float]
    private var envLow: [Float]              // low-end (kick) onsets, used to place the beats
    private var envCount = 0               // total hops seen
    private var level: Float = 0           // slow running loudness
    private var prevLowForPhase: Float = 0
    private var acc = 0, accLow: Float = 0, accAll: Float = 0
    private var lp: Float = 0
    private var prevLow: Float = 0, prevAll: Float = 0
    private var sinceEstimate = 0

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
        maxHops = Int(6.0 * sampleRate / Double(Self.hop))
        env = [Float](repeating: 0, count: maxHops)
        envLow = [Float](repeating: 0, count: maxHops)
    }

    func reset() {
        envCount = 0; acc = 0; accLow = 0; accAll = 0; lp = 0; prevLow = 0; prevAll = 0
        period = 0; anchor = 0; confidence = 0; samplesSeen = 0; sinceEstimate = 0; level = 0; prevLowForPhase = 0
        for i in env.indices { env[i] = 0; envLow[i] = 0 }
    }

    func feed(_ x: UnsafePointer<Float>, count: Int, stride: Int = 1) {
        let a = Float(1 - exp(-2 * Double.pi * 180 / sampleRate))     // ~180 Hz low-pass for the kick
        for i in 0..<count {
            let s = x[i * stride]
            lp += a * (s - lp)
            accLow += lp * lp
            accAll += s * s
            level = level * 0.99998 + s * s * 0.00002
            acc += 1
            if acc == Self.hop { pushHop() }
        }
        samplesSeen += count
    }

    private func pushHop() {
        let low = log1p(accLow * 40), all = log1p(accAll * 10)
        let onset = max(0, low - prevLow) + 0.5 * max(0, all - prevAll)
        prevLow = low; prevAll = all
        accLow = 0; accAll = 0; acc = 0
        env[envCount % maxHops] = onset
        envLow[envCount % maxHops] = max(0, low - prevLowForPhase)
        prevLowForPhase = low
        envCount += 1
        sinceEstimate += 1
        if sinceEstimate >= Int(0.5 * sampleRate / Double(Self.hop)), envCount >= Int(3 * sampleRate / Double(Self.hop)) {
            sinceEstimate = 0
            estimate()
        }
    }

    private func e(_ hopIndex: Int) -> Float {     // onset at an absolute hop index (0 if forgotten)
        guard hopIndex >= 0, hopIndex < envCount, envCount - hopIndex <= maxHops else { return 0 }
        return env[hopIndex % maxHops]
    }
    private func eLow(_ hopIndex: Int) -> Float {
        guard hopIndex >= 0, hopIndex < envCount, envCount - hopIndex <= maxHops else { return 0 }
        return envLow[hopIndex % maxHops]
    }

    private func estimate() {
        let n = min(envCount, maxHops)
        let hopsPerSec = sampleRate / Double(Self.hop)
        let minLag = Int(hopsPerSec * 60 / 180), maxLag = Int(hopsPerSec * 60 / 55) + 1
        let start = envCount - n
        var mean: Float = 0
        for i in start..<envCount { mean += e(i) }
        mean /= Float(n)
        var var0: Float = 0
        for i in start..<envCount { var0 += (e(i) - mean) * (e(i) - mean) }
        var0 /= Float(n)
        var best = 0.0, bestLag = 0, total = 0.0
        var scores = [Double](repeating: 0, count: maxLag + 2)
        for lag in minLag...maxLag {
            var s: Float = 0
            for i in (start + lag)..<envCount { s += (e(i) - mean) * (e(i - lag) - mean) }
            var v = Double(s) / Double(n - lag)
            // prefer tempos between ~70 and ~140 BPM (most rap, R&B and rock), gently
            let bpm = 60 * hopsPerSec / Double(lag)
            let octaves = log2(bpm / 100)
            v *= exp(-0.5 * (octaves * octaves) / (0.6 * 0.6))
            scores[lag] = v
            if v > 0 { total += v }
            if v > best { best = v; bestLag = lag }
        }
        guard bestLag > 0, best > 0 else { confidence = 0; return }
        // sub-hop accuracy from the neighbors
        var lag = Double(bestLag)
        let l = scores[max(minLag, bestLag - 1)], r = scores[min(maxLag, bestLag + 1)]
        let denom = l - 2 * best + r
        if denom < 0 { lag += 0.5 * (l - r) / denom }
        let newPeriod = lag * Double(Self.hop)
        // how clearly it repeats compared with the overall wobble (hiss or silence score low), and only for actual music
        let pOct = log2(60 * hopsPerSec / Double(bestLag) / 100)
        let prior = exp(-0.5 * (pOct * pOct) / (0.6 * 0.6))
        let strength = var0 > 1e-9 ? best / prior / Double(var0) : 0
        var recent: Float = 0
        for i in (envCount - Int(2 * hopsPerSec))..<envCount { recent += e(i) }
        let loudEnough = level > 0.0003            // about -35 dB
        confidence = recent < 0.5 || !loudEnough ? 0 : max(0, min(1, (strength - 0.12) / 0.3))
        _ = total

        // where the beats are: the offset whose evenly spaced hits are strongest over the last 8 beats
        let lagI = lag
        let steps = max(1, Int(lagI))
        var phase = [Float](repeating: 0, count: steps)
        var bestPhase = 0, bestScore: Float = -1
        for o in 0..<steps {
            var sc: Float = 0
            for k in 0..<8 {
                let idx = envCount - 1 - o - Int((Double(k) * lagI).rounded())
                sc += eLow(idx) + 0.5 * (eLow(idx - 1) + eLow(idx + 1)) + 0.3 * e(idx)
            }
            phase[o] = sc
            if sc > bestScore { bestScore = sc; bestPhase = o }
        }
        // sub-step accuracy from the neighbors
        let pl = phase[(bestPhase - 1 + steps) % steps], pr = phase[(bestPhase + 1) % steps]
        let pd = pl - 2 * bestScore + pr
        let frac = pd < 0 ? max(-0.5, min(0.5, Double(0.5 * (pl - pr) / pd))) : 0
        let beatHop = Double(envCount - 1) - (Double(bestPhase) + frac)
        // an onset is measured at the end of its hop; the hit itself started about half a hop earlier
        let newAnchor = (beatHop + 0.5) * Double(Self.hop)
        if period > 0, abs(newPeriod - period) / period < 0.04 {
            period = period * 0.7 + newPeriod * 0.3         // steady: smooth small wobbles
        } else {
            period = newPeriod
        }
        anchor = newAnchor
    }

    /// The first beat at or after `sample`.
    func nextBeat(atOrAfter sample: Double) -> Double? {
        guard period > 0 else { return nil }
        let k = ((sample - anchor) / period).rounded(.up)
        return anchor + k * period
    }
}

// MARK: - Chops

/// Two copies of the song, one a little behind: cutting to the late copy repeats what just played,
/// cutting back catches up. Cuts land on the beat and fade over 6 ms so they never click.
final class Chopper {
    struct Chop: Equatable { var start: Double; var length: Double; var delay: Double }

    let sampleRate: Double
    let tracker: BeatTracker
    private var rings: [[Float]] = []
    private let cap: Int
    private var written = 0                     // samples written per channel (absolute index)
    private var nextChance: Double = 0
    private var beatsSeen = 0
    private var lastBeatCounted: Double = -1
    private var rng: UInt64
    private let fade: Int
    private(set) var active: Chop?
    private(set) var history: [Chop] = []        // for tests and debugging

    init(sampleRate: Double, seed: UInt64 = UInt64(Date().timeIntervalSince1970 * 1000)) {
        self.sampleRate = sampleRate
        tracker = BeatTracker(sampleRate: sampleRate)
        cap = Int(sampleRate * 5)
        fade = max(64, Int(sampleRate * 0.006))
        rng = seed | 1
    }

    /// Sets up memory ahead of time (called before playback starts, not on the audio thread).
    func prepare(channels: Int) {
        if rings.count != channels { rings = Array(repeating: [Float](repeating: 0, count: cap), count: max(1, channels)) }
    }

    func reset() {
        tracker.reset()
        written = 0; nextChance = 0; beatsSeen = 0; lastBeatCounted = -1; active = nil
        for c in rings.indices { for i in rings[c].indices { rings[c][i] = 0 } }
    }

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

        // plan a chop on an upcoming beat
        if active == nil, amount != .off { planChop(from: Double(blockStart), to: Double(written), amount: amount) }

        // play the late copy while a chop is on, with short fades at both cuts
        guard let chop = active else { return }
        let d = Int(chop.delay.rounded())
        let s0 = Int(chop.start.rounded()), s1 = Int((chop.start + chop.length).rounded())
        if Double(blockStart) >= chop.start + chop.length + Double(fade) { active = nil; return }
        for (c, (p, stride)) in channels.enumerated() {
            rings[c].withUnsafeBufferPointer { ring in
                for i in 0..<frames {
                    let n = blockStart + i
                    guard n >= s0 - fade, n < s1 + fade else { continue }
                    // mix: 0 = live, 1 = the copy one chop-delay behind
                    let m: Float
                    if n < s0 { m = Float(n - (s0 - fade)) / Float(fade) }          // fade into the late copy
                    else if n < s1 { m = 1 }
                    else { m = 1 - Float(n - s1) / Float(fade) }                     // fade back to live
                    let late = ring[((n - d) % cap + cap) % cap]
                    p[i * stride] = p[i * stride] * (1 - m) + late * m
                }
            }
        }
    }

    private func planChop(from: Double, to: Double, amount: ChopAmount) {
        let t = tracker
        guard t.confidence > 0.25, t.period > 0, t.samplesSeen > Int(sampleRate * 4) else { return }
        // count beats as they go by
        var beat = t.nextBeat(atOrAfter: max(from, lastBeatCounted + t.period * 0.5)) ?? to
        // plan just ahead (fresh beat estimates), but far enough to cover the next audio block
        let horizon = to + max(Double(fade * 2), min(t.period * 0.5, 8192))
        while beat < horizon {
            if beat > lastBeatCounted + t.period * 0.5 {
                lastBeatCounted = beat
                beatsSeen += 1
                // chances fall on bar lines; the cut has to start a little ahead so the fade-in lands on the beat
                if beatsSeen % amount.every == 0, beat - Double(fade) > to, random() < amount.chance {
                    let p = t.period
                    let roll = random()
                    let chop: Chop
                    if amount == .heavy && roll < 0.3 {
                        chop = Chop(start: beat, length: p, delay: p / 2)          // stutter: half a beat, twice
                    } else if roll < 0.75 {
                        chop = Chop(start: beat, length: p, delay: p)              // repeat the last beat
                    } else {
                        chop = Chop(start: beat, length: 2 * p, delay: 2 * p)      // run back the last two beats (a line)
                    }
                    if chop.delay < Double(cap - 4096) {
                        active = chop
                        history.append(chop)
                        if history.count > 64 { history.removeFirst() }
                        return
                    }
                }
            }
            beat += t.period
        }
    }
}
