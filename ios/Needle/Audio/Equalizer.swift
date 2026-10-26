import Accelerate
import Foundation
import Observation
import os

// MARK: - The settings you see and change

struct EQPreset: Codable, Identifiable, Hashable {
    var id: String { name }
    var name: String
    var gains: [Float]
    var builtIn = false
}

@Observable
final class Equalizer {
    static let frequencies: [Float] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    static let labels = ["32", "64", "125", "250", "500", "1K", "2K", "4K", "8K", "16K"]
    static let range: ClosedRange<Float> = -12...12

    static let builtInPresets: [EQPreset] = [
        .init(name: "Flat", gains: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0], builtIn: true),
        .init(name: "Bass Boost", gains: [6, 5.5, 4.5, 2.5, 0.5, 0, 0, 0, 0, 0], builtIn: true),
        .init(name: "Deep Bass", gains: [8, 7, 5, 2, 0, -1, -1, 0, 0, 0], builtIn: true),
        .init(name: "Treble Boost", gains: [0, 0, 0, 0, 0, 1, 2.5, 4, 5, 6], builtIn: true),
        .init(name: "Vocal", gains: [-2, -2, -1, 1, 3, 4, 3.5, 1.5, 0, -1], builtIn: true),
        .init(name: "Hip-Hop", gains: [6, 5, 2, 3, -1, -1, 1, 0, 2, 3], builtIn: true),
        .init(name: "Rock", gains: [5, 4, 2, -1, -2, -1, 2, 3, 4, 4], builtIn: true),
        .init(name: "Pop", gains: [-1, 1, 3, 4, 3, 0, -1, -1, 0, 1], builtIn: true),
        .init(name: "Electronic", gains: [5, 4, 1, 0, -2, 2, 1, 2, 4, 5], builtIn: true),
        .init(name: "Acoustic", gains: [3, 3, 2, 1, 1, 1, 2, 2.5, 2, 1], builtIn: true),
        .init(name: "Loudness", gains: [5, 3.5, 0, 0, -1, 0, -1, 0, 3.5, 5], builtIn: true),
        .init(name: "Late Night", gains: [3, 2.5, 1, 0, -1, -1.5, 0, 1, 1, 0.5], builtIn: true),
        .init(name: "Small Speakers", gains: [-4, -2, 3, 4, 3, 1, 1, 2, 2, 1], builtIn: true),
    ]

    var gains: [Float] { didSet { push(); persist() } }
    var preamp: Float { didSet { push(); persist() } }
    var enabled: Bool { didSet { push(); persist() } }
    var clipGuard: Bool { didSet { push(); persist() } }
    var presetName: String { didSet { persist() } }
    var customPresets: [EQPreset] { didSet { persist() } }

    var allPresets: [EQPreset] { Self.builtInPresets + customPresets }

    init() {
        let d = UserDefaults.standard
        gains = (d.array(forKey: "eq.gains") as? [Float]).flatMap { $0.count == 10 ? $0 : nil } ?? Array(repeating: 0, count: 10)
        preamp = d.object(forKey: "eq.preamp") as? Float ?? 0
        enabled = d.object(forKey: "eq.enabled") as? Bool ?? true
        clipGuard = d.object(forKey: "eq.clipGuard") as? Bool ?? true
        presetName = d.string(forKey: "eq.preset") ?? "Flat"
        if let data = d.data(forKey: "eq.custom"), let list = try? JSONDecoder().decode([EQPreset].self, from: data) {
            customPresets = list
        } else {
            customPresets = []
        }
        push()
    }

    func apply(_ preset: EQPreset) {
        gains = preset.gains
        presetName = preset.name
    }

    func setGain(_ value: Float, band: Int) {
        guard gains.indices.contains(band) else { return }
        gains[band] = min(max(value, Self.range.lowerBound), Self.range.upperBound)
        presetName = allPresets.first(where: { $0.gains == gains })?.name ?? "Custom"
    }

    func saveCurrent(as name: String) {
        let clean = name.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty, !Self.builtInPresets.contains(where: { $0.name == clean }) else { return }
        customPresets.removeAll { $0.name == clean }
        customPresets.append(EQPreset(name: clean, gains: gains))
        presetName = clean
    }

    func delete(_ preset: EQPreset) {
        customPresets.removeAll { $0.name == preset.name }
    }

    private func push() {
        EQProcessor.shared.update(gains: enabled ? gains : Array(repeating: 0, count: 10),
                                  preamp: enabled ? preamp : 0,
                                  clipGuard: enabled && clipGuard)
    }

    private func persist() {
        let d = UserDefaults.standard
        d.set(gains, forKey: "eq.gains")
        d.set(preamp, forKey: "eq.preamp")
        d.set(enabled, forKey: "eq.enabled")
        d.set(clipGuard, forKey: "eq.clipGuard")
        d.set(presetName, forKey: "eq.preset")
        d.set(try? JSONEncoder().encode(customPresets), forKey: "eq.custom")
    }

    /// The combined response of all bands, in dB, at a given frequency (for drawing the curve).
    static func response(at freq: Double, gains: [Float], sampleRate: Double = 44100) -> Double {
        var total = 0.0
        for (i, g) in gains.enumerated() where g != 0 {
            let c = Biquad.coefficients(band: i, gain: Double(g), sampleRate: sampleRate)
            total += c.magnitudeDB(at: freq, sampleRate: sampleRate)
        }
        return total
    }
}

