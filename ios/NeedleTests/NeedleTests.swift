import CoreGraphics
import XCTest
@testable import Needle

/// Lines starting with METRIC are collected by the GitHub build and shown on the run.
private func metric(_ s: String) { print("METRIC \(s)") }

// MARK: - Lyrics

final class LyricsTests: XCTestCase {
    func testBasicTimestamp() {
        XCTAssertEqual(Lyrics.parseLRC("[00:12.50]Hello"), [LyricLine(t: 12.5, text: "Hello")])
    }

    func testColonMilliseconds() {
        XCTAssertEqual(Lyrics.parseLRC("[01:02:30]Colon ms").first!.t, 62.3, accuracy: 1e-6)
    }

    func testTwoStampsOnOneLineAppearTwiceInOrder() {
        XCTAssertEqual(Lyrics.parseLRC("[00:03]Twice\n[00:01.5]x").map(\.t), [1.5, 3.0])
        XCTAssertEqual(Lyrics.parseLRC("[00:01.5][00:03]Twice").map(\.t), [1.5, 3.0])
    }

    func testOffsetTagIsApplied() {
        XCTAssertEqual(Lyrics.parseLRC("[offset:+500]\n[00:10.00]Shifted").first!.t, 9.5, accuracy: 1e-6)
    }

    func testTagOnlyAndPlainLinesIgnored() {
        XCTAssertEqual(Lyrics.parseLRC("no stamps here\n[ar:Artist]"), [])
    }

    func testWindowsLineEndings() {
        XCTAssertEqual(Lyrics.parseLRC("[00:01.00]a\r\n[00:02.00]b").map(\.text), ["a", "b"])
    }

    func testIndexAtTime() {
        let l = Lyrics(synced: true, source: "t", lines: (0..<10).map { LyricLine(t: Double($0) * 2.5, text: "\($0)") })
        XCTAssertEqual(l.index(at: -1), -1)
        XCTAssertEqual(l.index(at: 0), 0)
        XCTAssertEqual(l.index(at: 10.05), 4)
        XCTAssertEqual(l.index(at: 999), 9)
    }

    func testNavidromeResponseDecodes() throws {
        let json = """
        {"subsonic-response":{"status":"ok","version":"1.16.1","lyricsList":{"structuredLyrics":[
          {"synced":false,"line":[{"value":"plain"}]},
          {"synced":true,"offset":-250,"line":[{"start":0,"value":"one"},{"start":2500,"value":"two"}]}]}}}
        """
        let env = try JSONDecoder().decode(SubsonicEnvelope.self, from: Data(json.utf8))
        let lyrics = try XCTUnwrap(Lyrics.from(navidrome: env.response.lyricsList?.structuredLyrics ?? []))
        XCTAssertTrue(lyrics.synced, "synced lyrics are preferred over plain ones")
        XCTAssertEqual(lyrics.source, "your files")
        XCTAssertEqual(lyrics.lines.map(\.text), ["one", "two"])
        XCTAssertEqual(lyrics.lines[1].t, 2.75, accuracy: 1e-6, "negative offset delays lines")
    }

    func testNavidromeWithNoLyrics() throws {
        let json = #"{"subsonic-response":{"status":"ok","version":"1.16.1","lyricsList":{}}}"#
        let env = try JSONDecoder().decode(SubsonicEnvelope.self, from: Data(json.utf8))
        XCTAssertNil(Lyrics.from(navidrome: env.response.lyricsList?.structuredLyrics ?? []))
    }

    func testLRCLIBDecodes() throws {
        let json = #"{"id":1,"trackName":"X","duration":201,"instrumental":false,"plainLyrics":"a\nb","syncedLyrics":"[00:01.00]a\n[00:04.20]b"}"#
        let r = try JSONDecoder().decode(LRCLIBResult.self, from: Data(json.utf8))
        let l = try XCTUnwrap(Lyrics.from(lrclib: r))
        XCTAssertTrue(l.synced)
        XCTAssertEqual(l.source, "LRCLIB")
        XCTAssertEqual(l.lines.map(\.t), [1.0, 4.2])
    }

