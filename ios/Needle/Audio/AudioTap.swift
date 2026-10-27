import AVFoundation
import MediaToolbox

/// Hooks into AVPlayer's audio as it plays (streamed or local) and runs it through the
/// equalizer. One context per song; all of them read the shared EQ settings.
final class TapContext {
    var sampleRate: Double = 44100
    var isFloat = true
    var interleaved = false
    var version = -1
    var coeffs: [Biquad] = []
    var state: [Double] = []      // z1, z2 for every channel x band
    var gain: Float = 1
    var mono: [Float] = []
    var channelsInState = 0
    var chopper: Chopper?
    var expectedStart: Double = -1          // where the next block should start in the song (to notice seeks)

    func rebuild(channels: Int) {
        let snap = EQProcessor.shared.snapshot()
        version = snap.version
        coeffs = snap.gains.enumerated().compactMap { i, g in
            g == 0 ? nil : Biquad.coefficients(band: i, gain: Double(g), sampleRate: sampleRate)
        }
        let maxBoost = max(0, snap.gains.max() ?? 0)
        var g = pow(10, snap.preamp / 20)
        if snap.clipGuard { g *= pow(10, -maxBoost * 0.6 / 20) }
        gain = g
        channelsInState = channels
        state = [Double](repeating: 0, count: max(1, channels * coeffs.count * 2))
    }

    func process(_ abl: UnsafeMutableAudioBufferListPointer, frames: Int) {
        guard isFloat, frames > 0 else { return }

        // work out how the samples are laid out
        var channels: [(UnsafeMutablePointer<Float>, Int)] = []   // pointer + stride
        if interleaved, let buf = abl.first, let data = buf.mData {
            let n = Int(buf.mNumberChannels)
            let p = data.assumingMemoryBound(to: Float.self)
            for c in 0..<n { channels.append((p + c, n)) }
        } else {
            for buf in abl {
                if let data = buf.mData { channels.append((data.assumingMemoryBound(to: Float.self), 1)) }
            }
        }
        guard !channels.isEmpty else { return }

        if EQProcessor.shared.currentVersion() != version || channels.count != channelsInState {
            rebuild(channels: channels.count)
        }

        let bands = coeffs.count
        let g = gain
        if bands > 0 || g != 1 {
            for (ci, (p, stride)) in channels.enumerated() {
                for bi in 0..<bands {
                    let c = coeffs[bi]
                    let si = (ci * bands + bi) * 2
                    var z1 = state[si], z2 = state[si + 1]
                    var i = 0
                    while i < frames {
                        let x = Double(p[i * stride])
                        let y = c.b0 * x + z1
                        z1 = c.b1 * x - c.a1 * y + z2
                        z2 = c.b2 * x - c.a2 * y
                        p[i * stride] = Float(y)
                        i += 1
                    }
                    state[si] = z1; state[si + 1] = z2
                }
                if g != 1 || bands > 0 {
                    var i = 0
                    while i < frames {
                        let v = p[i * stride] * g
                        p[i * stride] = v > 1 ? 1 : (v < -1 ? -1 : v)
                        i += 1
                    }
                }
            }
        }

        // slowed & chopped: the beat tracker listens whenever screw mode is on, chops cut in on the beat
        let screw = ScrewSettings.shared
        if screw.isOn || chopper?.active != nil {
            if chopper == nil { chopper = Chopper(sampleRate: sampleRate) }
            chopper?.process(channels, frames: frames, amount: screw.chops)
        }

        // send a copy to the spectrum display
        if EQProcessor.shared.spectrumEnabled, frames <= mono.count {
            let (p, stride) = channels[0]
            for i in 0..<frames { mono[i] = p[i * stride] }
            mono.withUnsafeBufferPointer { EQProcessor.shared.feed($0.baseAddress!, count: frames, sampleRate: sampleRate) }
        }
    }
}

private let tapInit: MTAudioProcessingTapInitCallback = { _, clientInfo, storageOut in
    storageOut.pointee = clientInfo
}

private let tapFinalize: MTAudioProcessingTapFinalizeCallback = { tap in
    Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
}

private let tapPrepare: MTAudioProcessingTapPrepareCallback = { tap, maxFrames, format in
    let ctx = Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
    let asbd = format.pointee
    ctx.sampleRate = asbd.mSampleRate
    ctx.isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 && asbd.mBitsPerChannel == 32
    ctx.interleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
    ctx.mono = [Float](repeating: 0, count: max(4096, Int(maxFrames)))
    ctx.version = -1
    let chopper = Chopper(sampleRate: asbd.mSampleRate)
    chopper.prepare(channels: Int(asbd.mChannelsPerFrame))
    ctx.chopper = chopper
}

private let tapUnprepare: MTAudioProcessingTapUnprepareCallback = { _ in }

private let tapProcess: MTAudioProcessingTapProcessCallback = { tap, frames, _, bufferList, framesOut, flagsOut in
    var range = CMTimeRange.zero
    guard MTAudioProcessingTapGetSourceAudio(tap, frames, bufferList, flagsOut, &range, framesOut) == noErr else { return }
    let ctx = Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
    // a jump in the song (scrubbing): start the beat tracking and chop memory over
    let start = range.start.seconds
    if start.isFinite {
        if ctx.expectedStart >= 0, abs(start - ctx.expectedStart) > 0.05 { ctx.chopper?.reset() }
        ctx.expectedStart = start + Double(framesOut.pointee) / ctx.sampleRate
    }
    ctx.process(UnsafeMutableAudioBufferListPointer(bufferList), frames: Int(framesOut.pointee))
}

enum AudioTap {
    /// Attaches the equalizer to a player item's audio.
    static func attach(to item: AVPlayerItem, track: AVAssetTrack) {
        let ctx = Unmanaged.passRetained(TapContext())
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: ctx.toOpaque(),
            init: tapInit, finalize: tapFinalize, prepare: tapPrepare, unprepare: tapUnprepare, process: tapProcess)
        var unmanaged: Unmanaged<MTAudioProcessingTap>?
        let err = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks,
                                             kMTAudioProcessingTapCreationFlag_PostEffects, &unmanaged)
        guard err == noErr, let tap = unmanaged?.takeRetainedValue() else {
            ctx.release()
            return
        }
        let params = AVMutableAudioMixInputParameters(track: track)
        params.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [params]
        item.audioMix = mix
    }
}