// MARK: - Filter math (standard "audio EQ cookbook" biquads)

struct Biquad {
    var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0

    static func coefficients(band: Int, gain: Double, sampleRate fs: Double) -> Biquad {
        let f = min(Double(Equalizer.frequencies[band]), fs * 0.45)
        let A = pow(10, gain / 40)
        let w0 = 2 * Double.pi * f / fs
        let cw = cos(w0), sw = sin(w0)
        var b0, b1, b2, a0, a1, a2: Double
        if band == 0 || band == Equalizer.frequencies.count - 1 {
            let alpha = sw / 2 * sqrt(2.0)          // shelf slope 1
            let sa = 2 * sqrt(A) * alpha
            if band == 0 {                          // low shelf
                b0 = A * ((A + 1) - (A - 1) * cw + sa)
                b1 = 2 * A * ((A - 1) - (A + 1) * cw)
                b2 = A * ((A + 1) - (A - 1) * cw - sa)
                a0 = (A + 1) + (A - 1) * cw + sa
                a1 = -2 * ((A - 1) + (A + 1) * cw)
                a2 = (A + 1) + (A - 1) * cw - sa
            } else {                                // high shelf
                b0 = A * ((A + 1) + (A - 1) * cw + sa)
                b1 = -2 * A * ((A - 1) + (A + 1) * cw)
                b2 = A * ((A + 1) + (A - 1) * cw - sa)
                a0 = (A + 1) - (A - 1) * cw + sa
                a1 = 2 * ((A - 1) - (A + 1) * cw)
                a2 = (A + 1) - (A - 1) * cw - sa
            }
        } else {                                    // peaking, about one octave wide
            let alpha = sw / (2 * 1.41)
            b0 = 1 + alpha * A
            b1 = -2 * cw
            b2 = 1 - alpha * A
            a0 = 1 + alpha / A
            a1 = -2 * cw
            a2 = 1 - alpha / A
        }
        return Biquad(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }

    func magnitudeDB(at freq: Double, sampleRate fs: Double) -> Double {
        let w = 2 * Double.pi * freq / fs
        let c1 = cos(w), s1 = sin(w), c2 = cos(2 * w), s2 = sin(2 * w)
        let nr = b0 + b1 * c1 + b2 * c2, ni = -(b1 * s1 + b2 * s2)
        let dr = 1 + a1 * c1 + a2 * c2, di = -(a1 * s1 + a2 * s2)
        let mag = sqrt((nr * nr + ni * ni) / max(dr * dr + di * di, 1e-12))
        return 20 * log10(max(mag, 1e-9))
    }
}

// MARK: - Shared between the audio thread and the app

/// Holds the current EQ settings for the audio thread, plus the latest audio for the spectrum display.
final class EQProcessor {
    static let shared = EQProcessor()