    func testLRCLIBPlainAndInstrumental() throws {
        let plain = try JSONDecoder().decode(LRCLIBResult.self, from: Data(#"{"plainLyrics":"x\ny","syncedLyrics":null}"#.utf8))
        XCTAssertEqual(Lyrics.from(lrclib: plain)?.synced, false)
        let inst = try JSONDecoder().decode(LRCLIBResult.self, from: Data(#"{"instrumental":true}"#.utf8))
        XCTAssertEqual(Lyrics.from(lrclib: inst)?.instrumental, true)
    }
}

// MARK: - Equalizer math

final class EqualizerTests: XCTestCase {
    func testFlatIsFlat() {
        for f in [30.0, 250, 1000, 8000, 16000] {
            XCTAssertEqual(Equalizer.response(at: f, gains: Array(repeating: 0, count: 10)), 0, accuracy: 1e-9)
        }
    }

    func testBoostHitsItsBand() {
        var g = [Float](repeating: 0, count: 10)
        g[5] = 6                                  // 1 kHz
        XCTAssertEqual(Equalizer.response(at: 1000, gains: g), 6, accuracy: 0.3)
        XCTAssertLessThan(abs(Equalizer.response(at: 100, gains: g)), 0.5, "a 1 kHz boost barely touches the bass")
    }

    func testShelvesReachTheEnds() {
        var g = [Float](repeating: 0, count: 10)
        g[0] = -8
        g[9] = 8
        XCTAssertEqual(Equalizer.response(at: 20, gains: g), -8, accuracy: 1)
        XCTAssertEqual(Equalizer.response(at: 19000, gains: g), 8, accuracy: 1)
    }
}

// MARK: - Visualizer

final class VisualizerTests: XCTestCase {
    /// Test music: a kick drum `bpm` times a minute over steady mids and highs.
    private func input(_ t: Double, bpm: Double = 120, quiet: Bool = false) -> VizInput {
        let period = 60 / bpm
        let kick = !quiet && t.truncatingRemainder(dividingBy: period) < 0.07
        var levels = [Float](repeating: 0.2, count: VizEngine.bins)
        for b in 0..<6 { levels[b] = quiet ? 0.05 : (kick ? 0.85 : 0.25) }
        for b in 6..<25 { levels[b] = quiet ? 0.05 : Float(0.4 + 0.1 * sin(t * 3 + Double(b))) }
        let wave = (0..<256).map { Float(sin(Double($0) / 256 * .pi * 8 + t * 6) * 0.5) }
        return VizInput(levels: levels, wave: wave, live: true)
    }

    @discardableResult
    private func run(_ e: VizEngine, seconds: Double, from start: Double = 0, fps: Double = 60, keep: Bool = false,
                     make: (Double) -> VizInput) -> [CGImage] {
        var frames: [CGImage] = []
        var t = start
        while t < start + seconds {
            autoreleasepool {
                let img = e.render(time: t, dt: 1 / fps, input: make(t))
                if keep, let img { frames.append(img) }
            }
            t += 1 / fps
        }
        return frames
    }

    private func brightness(_ img: CGImage) -> Double {
        let ctx = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 64,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: 16, height: 16))
        let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
        var s = 0.0
        for i in stride(from: 0, to: 16 * 16 * 4, by: 4) { s += Double(p[i]) + Double(p[i + 1]) + Double(p[i + 2]) }
        return s / (16 * 16 * 3)
    }

    private func variance(_ xs: [Double]) -> Double {
        let m = xs.reduce(0, +) / Double(xs.count)
        return xs.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(xs.count)
    }

    private func maxPerSecond(_ log: [Double]) -> Int {
        log.map { t in log.filter { $0 >= t && $0 < t + 1 }.count }.max() ?? 0
    }

    func testBeatDetectionMatches120BPM() {
        let e = VizEngine()
        e.resize(width: 200, height: 200)
        run(e, seconds: 1, make: { self.input($0) })
        e.resetStats()
        run(e, seconds: 10, from: 1, make: { self.input($0) })
        let bps = Double(e.stats.beats) / 10
        metric("viz.beats_per_second=\(String(format: "%.2f", bps)) (track is 120 BPM = 2.0)")
        XCTAssertEqual(bps, 2, accuracy: 0.5)
    }

    func testNeverMoreThanThreeFlashesPerSecond() {
        let e = VizEngine()
        e.resize(width: 200, height: 200)
        run(e, seconds: 10, make: { self.input($0, bpm: 480) })     // a very fast beat to push the limit
        let worst = maxPerSecond(e.stats.flashLog)
        metric("viz.max_flashes_per_second=\(worst) (limit 3), beats=\(e.stats.beats)")
        XCTAssertLessThanOrEqual(worst, 3)
        XCTAssertGreaterThan(e.stats.flashes, 0)
    }

    func testReduceMotionHasNoFlashesButStillReacts() {
        let e = VizEngine()
        e.reducedMotion = true
        e.resize(width: 200, height: 200)
        run(e, seconds: 6, make: { self.input($0) })
        metric("viz.reduce_motion flashes=\(e.stats.flashes) beats=\(e.stats.beats)")
        XCTAssertEqual(e.stats.flashes, 0)
        XCTAssertGreaterThan(e.stats.beats, 5)
    }

    func testReactsToMusicAndIdlesWhenPaused() {
        for mode in VizEngine.Mode.allCases {
            let e = VizEngine()
            e.mode = mode
            e.resize(width: 160, height: 160)
            let liveFrames = run(e, seconds: 3, keep: true, make: { self.input($0) }).suffix(120)
            let liveBass = e.bass
            let idleFrames = run(e, seconds: 3, from: 3, keep: true, make: { _ in VizInput(levels: [], wave: [], live: false) }).suffix(120)
            let lv = variance(liveFrames.enumerated().filter { $0.offset % 4 == 0 }.map { brightness($0.element) })
            let iv = variance(idleFrames.enumerated().filter { $0.offset % 4 == 0 }.map { brightness($0.element) })
            metric("viz.\(mode.name) pulse variance live=\(String(format: "%.1f", lv)) idle=\(String(format: "%.2f", iv)) bass live=\(String(format: "%.2f", liveBass)) idle=\(String(format: "%.2f", e.bass))")
            XCTAssertGreaterThan(liveBass, e.bass, "\(mode.name): bass is higher with music")
            XCTAssertFalse(e.live, "\(mode.name): paused means idle")
            XCTAssertGreaterThan(brightness(idleFrames.last!), 0.05, "\(mode.name): idle picture isn't black")
        }
    }

    func testAutoModeSwitchesOnADrop() {
        let e = VizEngine()
        e.auto = true
        e.resize(width: 160, height: 160)
        var switched: [VizEngine.Mode] = []
        e.onModeChange = { switched.append($0) }
        run(e, seconds: 4, make: { self.input($0) })
        run(e, seconds: 2.5, from: 4, make: { self.input($0, quiet: true) })
        run(e, seconds: 1, from: 6.5, make: { self.input($0) })
        XCTAssertEqual(switched.count, 1, "one switch when the beat drops back in")
        XCTAssertEqual(e.mode, .prism)
    }

    func testManualModeNeverSwitchesByItself() {
        let e = VizEngine()
        e.resize(width: 160, height: 160)
        run(e, seconds: 4, make: { self.input($0) })
        run(e, seconds: 2.5, from: 4, make: { self.input($0, quiet: true) })
        run(e, seconds: 50, from: 6.5, make: { self.input($0) })
        XCTAssertEqual(e.stats.modeSwitches, 0)
        XCTAssertEqual(e.mode, .tunnel)
    }

    func testFrameTimesAreFastEnough() {
        for size in [360, 700] {
            for mode in VizEngine.Mode.allCases {
                let e = VizEngine()
                e.mode = mode
                e.resize(width: size, height: size)
                run(e, seconds: 0.5, make: { self.input($0) })                 // warm up
                var times: [Double] = []
                var t = 0.5
                for _ in 0..<180 {
                    let start = CFAbsoluteTimeGetCurrent()
                    autoreleasepool { _ = e.render(time: t, dt: 1 / 60, input: input(t)) }
                    times.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
                    t += 1 / 60
                }
                times.sort()
                let avg = times.reduce(0, +) / Double(times.count), p95 = times[Int(Double(times.count) * 0.95)]
                metric("viz.frame_ms \(mode.name) \(size)px avg=\(String(format: "%.2f", avg)) p95=\(String(format: "%.2f", p95))")
                if size == 360 {
                    XCTAssertLessThan(avg, 8, "\(mode.name) at \(size)px: average frame must leave room for 60 fps")
                    XCTAssertLessThan(p95, 14, "\(mode.name) at \(size)px: no big stutters")
                }
            }
        }
    }

    func testNoMemoryGrowthOverALongSession() {
        let e = VizEngine()
        e.resize(width: 400, height: 400)
        run(e, seconds: 2, make: { self.input($0) })
        let before = residentMB()
        for (i, mode) in VizEngine.Mode.allCases.enumerated() {
            e.mode = mode
            run(e, seconds: 8, from: 2 + Double(i) * 8, make: { self.input($0) })
        }
        let after = residentMB()
        metric("viz.memory before=\(String(format: "%.1f", before))MB after=\(String(format: "%.1f", after))MB over 1920 frames")
        XCTAssertLessThan(after - before, 15)
    }

    func testResizeKeepsWorking() {
        let e = VizEngine()
        e.resize(width: 390, height: 390)
        run(e, seconds: 0.5, make: { self.input($0) })
        e.resize(width: 844, height: 390)
        let img = e.render(time: 1, dt: 1 / 60, input: input(1))
        XCTAssertEqual(img?.width, 844)
        XCTAssertEqual(img?.height, 390)
    }

    private func residentMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : 0
    }
}
