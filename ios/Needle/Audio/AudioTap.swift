import AVFoundation
import MediaToolbox

/// One chopper for every song, so the time chops add to a song carries over into the start of the next one
/// (it plays out first) instead of being cut off when the song file ends.
final class ChopHub {
    static let shared = ChopHub()
    var chopper: Chopper?
    /// Called from tap set-up (not the audio thread): makes the memory ahead of time.
    func prepare(sampleRate: Double, channels: Int) {
        if chopper == nil {      // a different rate is handled when that song actually plays (never swap mid-song)
            let c = Chopper(sampleRate: sampleRate)
            c.prepare(channels: channels)
            chopper = c
        }
    }
}

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
    var sinceStatus = 0
    var songSecondsPerFrame: Double = 0     // how much of the song one frame here covers (depends on where the tap sits)
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
        let hub = ChopHub.shared
        if hub.chopper == nil || hub.chopper!.sampleRate != sampleRate { hub.chopper = Chopper(sampleRate: sampleRate) }   // rare: a song at a new sample rate
        if let chopper = hub.chopper {
            let taps = screw.takeTaps()
            if taps.reset { chopper.reset() }
            let sc = screw.takeScratch()
            if screw.isOn || chopper.active != nil || chopper.lag > 0 || chopper.scr != nil {
                let lagBefore = chopper.lag
                // the turntable: heard seconds <-> frames here (the tap may sit before or after the speed change)
                let songPerFrame = songSecondsPerFrame > 0 ? songSecondsPerFrame : 1 / sampleRate
                let framesPerHeardSecond = Double(screw.speed.rate) / songPerFrame
                if sc.down { chopper.scratchDown() }
                if sc.offset != nil || sc.speed != nil {
                    // speed is already in "playing speeds": 1 = one frame per frame here, whichever side of the speed change
                    chopper.scratchMove(sc.offset.map { $0 * framesPerHeardSecond }, speed: sc.speed)
                }
                if sc.up {
                    let over = chopper.scratchUp()
                    let prev = screw.scratchResult.seq
                    screw.scratchResult = (prev + 1, over * songPerFrame)
                }
                if let m = taps.move { chopper.trigger(m, hold: taps.hold) }
                if taps.release { chopper.release() }       // after the tap: a quick tap on Loop is one repeat
                chopper.process(channels, frames: frames, amount: screw.chops)
                sinceStatus += frames
                if sinceStatus >= Int(sampleRate) || chopper.lag != lagBefore && chopper.active == nil {   // for the Screw sheet and the player
                    sinceStatus = 0
                    var st = chopper.status
                    st.lag = Double(chopper.lag) * (songSecondsPerFrame > 0 ? songSecondsPerFrame : 1 / sampleRate)
                    screw.status = st
                }
            } else if taps.reset {
                var st = chopper.status; st.lag = 0; screw.status = st
            }
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
    ChopHub.shared.prepare(sampleRate: asbd.mSampleRate, channels: Int(asbd.mChannelsPerFrame))
}

private let tapUnprepare: MTAudioProcessingTapUnprepareCallback = { _ in }

private let tapProcess: MTAudioProcessingTapProcessCallback = { tap, frames, _, bufferList, framesOut, flagsOut in
    var range = CMTimeRange.zero
    guard MTAudioProcessingTapGetSourceAudio(tap, frames, bufferList, flagsOut, &range, framesOut) == noErr else { return }
    let ctx = Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
    // a jump in the song (scrubbing): start the beat tracking and chop memory over. A new song's first block
    // isn't a jump: whatever chops added to the last song plays out first.
    let start = range.start.seconds, frames = Int(framesOut.pointee)
    if start.isFinite, frames > 0 {
        let dur = range.duration.seconds
        if dur.isFinite, dur > 0 { ctx.songSecondsPerFrame = dur / Double(frames) }
        let step = ctx.songSecondsPerFrame > 0 ? ctx.songSecondsPerFrame : 1 / ctx.sampleRate
        if ctx.expectedStart >= 0, abs(start - ctx.expectedStart) > 0.05 { ChopHub.shared.chopper?.reset() }
        ctx.expectedStart = start + Double(frames) * step
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
