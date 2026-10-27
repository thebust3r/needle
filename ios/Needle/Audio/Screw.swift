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
    var every: Int { 4 }
    var chance: Double { self == .heavy ? 1 : 0.45 }
    /// Which moves, and how often: heavy picks the wilder ones more.
    var picks: [(ChopMove, Double)] {
        switch self {
        case .off: return []
        case .light: return [(.runBack, 0.45), (.repeatBeat, 0.3), (.stutter, 0.15), (.doubleUp, 0.1)]
        case .heavy: return [(.stutter, 0.3), (.runBack, 0.25), (.doubleUp, 0.2), (.repeatBeat, 0.1), (.backItUp, 0.15)]
        }
    }
}

/// The moves, as cuts between the live record and copies that are behind. Each cut is (length, delay) in beats;
/// the song keeps running underneath, like the second deck.
enum ChopMove: Int, CaseIterable {
    case repeatBeat, runBack, stutter, doubleUp, backItUp
    var cuts: [(Double, Double)] {
        switch self {
        case .repeatBeat: return [(1, 1)]                          // hear the last beat again
        case .runBack: return [(2, 2)]                             // run back the last two beats (about a line)
        case .stutter: return [(0.5, 0.5), (0.5, 1), (0.5, 1.5)]   // "ch-ch-ch": the same half beat three times
        case .doubleUp: return [(1, 1), (1, 2)]                    // the last beat twice
        case .backItUp: return [(4, 4)]                            // back up a whole bar
        }
    }
    var label: String {
        switch self {
        case .repeatBeat: return "Repeat"
        case .runBack: return "Run it back"
        case .stutter: return "Stutter"
        case .doubleUp: return "Double up"
        case .backItUp: return "Back it up"
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

    private var _status = ScrewStatus()
    /// Written by the audio thread about once a second, read by the UI.
    var status: ScrewStatus {
        get { os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }; return _status }
        set { os_unfair_lock_lock(&lock); _status = newValue; os_unfair_lock_unlock(&lock) }
    }
}

// MARK: - Beat tracking

/// Finds the tempo and where the beats fall, from the audio as it plays (same as the web player's chop-worklet.js).
/// Onsets (sudden rises in low end, overall level and hi-hats/snares) are collected every 512 samples;
/// the tempo is the spacing at which that pattern best repeats, and the beat position is the
/// offset that best lines up with the strongest kicks.
final class BeatTracker {
    let sampleRate: Double
    static let hop = 512
    private let maxHops: Int
    private var env: [Float]
    private var envLow: [Float]              // low-end (kick) onsets, used to place the beats
    private var raw: [Double]                // scratch for the tempo search (allocated once, not on the audio thread)
    private var scores: [Double]
    private var phase: [Float]
    private var envCount = 0                 // total hops seen
    private(set) var level: Float = 0        // slow running loudness
    private var prevLowForPhase: Float = 0
    private var acc = 0, accLow: Float = 0, accAll: Float = 0, accHigh: Float = 0
    private var lp: Float = 0, lp2: Float = 0
    private var prevLow: Float = 0, prevAll: Float = 0, prevHigh: Float = 0
    private var lowHist: (Float, Float, Float) = (0, 0, 0)
    private var sinceEstimate = 0
    private let minLag: Int, maxLag: Int

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
        let hps = sampleRate / Double(Self.hop)
        minLag = Int(hps * 60 / 180)
        maxLag = Int(hps * 60 / 55) + 1
        env = [Float](repeating: 0, count: maxHops)
        envLow = [Float](repeating: 0, count: maxHops)
        raw = [Double](repeating: 0, count: 2 * maxLag + 2)
        scores = [Double](repeating: 0, count: maxLag + 2)
        phase = [Float](repeating: 0, count: maxLag + 2)
    }