    private var lock = os_unfair_lock()
    private var _gains = [Float](repeating: 0, count: 10)
    private var _preamp: Float = 0
    private var _clipGuard = true
    private var _version = 0

    // spectrum
    static let fftSize = 2048
    private var ring = [Float](repeating: 0, count: EQProcessor.fftSize)
    private var ringPos = 0
    private var _sampleRate: Double = 44100
    var spectrumEnabled = false

    func update(gains: [Float], preamp: Float, clipGuard: Bool) {
        os_unfair_lock_lock(&lock)
        _gains = gains; _preamp = preamp; _clipGuard = clipGuard; _version += 1
        os_unfair_lock_unlock(&lock)
    }

    func snapshot() -> (gains: [Float], preamp: Float, clipGuard: Bool, version: Int) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return (_gains, _preamp, _clipGuard, _version)
    }

    func currentVersion() -> Int {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return _version
    }

    /// Called from the audio thread with mono samples after the EQ.
    func feed(_ samples: UnsafePointer<Float>, count: Int, sampleRate: Double) {
        guard spectrumEnabled else { return }
        os_unfair_lock_lock(&lock)
        _sampleRate = sampleRate
        let n = ring.count
        for i in 0..<count {
            ring[ringPos] = samples[i]
            ringPos = (ringPos + 1) % n
        }
        os_unfair_lock_unlock(&lock)
    }

    // MARK: FFT for the visualizer (runs on the main thread, ~30 times a second)

    private let log2n = vDSP_Length(11)
    private lazy var fftSetup: FFTSetup? = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
    private lazy var window: [Float] = {
        var w = [Float](repeating: 0, count: EQProcessor.fftSize)
        vDSP_hann_window(&w, vDSP_Length(EQProcessor.fftSize), Int32(vDSP_HANN_NORM))
        return w
    }()
    private var smoothed = [Float](repeating: 0, count: 64)

    /// Returns `bins` values between 0 and 1, spaced like hearing (log frequency).
    func spectrum(bins: Int = 64) -> [Float] {
        let n = EQProcessor.fftSize
        if smoothed.count != bins { smoothed = [Float](repeating: 0, count: bins) }
        os_unfair_lock_lock(&lock)
        var samples = [Float](repeating: 0, count: n)
        for i in 0..<n { samples[i] = ring[(ringPos + i) % n] }
        let fs = _sampleRate
        os_unfair_lock_unlock(&lock)
        guard let setup = fftSetup else { return smoothed }

        var windowed = [Float](repeating: 0, count: n)
        vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(n))
        var real = [Float](repeating: 0, count: n / 2)
        var imag = [Float](repeating: 0, count: n / 2)
        var mags = [Float](repeating: 0, count: n / 2)
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBufferPointer { sp in
                    sp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { cp in
                        vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                mags.withUnsafeMutableBufferPointer { mp in
                    vDSP_zvabs(&split, 1, mp.baseAddress!, 1, vDSP_Length(n / 2))
                }
            }
        }

        let binHz = fs / Double(n)
        let lo = 25.0, hi = min(20000.0, fs / 2)
        for b in 0..<bins {
            let f0 = lo * pow(hi / lo, Double(b) / Double(bins))
            let f1 = lo * pow(hi / lo, Double(b + 1) / Double(bins))
            let i0 = max(1, Int(f0 / binHz)), i1 = max(i0 + 1, min(n / 2, Int(f1 / binHz)))
            var peak: Float = 0
            for i in i0..<i1 { peak = max(peak, mags[i]) }
            let db = 20 * log10(peak / Float(n) + 1e-9)
            let level = min(1, max(0, (db + 72) / 62))
            smoothed[b] = level > smoothed[b] ? level * 0.6 + smoothed[b] * 0.4 : smoothed[b] * 0.86 + level * 0.14
        }
        return smoothed
    }
}