    func reset() {
        envCount = 0; acc = 0; accLow = 0; accAll = 0; accHigh = 0; lp = 0; lp2 = 0
        prevLow = 0; prevAll = 0; prevHigh = 0; lowHist = (0, 0, 0)
        period = 0; anchor = 0; confidence = 0; samplesSeen = 0; sinceEstimate = 0; level = 0; prevLowForPhase = 0
        for i in env.indices { env[i] = 0; envLow[i] = 0 }
    }

    func feed(_ x: UnsafePointer<Float>, count: Int, stride: Int = 1) {
        let a = Float(1 - exp(-2 * Double.pi * 180 / sampleRate))      // ~180 Hz low-pass for the kick
        let a2 = Float(1 - exp(-2 * Double.pi * 2500 / sampleRate))    // above ~2.5 kHz: hats and snares
        for i in 0..<count {
            let s = x[i * stride]
            lp += a * (s - lp)
            lp2 += a2 * (s - lp2)
            let h = s - lp2
            accHigh += h * h
            accLow += lp * lp
            accAll += s * s
            level = level * 0.99998 + s * s * 0.00002
            acc += 1
            if acc == Self.hop { pushHop() }
        }
        samplesSeen += count
    }

    private func pushHop() {
        // The low band is averaged over ~35 ms for the tempo, so long sliding 808s (whose energy ripples hop to hop)
        // don't drown the pattern. Hats and snares count too, for songs where the bass never really "hits".
        lowHist = (lowHist.1, lowHist.2, accLow)
        let lowRaw = log1p(accLow * 40), low = log1p((lowHist.0 + lowHist.1 + lowHist.2) / 3 * 40)
        let all = log1p(accAll * 10), high = log1p(accHigh * 200)
        let onset = max(0, low - prevLow) + 0.5 * max(0, all - prevAll) + 0.7 * max(0, high - prevHigh)
        prevLow = low; prevAll = all; prevHigh = high
        accLow = 0; accAll = 0; accHigh = 0; acc = 0
        env[envCount % maxHops] = onset
        envLow[envCount % maxHops] = max(0, lowRaw - prevLowForPhase)
        prevLowForPhase = lowRaw
        envCount += 1
        sinceEstimate += 1
        if sinceEstimate >= Int(0.25 * sampleRate / Double(Self.hop)), envCount >= Int(3 * sampleRate / Double(Self.hop)) {
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
        let start = envCount - n
        var mean: Float = 0
        for i in start..<envCount { mean += e(i) }
        mean /= Float(n)
        var var0: Float = 0
        for i in start..<envCount { var0 += (e(i) - mean) * (e(i) - mean) }
        var0 /= Float(n)
        // Autocorrelation, plus a half-weight vote from twice the lag: a beat that also lines up two beats later (where
        // kicks and 808s usually repeat) wins over an in-between lag that only the steady hi-hats agree with.
        for lag in minLag...(2 * maxLag + 1) {
            guard lag < n else { raw[lag] = 0; continue }
            var s: Float = 0
            for i in (start + lag)..<envCount { s += (e(i) - mean) * (e(i - lag) - mean) }
            raw[lag] = Double(s) / Double(n - lag)
        }
        var best = 0.0, bestLag = 0
        for lag in minLag...maxLag {
            var v = (raw[lag] + 0.5 * max(0, raw[2 * lag])) / 1.5
            // prefer tempos between ~70 and ~140 BPM (most rap, R&B and rock), gently
            let octaves = log2(60 * hopsPerSec / Double(lag) / 100)
            v *= exp(-0.5 * (octaves * octaves) / 0.36)
            scores[lag] = v
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
        let prior = exp(-0.5 * (pOct * pOct) / 0.36)
        let strength = var0 > 1e-9 ? best / prior / Double(var0) : 0
        var recent: Float = 0
        for i in (envCount - Int(2 * hopsPerSec))..<envCount { recent += e(i) }
        let loudEnough = level > 0.0001            // about -40 dB: actual music, not hiss
        confidence = recent < 0.5 || !loudEnough ? 0 : max(0, min(1, (strength - 0.12) / 0.3))

        // where the beats are: the offset whose evenly spaced hits are strongest over the last 8 beats
        let steps = max(1, min(Int(lag), phase.count))
        var bestPhase = 0, bestScore: Float = -1
        for o in 0..<steps {
            var sc: Float = 0
            for k in 0..<8 {
                let idx = envCount - 1 - o - Int((Double(k) * lag).rounded())
                sc += eLow(idx) + 0.5 * (eLow(idx - 1) + eLow(idx + 1)) + 0.3 * e(idx)
            }
            phase[o] = sc
            if sc > bestScore { bestScore = sc; bestPhase = o }
        }
        let pl = phase[(bestPhase - 1 + steps) % steps], pr = phase[(bestPhase + 1) % steps]
        let pd = pl - 2 * bestScore + pr
        let frac = pd < 0 ? max(-0.5, min(0.5, Double(0.5 * (pl - pr) / pd))) : 0
        let beatHop = Double(envCount - 1) - (Double(bestPhase) + frac)
        // an onset is measured at the end of its hop; the hit itself started about half a hop earlier
        let newAnchor = (beatHop + 0.5) * Double(Self.hop)
        if period > 0, abs(newPeriod - period) / period < 0.04 {
            period = period * 0.5 + newPeriod * 0.5         // steady: smooth small wobbles, still follow drift
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
    private var rng: UInt64
    private let fade: Int
    private(set) var active: Chop?
    private(set) var history: [Chop] = []        // for tests and the status line
    private(set) var count = 0

    init(sampleRate: Double, seed: UInt64 = UInt64(Date().timeIntervalSince1970 * 1000)) {
        self.sampleRate = sampleRate
        tracker = BeatTracker(sampleRate: sampleRate)
        cap = Int(sampleRate * 5)
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
        written = 0; beatsSeen = 0; lastBeatCounted = -1; cooldownUntil = 0; active = nil; history.removeAll(keepingCapacity: true); count = 0
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

        guard let chop = active else { return }
        let f = fade
        let end = chop.start + chop.length
        if Double(blockStart) >= end + Double(f) { active = nil; cooldownUntil = end + tracker.period; return }
        let s0 = Int(chop.start.rounded()), e0 = Int(end.rounded())
        let cuts = chop.cuts
        for (c, (p, stride)) in channels.enumerated() {
            rings[c].withUnsafeBufferPointer { ring in
                func read(_ n: Int, _ d: Int, _ live: Float) -> Float { d == 0 ? live : ring[((n - d) % cap + cap) % cap] }
                for i in 0..<frames {
                    let n = blockStart + i
                    guard n >= s0, n < e0 + f else { continue }
                    let live = p[i * stride]
                    var d = 0, k = -1
                    for (j, g) in cuts.enumerated() {
                        let a = Int(g.at.rounded())
                        if n >= a && n < Int((g.at + g.length).rounded()) { d = Int(g.delay.rounded()) }
                        if n >= a && n < a + f { k = j }
                    }
                    var v = read(n, d, live)
                    if k >= 0 {
                        // the cut before this sample: fade over 6 ms from what was playing to the new copy
                        let prevD = k == 0 ? 0 : Int(cuts[k - 1].delay.rounded())
                        let m = Float(n - Int(cuts[k].at.rounded())) / Float(f)
                        v = read(n, prevD, live) * (1 - m) + v * m
                    } else if n >= e0 {
                        let m = Float(n - e0) / Float(f)                                  // fade back to live
                        v = read(n, Int(cuts[cuts.count - 1].delay.rounded()), live) * (1 - m) + live * m
                    }
                    p[i * stride] = v
                }
            }
        }
    }

    private func plan(from: Double, to: Double, amount: ChopAmount) {
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
