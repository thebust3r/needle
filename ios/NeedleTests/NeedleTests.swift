import CoreGraphics
import SwiftUI
import UIKit
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
        XCTAssertEqual(Equalizer.response(at: 10, gains: g), -8, accuracy: 1)
        XCTAssertLessThan(Equalizer.response(at: 20, gains: g), -6, "most of the cut already applies at 20 Hz")
        XCTAssertEqual(Equalizer.response(at: 19000, gains: g), 8, accuracy: 1)
    }
}

// MARK: - Visualizer

final class VisualizerTests: XCTestCase {
    /// Test music: a kick drum `bpm` times a minute over steady mids and highs.
    private func input(_ t: Double, bpm: Double = 120, quiet: Bool = false, gain: Float = 1) -> VizInput {
        let period = 60 / bpm
        let kick = !quiet && t.truncatingRemainder(dividingBy: period) < 0.07
        var levels = [Float](repeating: 0.2 * gain, count: VizEngine.bins)
        for b in 0..<6 { levels[b] = quiet ? 0.05 : (kick ? 0.85 : 0.25) * gain }
        for b in 6..<25 { levels[b] = quiet ? 0.05 : Float(0.4 + 0.1 * sin(t * 3 + Double(b))) * gain }
        let wave = (0..<256).map { Float(sin(Double($0) / 256 * .pi * 8 + t * 6) * 0.5) * gain }
        return VizInput(levels: levels, wave: wave, live: true)
    }

    /// Feeds the engine `seconds` of music at 60 fps (no drawing).
    private func run(_ e: VizEngine, seconds: Double, from start: Double = 0, fps: Double = 60, make: (Double) -> VizInput) {
        var t = start
        while t < start + seconds { e.update(time: t, dt: 1 / fps, input: make(t)); t += 1 / fps }
    }

    /// Feeds and draws on the graphics chip; returns brightness of each frame (0...255) when `sample` is set.
    @discardableResult
    private func render(_ e: VizEngine, _ r: VizRenderer, size: (Int, Int) = (160, 160), seconds: Double, from start: Double = 0,
                        sampleEvery: Int = 0, make: (Double) -> VizInput) -> [Double] {
        guard let out = r.makeOutput(width: size.0, height: size.1) else { XCTFail("no output"); return [] }
        var t = start, i = 0, values: [Double] = []
        while t < start + seconds {
            e.update(time: t, dt: 1 / 60, input: make(t))
            let done = DispatchSemaphore(value: 0)
            r.draw(engine: e, width: size.0, height: size.1, output: out, completion: { done.signal() })
            done.wait()
            if sampleEvery > 0 && i % sampleEvery == 0 { values.append(brightness(r.readBack(out))) }
            t += 1 / 60; i += 1
        }
        return values
    }

    private func brightness(_ px: [UInt8]) -> Double {
        guard !px.isEmpty else { return 0 }
        var s = 0.0
        var n = 0
        for i in stride(from: 0, to: px.count, by: 4 * 7) { s += Double(px[i]) + Double(px[i + 1]) + Double(px[i + 2]); n += 3 }
        return s / Double(n)
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
        run(e, seconds: 1, make: { self.input($0) })
        e.resetStats()
        run(e, seconds: 10, from: 1, make: { self.input($0) })
        let bps = Double(e.stats.beats) / 10
        metric("viz.beats_per_second=\(String(format: "%.2f", bps)) (track is 120 BPM = 2.0)")
        XCTAssertEqual(bps, 2, accuracy: 0.5)
    }

    func testNeverMoreThanThreeFlashesPerSecond() {
        let e = VizEngine()
        run(e, seconds: 10, make: { self.input($0, bpm: 240) })     // 4 beats a second: tries to flash too often
        let worst = maxPerSecond(e.stats.flashLog)
        metric("viz.max_flashes_per_second=\(worst) (limit 3), beats=\(e.stats.beats), flashes=\(e.stats.flashes)")
        XCTAssertGreaterThan(e.stats.beats, 35, "the test really does beat ~4 times a second")
        XCTAssertLessThanOrEqual(worst, 3)
        XCTAssertLessThan(e.stats.flashes, e.stats.beats, "some flashes were held back")
        XCTAssertGreaterThan(e.stats.flashes, 20)
    }

    func testFlashLimitHoldsAtMaxReactivity() {
        let e = VizEngine()
        e.look.intensity = 2
        run(e, seconds: 10, make: { self.input($0, bpm: 240) })
        XCTAssertLessThanOrEqual(maxPerSecond(e.stats.flashLog), 3, "turning reactivity up never breaks the flash limit")
    }

    func testReduceMotionHasNoFlashesButStillReacts() {
        let e = VizEngine()
        e.reducedMotion = true
        run(e, seconds: 6, make: { self.input($0) })
        metric("viz.reduce_motion flashes=\(e.stats.flashes) beats=\(e.stats.beats)")
        XCTAssertEqual(e.stats.flashes, 0)
        XCTAssertGreaterThan(e.stats.beats, 5)
    }

    func testQuietSongsAreBoosted() {
        let loud = VizEngine(), quiet = VizEngine()
        run(loud, seconds: 4, make: { self.input($0) })
        run(quiet, seconds: 4, make: { self.input($0, gain: 0.35) })
        let ratio = quiet.bass / loud.bass
        metric("viz.quiet_song shown_bass=\(String(format: "%.0f", ratio * 100))% of a loud song at 35% volume")
        XCTAssertGreaterThan(ratio, 0.55, "a song at a third of the volume still moves it more than half as much")
    }

    func testReactivitySlider() {
        let chill = VizEngine(), hype = VizEngine()
        chill.look.intensity = 0.5; hype.look.intensity = 2
        run(chill, seconds: 3, make: { self.input($0) })
        run(hype, seconds: 3, make: { self.input($0) })
        XCTAssertGreaterThan(hype.bass, chill.bass * 2.5)
    }

    func testAlwaysFlowing() {
        let e = VizEngine()
        run(e, seconds: 1, make: { self.input($0) })
        let f0 = e.flow
        run(e, seconds: 1, from: 1, make: { self.input($0) })
        XCTAssertGreaterThan(e.flow - f0, 0.4, "the current keeps moving")
        let idle = VizEngine()
        run(idle, seconds: 1, make: { _ in VizInput(levels: [], wave: [], live: false) })
        XCTAssertGreaterThan(idle.flow, 0.1, "even when paused it drifts gently")
        XCTAssertLessThan(idle.flow, e.flow - f0, "and drifts faster with music")
    }

    func testTouch() {
        let e = VizEngine()
        e.drag(to: 0.3, 0.3, moved: 0.2)
        XCTAssertGreaterThan(e.touchSwirl, 0.5)
        run(e, seconds: 1.5, make: { self.input($0) })
        XCTAssertLessThan(e.touchSwirl, 0.05, "the swirl settles after you let go")
        e.tap(at: 0.25, 0.5)
        let u = e.uniforms(width: 100, height: 100)
        XCTAssertEqual(u.tap.x, 0.25, accuracy: 0.001)
        XCTAssertEqual(u.tap.y, 0.5, accuracy: 0.001)
        XCTAssertLessThan(u.touch.w, 0.1, "burst starts right away")
    }

    func testThemes() {
        let e = VizEngine()
        e.look.theme = .fire
        XCTAssertEqual(e.palette()[0], SIMD3<Float>(1, 0.25, 0.05))
        e.look.theme = .album
        e.setColor(.blue)
        let c = e.palette()[0]
        XCTAssertGreaterThan(c.z, c.x, "Album Colors follows the cover")
    }

    func testAutoModeSwitchesOnADrop() {
        let e = VizEngine()
        e.auto = true
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
        run(e, seconds: 4, make: { self.input($0) })
        run(e, seconds: 2.5, from: 4, make: { self.input($0, quiet: true) })
        run(e, seconds: 50, from: 6.5, make: { self.input($0) })
        XCTAssertEqual(e.stats.modeSwitches, 0)
        XCTAssertEqual(e.mode, .tunnel)
    }

    func testShadersCompile() {
        XCTAssertNotNil(VizRenderer(), "the Metal shaders compile on this device")
    }

    func testEveryStyleDrawsAndReacts() throws {
        guard let r = VizRenderer() else { throw XCTSkip("no Metal device") }
        for mode in VizEngine.Mode.allCases {
            let e = VizEngine()
            e.mode = mode
            let live = render(e, r, seconds: 2.5, sampleEvery: 3, make: { self.input($0) }).suffix(30)
            let idle = render(e, r, seconds: 2.5, from: 2.5, sampleEvery: 3, make: { _ in VizInput(levels: [], wave: [], live: false) }).suffix(30)
            let lv = variance(Array(live)), lb = live.reduce(0, +) / Double(live.count), ib = idle.last ?? 0
            metric("viz.\(mode.name) brightness=\(String(format: "%.0f", lb)) pulse_live=\(String(format: "%.1f", lv)) idle_brightness=\(String(format: "%.1f", ib))")
            XCTAssertGreaterThan(lb, 5, "\(mode.name): lights up with music")
            XCTAssertLessThan(lb, 200, "\(mode.name): not blown out to white")
            XCTAssertGreaterThan(lv, 0.5, "\(mode.name): moves with the beat")
            XCTAssertGreaterThan(ib, 0.3, "\(mode.name): idle picture isn't black")
        }
    }

    func testMirrorAndThemesChangeThePicture() throws {
        guard let r = VizRenderer(), let out = r.makeOutput(width: 128, height: 128) else { throw XCTSkip("no Metal device") }
        func frame(_ look: VizLook) -> [UInt8] {
            let e = VizEngine()
            e.look = look
            for i in 0..<60 {
                e.update(time: Double(i) / 60, dt: 1 / 60, input: input(Double(i) / 60))
                let done = DispatchSemaphore(value: 0)
                r.draw(engine: e, width: 128, height: 128, output: out, completion: { done.signal() })
                done.wait()
            }
            return r.readBack(out)
        }
        let base = frame(VizLook()), fire = frame(VizLook(theme: .fire)), mirror = frame(VizLook(mirror: true))
        func diff(_ a: [UInt8], _ b: [UInt8]) -> Double {
            var s = 0.0
            for i in stride(from: 0, to: min(a.count, b.count), by: 4) { s += abs(Double(a[i]) - Double(b[i])) + abs(Double(a[i + 2]) - Double(b[i + 2])) }
            return s / Double(a.count / 4)
        }
        XCTAssertGreaterThan(diff(base, fire), 3, "Fire theme recolors it")
        XCTAssertGreaterThan(diff(base, mirror), 3, "the kaleidoscope mirror changes the picture")
    }

    func testFullResolutionFrameTimes() throws {
        guard let r = VizRenderer() else { throw XCTSkip("no Metal device") }
        // an iPhone 15/16 screen at full resolution (the old visualizer drew 440 px tall and stretched it)
        let w = 1179, h = 2556
        for mode in VizEngine.Mode.allCases {
            let e = VizEngine()
            e.mode = mode
            render(e, r, size: (w, h), seconds: 0.25, make: { self.input($0) })      // warm up
            r.resetTimes()
            var cpu: [Double] = []
            var t = 0.25
            for _ in 0..<90 {
                let c0 = CFAbsoluteTimeGetCurrent()
                e.update(time: t, dt: 1 / 60, input: input(t))
                cpu.append((CFAbsoluteTimeGetCurrent() - c0) * 1000)
                let out = r.makeOutput(width: w, height: h)!
                let done = DispatchSemaphore(value: 0)
                r.draw(engine: e, width: w, height: h, output: out, completion: { done.signal() })
                done.wait()
                t += 1 / 60
            }
            let gpu = r.recentGpuMs().sorted()
            let avg = gpu.reduce(0, +) / Double(max(1, gpu.count)), p95 = gpu.isEmpty ? 0 : gpu[Int(Double(gpu.count) * 0.95)]
            let cpuAvg = cpu.reduce(0, +) / Double(cpu.count)
            metric("viz.gpu_ms \(mode.name) \(w)x\(h) avg=\(String(format: "%.2f", avg)) p95=\(String(format: "%.2f", p95)) cpu=\(String(format: "%.3f", cpuAvg))ms")
            XCTAssertLessThan(avg, 8.3, "\(mode.name): full-screen frame leaves room for 60 fps")
            XCTAssertLessThan(p95, 16.7, "\(mode.name): 95% of frames fit in one 60 fps frame")
            XCTAssertLessThan(cpuAvg, 1.0, "\(mode.name): barely touches the processor (cooler phone)")
        }
    }

    func testNoMemoryGrowthOverALongSession() throws {
        guard let r = VizRenderer() else { throw XCTSkip("no Metal device") }
        let e = VizEngine()
        render(e, r, size: (400, 800), seconds: 1, make: { self.input($0) })
        let before = residentMB()
        for (i, mode) in VizEngine.Mode.allCases.enumerated() {
            e.mode = mode
            render(e, r, size: (400, 800), seconds: 3, from: 1 + Double(i) * 3, make: { self.input($0) })
        }
        let after = residentMB()
        metric("viz.memory before=\(String(format: "%.1f", before))MB after=\(String(format: "%.1f", after))MB over \(VizEngine.Mode.allCases.count * 180) frames")
        XCTAssertLessThan(after - before, 15)
    }

    func testResizeKeepsWorking() throws {
        guard let r = VizRenderer() else { throw XCTSkip("no Metal device") }
        let e = VizEngine()
        render(e, r, size: (390, 390), seconds: 0.2, make: { self.input($0) })
        XCTAssertEqual(r.size.0, 390)
        let b = render(e, r, size: (844, 390), seconds: 0.5, sampleEvery: 10, make: { self.input($0) })
        XCTAssertEqual(r.size.0, 844)
        XCTAssertEqual(r.size.1, 390)
        XCTAssertGreaterThan(b.last ?? 0, 1)
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

// MARK: - Playlist import

/// Answers requests from canned data, so the helper client can be tested without a NAS.
final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, String, Data))?
    nonisolated(unsafe) static var lastRequest: URLRequest?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastRequest = request
        let (code, type, data) = Self.handler?(request) ?? (500, "text/plain", Data())
        let resp = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: ["Content-Type": type])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class ImporterTests: XCTestCase {
    // Shaped exactly like the helper's /helper/jobs/<id> answer.
    let jobJSON = """
    {"id":"a1b2c3","created":1790000000.5,"updated":1790000001,"state":"ready","name":"Road Trip Mix","source":"https://open.spotify.com/playlist/x",
     "progress":{"done":4,"total":4},"playlistId":"pl1","found":2,"active":true,
     "counts":{"found":2,"downloading":1,"failed":1},
     "tracks":[
      {"title":"Stressed Out","artists":["Twenty One Pilots"],"duration":202,"uri":"spotify:track:1","i":0,"status":"found","songId":"s1","match":"x"},
      {"title":"Midnight City","artists":["M83"],"duration":244,"i":1,"status":"downloading","method":"song","progress":40,"note":"Downloading from goodguy"},
      {"title":"Obscure Song","artists":["Nobody Known"],"duration":180,"i":2,"status":"failed","note":"No one on Soulseek is sharing it right now"},
      {"title":"Weird Fishes","artists":["Radiohead"],"duration":318,"i":3,"status":"found","songId":"s9","note":"Downloaded"}]}
    """

    func testDecodesHelperJob() throws {
        let j = try JSONDecoder().decode(ImportJob.self, from: Data(jobJSON.utf8))
        XCTAssertEqual(j.name, "Road Trip Mix")
        XCTAssertEqual(j.tracks?.count, 4)
        XCTAssertEqual(j.missing.map(\.title), ["Obscure Song"])
        XCTAssertEqual(j.summary, "2 of 4 in your library · 1 on the way · 1 not found")
        XCTAssertEqual(j.fraction, 0.5, accuracy: 0.001)
        XCTAssertEqual(j.tracks?[1].label, "Downloading 40%")
        XCTAssertEqual(j.tracks?[3].label, "Added")
        XCTAssertEqual(j.tracks?[0].label, "")
        XCTAssertEqual(j.tracks?[2].label, "Not found")
        XCTAssertTrue(j.tracks![1].isActive)
    }

    func testSummaryWhileWorking() throws {
        let j = try JSONDecoder().decode(ImportJob.self, from: Data("""
        {"id":"x","name":"","state":"matching","found":0,"active":false,"progress":{"done":3,"total":12},"tracks":[]}
        """.utf8))
        XCTAssertEqual(j.summary, "Checking your library… 3 of 12")
        XCTAssertEqual(j.fraction, 0.25, accuracy: 0.001)
        XCTAssertTrue(j.isWorking)
    }

    func testRecentListEntryWithoutTracks() throws {
        // /helper/jobs leaves out the song list
        let j = try JSONDecoder().decode(ImportJob.self, from: Data("""
        {"id":"x","name":"Mix","state":"ready","found":8,"active":false,"counts":{"found":8,"missing":4},"progress":{"done":12,"total":12}}
        """.utf8))
        XCTAssertEqual(j.summary, "8 of 12 in your library")
    }

    func testHelperAddress() {
        var c = ServerConfig(); c.url = "http://192.168.1.168:4533"; c.username = "mason"; c.password = "pw"
        XCTAssertEqual(HelperClient.baseURL(address: "", config: c)?.absoluteString, "http://192.168.1.168:8795")
        XCTAssertEqual(HelperClient.baseURL(address: "192.168.1.168:8795/", config: c)?.absoluteString, "http://192.168.1.168:8795")
        XCTAssertEqual(HelperClient.baseURL(address: "https://music.example.com", config: c)?.absoluteString, "https://music.example.com")
        var tunnel = c; tunnel.url = "https://some-random-words.trycloudflare.com/"
        XCTAssertEqual(HelperClient.baseURL(address: "", config: tunnel)?.absoluteString, "https://some-random-words.trycloudflare.com")
        let url = HelperClient(config: c, address: "").url("jobs/abc")!.absoluteString
        XCTAssertTrue(url.hasPrefix("http://192.168.1.168:8795/helper/jobs/abc?u=mason&t="), url)
        XCTAssertTrue(url.contains("&s="))
    }

    private func client() -> HelperClient {
        var c = ServerConfig(); c.url = "http://nas.local:4533"; c.username = "mason"; c.password = "pw"
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubProtocol.self]
        return HelperClient(config: c, address: "", session: URLSession(configuration: cfg))
    }

    func testStartImportSendsJSON() async throws {
        StubProtocol.handler = { _ in (200, "application/json", Data(self.jobJSON.utf8)) }
        let j = try await client().start(source: "https://open.spotify.com/playlist/x", name: "")
        XCTAssertEqual(j.id, "a1b2c3")
        let req = StubProtocol.lastRequest!
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.url?.path, "/helper/import")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    func testHelperMissingGivesClearMessage() async {
        StubProtocol.handler = { _ in (502, "text/html", Data("<html>Bad Gateway</html>".utf8)) }
        do { _ = try await client().jobs(); XCTFail("should throw") } catch {
            XCTAssertTrue(error.localizedDescription.contains("isn't running"), error.localizedDescription)
        }
    }

    func testHelperErrorMessagePassedThrough() async {
        StubProtocol.handler = { _ in (400, "application/json", Data(#"{"error":"Soulseek isn't set up in the helper."}"#.utf8)) }
        do { _ = try await client().download("a1", method: "song", indexes: [1]); XCTFail("should throw") } catch {
            XCTAssertEqual(error.localizedDescription, "Soulseek isn't set up in the helper.")
        }
    }
}

// MARK: - Layout

@MainActor
final class LayoutTests: XCTestCase {
    /// The blurred cover behind Now Playing must never make the page wider than the screen
    /// (a square cover filling a tall screen is much wider than the screen).
    func testBackdropKeepsScreenSize() {
        let square = UIGraphicsImageRenderer(size: CGSize(width: 160, height: 160)).image { ctx in
            UIColor.red.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 160, height: 160))
        }
        let screen = CGSize(width: 393, height: 852)
        let host = UIHostingController(rootView: NowPlayingBackdrop(image: square))
        let fit = host.sizeThatFits(in: screen)
        metric("layout.backdrop size=\(Int(fit.width))x\(Int(fit.height)) screen=\(Int(screen.width))x\(Int(screen.height))")
        XCTAssertLessThanOrEqual(fit.width, screen.width)
        XCTAssertLessThanOrEqual(fit.height, screen.height)

        // and inside a page laid out like Now Playing, the text column stays on screen
        let page = ZStack {
            NowPlayingBackdrop(image: square)
            VStack { Text("Da Begining").frame(maxWidth: .infinity, alignment: .leading) }.padding(.horizontal, 28)
        }
        let pageFit = UIHostingController(rootView: page).sizeThatFits(in: screen)
        XCTAssertLessThanOrEqual(pageFit.width, screen.width)

        // the old way (image straight in the stack) really did blow the page up: proves this test catches it
        let old = ZStack { Image(uiImage: square).resizable().scaledToFill(); Text("x") }
        let oldFit = UIHostingController(rootView: old).sizeThatFits(in: screen)
        metric("layout.old_backdrop width=\(Int(oldFit.width)) (screen \(Int(screen.width)))")
        XCTAssertGreaterThan(oldFit.width, screen.width)
    }
}

// MARK: - Daily mixes

final class MixerTests: XCTestCase {
    /// A pretend library: 5 genres x 4 artists x 3 albums x 8 songs = 480 songs.
    func library() -> (MixLibrary, [Song]) {
        let genres = ["Memphis Rap", "Alt Rock", "R&B", "Indie", "Jazz"]
        var songs: [Song] = []
        var albums: [Album] = []
        for (gi, g) in genres.enumerated() {
            for ai in 0..<4 {
                let artist = "\(g) Artist \(ai)"
                for al in 0..<3 {
                    let alId = "al-\(gi)-\(ai)-\(al)"
                    albums.append(Album(id: alId, name: "Album \(al)", artist: artist, artistId: "ar-\(gi)-\(ai)", coverArt: alId, genre: g))
                    for t in 0..<8 {
                        var s = Song(id: "s-\(gi)-\(ai)-\(al)-\(t)", title: "Song \(t)", album: "Album \(al)", artist: artist,
                                     albumId: alId, genre: g, coverArt: alId, duration: 200)
                        s.playCount = (gi == 0 ? 12 : gi == 1 ? 6 : 1) - (ai == 3 ? 1 : 0)
                        songs.append(s)
                    }
                }
            }
        }
        var lib = MixLibrary()
        // most played: Memphis Rap, then Alt Rock, then R&B
        lib.frequent = albums.filter { $0.genre == "Memphis Rap" } + albums.filter { $0.genre == "Alt Rock" } + Array(albums.filter { $0.genre == "R&B" }.prefix(3))
        lib.recent = Array(albums.filter { $0.genre == "Indie" }.prefix(4))
        lib.sample = songs
        lib.starred = Array(songs.filter { $0.genre == "Jazz" }.prefix(6))
        lib.fresh = songs.filter { $0.albumId?.hasSuffix("-2") == true && $0.genre == "Indie" }.map { var s = $0; s.playCount = 0; return s }
        for g in genres { lib.pools["genre:" + g] = songs.filter { $0.genre == g } }
        return (lib, songs)
    }

    let today: Date = { var c = DateComponents(); c.year = 2026; c.month = 10; c.day = 26; c.hour = 21; return Calendar.current.date(from: c)! }()

    func testPlansMixesAroundYourTopGenres() {
        let (lib, _) = library()
        let plan = Mixer.plan(lib, [], now: today)
        XCTAssertEqual(plan.dailies.count, 4)
        XCTAssertEqual(plan.dailies.first?.genre, "Memphis Rap", "your most played genre comes first")
        XCTAssertEqual(Set(plan.dailies.compactMap(\.genre)).count, 4, "four different genres")
        XCTAssertTrue(plan.dailies.allSatisfy { !$0.seeds.isEmpty && $0.seeds.count <= 3 })
    }

    func testDailyMixesAreGoodPlaylists() {
        let (lib, _) = library()
        let mixes = Mixer.build(lib, history: [], now: today)
        let dailies = mixes.filter { $0.kind == .daily }
        XCTAssertEqual(dailies.map(\.title), ["Daily Mix 1", "Daily Mix 2", "Daily Mix 3", "Daily Mix 4"])
        for m in dailies {
            XCTAssertEqual(m.songs.count, Mixer.size, m.title)
            XCTAssertEqual(Set(m.songs.map(\.id)).count, m.songs.count, "\(m.title) has no repeats")
            let perArtist = Dictionary(grouping: m.songs, by: { $0.artist ?? "" }).values.map(\.count).max() ?? 0
            XCTAssertLessThanOrEqual(perArtist, 9, "\(m.title): no artist takes over (4 artists in the genre -> about 8 each)")
            XCTAssertGreaterThanOrEqual(Set(m.songs.map { $0.artist ?? "" }).count, 4, "\(m.title): every artist of the genre shows up")
            let perAlbum = Dictionary(grouping: m.songs, by: { $0.albumId ?? "" }).values.map(\.count).max() ?? 0
            XCTAssertLessThanOrEqual(perAlbum, 4, "\(m.title): no album takes over")
            for (a, b) in zip(m.songs, m.songs.dropFirst()) where a.artist == b.artist {
                // only allowed when nothing else was left to put between them
                XCTAssertTrue(m.songs.suffix(3).contains(b), "\(m.title): same artist twice in a row early on")
            }
            XCTAssertEqual(m.covers.count, 4)
            XCTAssertFalse(m.subtitle.isEmpty)
        }
        let first = dailies[0].songs.filter { $0.genre == "Memphis Rap" }.count
        XCTAssertGreaterThan(first, 20, "Daily Mix 1 sticks to its genre")
        metric("mixes.daily1 genre_share=\(first)/\(Mixer.size) subtitle=\(dailies[0].subtitle)")
    }

    func testSameAllDayNewTomorrow() {
        let (lib, _) = library()
        let a = Mixer.build(lib, history: [], now: today)
        let b = Mixer.build(lib, history: [], now: today.addingTimeInterval(60 * 30))
        XCTAssertEqual(a.first?.songs.map(\.id), b.first?.songs.map(\.id), "same mixes later the same day")
        let c = Mixer.build(lib, history: [], now: today.addingTimeInterval(86400))
        XCTAssertNotEqual(a.first?.songs.map(\.id), c.first?.songs.map(\.id), "new mixes tomorrow")
    }

    func testRecentPlaysAndSkipsGetPushedBack() {
        let (lib, songs) = library()
        let base = Mixer.build(lib, history: [], now: today).first!
        // pretend you played (and skipped) every song of Daily Mix 1 yesterday, twice
        var hist: [PlayRecord] = []
        for round in 0..<2 {
            for s in base.songs {
                hist.append(PlayRecord(id: s.id, title: s.title, artist: s.artist!, album: s.album!, albumId: s.albumId,
                                       coverArt: s.coverArt, duration: 200, at: today.addingTimeInterval(-86400 + Double(round * 60)), listened: 5))
            }
        }
        let after = Mixer.build(lib, history: hist, now: today).first { $0.kind == .daily }!
        let overlap = Set(after.songs.map(\.id)).intersection(base.songs.map(\.id)).count
        XCTAssertLessThan(overlap, 8, "songs you just skipped mostly stay out (\(overlap) repeats)")
        XCTAssertEqual(songs.count, 480)
    }

    func testTimeOfDayMixLearnsYourNights() {
        let (lib, songs) = library()
        let jazz = songs.filter { $0.genre == "Jazz" }
        var hist: [PlayRecord] = []
        for d in 1...10 {
            for (i, s) in jazz.prefix(4).enumerated() {
                let night = Calendar.current.date(bySettingHour: 23, minute: i * 5, second: 0, of: today.addingTimeInterval(-Double(d) * 86400))!
                hist.append(PlayRecord(id: s.id, title: s.title, artist: s.artist!, album: s.album!, albumId: s.albumId,
                                       coverArt: s.coverArt, duration: 200, at: night, listened: 200))
            }
        }
        let lateNight = Calendar.current.date(bySettingHour: 23, minute: 30, second: 0, of: today)!
        let mix = Mixer.build(lib, history: hist, now: lateNight).first { $0.kind == .timeOfDay }!
        XCTAssertEqual(mix.title, "Late Night Mix")
        XCTAssertEqual(mix.subtitle, "What you play around this time")
        let jazzShare = mix.songs.filter { $0.genre == "Jazz" }.count
        XCTAssertGreaterThan(jazzShare, mix.songs.count / 2, "late night = what you play late at night (\(jazzShare)/\(mix.songs.count))")
        let morning = Calendar.current.date(bySettingHour: 8, minute: 0, second: 0, of: today)!
        XCTAssertEqual(Mixer.build(lib, history: hist, now: morning).first { $0.kind == .timeOfDay }?.title, "Morning Mix")
    }

    func testRediscoverFreshAndOnThisDay() {
        var (lib, songs) = library()
        let oldDate = ISO8601DateFormatter().string(from: today.addingTimeInterval(-120 * 86400))
        let yesterday = ISO8601DateFormatter().string(from: today.addingTimeInterval(-86400))
        for i in lib.sample.indices { lib.sample[i].played = lib.sample[i].genre == "Alt Rock" ? oldDate : yesterday }
        lib.starred = lib.starred.map { var s = $0; s.played = yesterday; return s }
        let lastYear = Calendar.current.date(byAdding: .year, value: -1, to: today)!
        let hist = songs.prefix(6).map { s in
            PlayRecord(id: s.id, title: s.title, artist: s.artist!, album: s.album!, albumId: s.albumId,
                       coverArt: s.coverArt, duration: 200, at: lastYear, listened: 200)
        }
        let mixes = Mixer.build(lib, history: Array(hist), now: today)
        let re = mixes.first { $0.kind == .rediscover }
        XCTAssertNotNil(re)
        XCTAssertTrue(re!.songs.allSatisfy { $0.genre == "Alt Rock" }, "only old favorites you haven't played lately")
        let fresh = mixes.first { $0.kind == .fresh }
        XCTAssertNotNil(fresh)
        XCTAssertTrue(fresh!.songs.allSatisfy { $0.playCount == 0 })
        let otd = mixes.first { $0.kind == .onThisDay }
        XCTAssertEqual(otd?.songs.count, 6)
        XCTAssertTrue(otd?.subtitle.contains("2025") == true, otd?.subtitle ?? "")
        // no history from last year = no On This Day card
        XCTAssertNil(Mixer.build(lib, history: [], now: today).first { $0.kind == .onThisDay })
    }

    func testLibraryWithoutGenresStillGetsMixes() {
        var (lib, _) = library()
        lib.frequent = lib.frequent.map { var a = $0; a.genre = nil; return a }
        lib.recent = lib.recent.map { var a = $0; a.genre = nil; return a }
        lib.sample = lib.sample.map { var s = $0; s.genre = nil; return s }
        lib.starred = []; lib.fresh = []
        lib.pools = [:]
        let plan = Mixer.plan(lib, [], now: today)
        XCTAssertGreaterThanOrEqual(plan.dailies.count, 3)
        XCTAssertTrue(plan.dailies.allSatisfy { $0.genre == nil && !$0.seeds.isEmpty })
        for d in plan.dailies { for a in d.seeds { lib.pools["artist:" + a] = lib.sample.filter { $0.artist == a } } }
        let dailies = Mixer.build(lib, history: [], now: today).filter { $0.kind == .daily }
        XCTAssertGreaterThanOrEqual(dailies.count, 3)
    }

    func testBuildIsFast() {
        let (lib, songs) = library()
        var hist: [PlayRecord] = []
        for i in 0..<5000 {
            let s = songs[i % songs.count]
            hist.append(PlayRecord(id: s.id, title: s.title, artist: s.artist!, album: s.album!, albumId: s.albumId,
                                   coverArt: s.coverArt, duration: 200, at: today.addingTimeInterval(-Double(i) * 3600), listened: 200))
        }
        let t0 = CFAbsoluteTimeGetCurrent()
        _ = Mixer.build(lib, history: hist, now: today)
        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        metric("mixes.build_ms=\(Int(ms)) (480 songs, 5000 plays)")
        XCTAssertLessThan(ms, 1500)
    }

    @MainActor func testHistoryRecordsPlaysAndSkips() {
        let h = PlayHistory(load: false)
        let a = Track(song: Song(id: "a", title: "A", artist: "X", duration: 200))
        let b = Track(song: Song(id: "b", title: "B", artist: "Y", duration: 200))
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        h.started(a, now: t0)
        h.started(a, now: t0.addingTimeInterval(2))     // same song again right away: not a second play
        h.started(b, now: t0.addingTimeInterval(8))     // skipped A after 8 seconds
        XCTAssertEqual(h.records.map(\.id), ["a", "b"])
        XCTAssertEqual(h.records[0].listened, 8)
        XCTAssertTrue(h.records[0].skipped)
    }
}

final class ExtrasTests: XCTestCase {
    func testWeatherSymbols() {
        XCTAssertEqual(WeatherNow.symbol(0, true), "sun.max.fill")
        XCTAssertEqual(WeatherNow.symbol(0, false), "moon.stars.fill")
        XCTAssertEqual(WeatherNow.symbol(63, true), "cloud.rain.fill")
        XCTAssertEqual(WeatherNow.words(95), "Storms")
    }

    func testGreeting() {
        func at(_ h: Int) -> Date { Calendar.current.date(bySettingHour: h, minute: 0, second: 0, of: .now)! }
        XCTAssertEqual(HomeHeader.greeting(at(8)), "Good morning")
        XCTAssertEqual(HomeHeader.greeting(at(14)), "Good afternoon")
        XCTAssertEqual(HomeHeader.greeting(at(20)), "Good evening")
        XCTAssertEqual(HomeHeader.greeting(at(2)), "Up late")
    }

    func testArtistBioCleanup() {
        let html = #"Three 6 Mafia is a hip hop group from Memphis &amp; more. <a href="https://www.last.fm/music/Three+6+Mafia">Read more on Last.fm</a>"#
        XCTAssertEqual(ArtistView.plain(html), "Three 6 Mafia is a hip hop group from Memphis & more.")
    }

    func testBackdropBlurIsCheapAndCached() {
        func cover(_ c: UIColor) -> UIImage {
            UIGraphicsImageRenderer(size: CGSize(width: 160, height: 160)).image { ctx in
                c.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 80, height: 160))
                UIColor.blue.setFill(); ctx.fill(CGRect(x: 80, y: 0, width: 80, height: 160))
            }
        }
        let t00 = CFAbsoluteTimeGetCurrent()
        _ = softBlur(cover(.red))                       // one-time setup (done in the background at launch in the app)
        let setup = (CFAbsoluteTimeGetCurrent() - t00) * 1000
        let img = cover(.orange)
        let t0 = CFAbsoluteTimeGetCurrent()
        let a = softBlur(img)
        let first = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        let t1 = CFAbsoluteTimeGetCurrent()
        let b = softBlur(img)
        let again = (CFAbsoluteTimeGetCurrent() - t1) * 1000
        metric("perf.backdrop_blur setup=\(Int(setup))ms per_song=\(String(format: "%.1f", first))ms cached=\(String(format: "%.3f", again))ms")
        XCTAssertTrue(a === b, "made once per song")
        XCTAssertLessThan(first, 15, "softening a new song's cover is quick")
        XCTAssertLessThan(again, 1)
        XCTAssertEqual(a.size, CGSize(width: 64, height: 64), "small soft image, stretched by the screen")
    }

    @MainActor func testAccentFollowsSetting() {
        let s = AccentStore.shared
        let old = s.choice
        s.choice = .red
        XCTAssertEqual(Theme.accent, AccentStore.Choice.red.color)
        s.choice = .albumArt
        s.albumColor = .yellow
        XCTAssertEqual(Theme.accent, .yellow)
        s.choice = old
    }
}

// MARK: - Chopped & screwed

final class ScrewTests: XCTestCase {
    let sr = 44100.0

    /// A drum loop: kick on 1 and 3, snare on 2 and 4, hats on eighths, a bass note, plus a little noise.
    func beat(bpm: Double, seconds: Double, offset: Double = 0.137, swing: Double = 0, seed: UInt64 = 7) -> [Float] {
        let n = Int(seconds * sr)
        var out = [Float](repeating: 0, count: n)
        let p = 60 / bpm
        var rng = seed
        func noise() -> Float { rng = rng &* 6364136223846793005 &+ 1442695040888963407; return Float(Int64(bitPattern: rng >> 1) % 2000) / 2000 - 0.5 }
        var k = 0
        while true {
            let t0 = offset + Double(k) * p
            if t0 >= seconds { break }
            let isKick = k % 2 == 0
            let start = Int(t0 * sr)
            for i in 0..<Int(0.25 * sr) where start + i < n {
                let t = Double(i) / sr
                if isKick {
                    let f = 55 + 90 * exp(-t * 30)
                    out[start + i] += Float(0.9 * sin(2 * .pi * f * t) * exp(-t * 9))
                } else {
                    out[start + i] += noise() * Float(0.6 * exp(-t * 22)) + Float(0.3 * sin(2 * .pi * 190 * t) * exp(-t * 18))
                }
            }
            for h in 0..<2 {   // hats
                let ht = t0 + Double(h) * p / 2 + (h == 1 ? swing * p / 2 : 0)
                let hs = Int(ht * sr)
                for i in 0..<Int(0.04 * sr) where hs + i < n && hs + i >= 0 { out[hs + i] += noise() * Float(0.18 * exp(-Double(i) / sr * 90)) }
            }
            k += 1
        }
        for i in 0..<n { out[i] += Float(0.12 * sin(2 * .pi * 41.2 * Double(i) / sr)) + noise() * 0.01 }
        return out
    }

    /// Runs audio through a tracker/chopper in 512-sample blocks like the real audio thread does.
    func run(_ x: [Float], amount: ChopAmount, seed: UInt64 = 42, onBlock: ((Chopper, Int) -> Void)? = nil) -> (Chopper, [Float], [Float]) {
        let c = Chopper(sampleRate: sr, seed: seed)
        c.prepare(channels: 2)
        var l = x, r = x
        var i = 0
        while i < x.count {
            let n = min(512, x.count - i)
            l.withUnsafeMutableBufferPointer { lp in
                r.withUnsafeMutableBufferPointer { rp in
                    c.process([(lp.baseAddress! + i, 1), (rp.baseAddress! + i, 1)], frames: n, amount: amount)
                }
            }
            onBlock?(c, i)
            i += n
        }
        return (c, l, r)
    }

    func testFindsTheTempo() {
        for bpm in [72.0, 80, 90, 100, 120] {
            let (c, _, _) = run(beat(bpm: bpm, seconds: 14), amount: .off)
            let got = c.tracker.bpm
            metric("screw.tempo true=\(Int(bpm)) found=\(String(format: "%.2f", got)) confidence=\(String(format: "%.2f", c.tracker.confidence))")
            XCTAssertEqual(got, bpm, accuracy: bpm * 0.015, "tempo at \(bpm) BPM")
            XCTAssertGreaterThan(c.tracker.confidence, 0.25)
        }
        // fast songs may be counted in half time, which is still on the beat
        let (fast, _, _) = run(beat(bpm: 150, seconds: 14), amount: .off)
        let ratio = fast.tracker.bpm / 150
        XCTAssertTrue(abs(ratio - 1) < 0.015 || abs(ratio - 0.5) < 0.015, "150 BPM -> \(fast.tracker.bpm)")
    }

    func testFindsWhereTheBeatsAre() {
        for (bpm, offset) in [(90.0, 0.137), (75.0, 0.42), (110.0, 0.05)] {
            let (c, _, _) = run(beat(bpm: bpm, seconds: 14, offset: offset), amount: .off)
            let p = 60 / bpm * sr
            guard let next = c.tracker.nextBeat(atOrAfter: 12 * sr) else { return XCTFail("no beat") }
            var err = (next - offset * sr).truncatingRemainder(dividingBy: p)
            if err > p / 2 { err -= p }
            if err < -p / 2 { err += p }
            let ms = abs(err) / sr * 1000
            metric("screw.beat_phase bpm=\(Int(bpm)) error=\(String(format: "%.1f", ms))ms")
            XCTAssertLessThan(ms, 15, "beats land within 15 ms at \(bpm) BPM")
        }
    }

    func testChopsLandOnTheBeatAndRepeatIt() {
        let bpm = 84.0, offset = 0.21
        let x = beat(bpm: bpm, seconds: 60, offset: offset)
        let (c, l, _) = run(x, amount: .heavy)
        let p = 60 / bpm * sr
        XCTAssertGreaterThanOrEqual(c.count, 15, "heavy chops happen a lot, so you actually hear them (\(c.count) in a minute)")
        var worst = 0.0
        for chop in c.history {
            for cut in chop.cuts {
                var err = (cut.at - offset * sr).truncatingRemainder(dividingBy: p / 2)
                if err > p / 4 { err -= p / 2 }
                if err < -p / 4 { err += p / 2 }
                worst = max(worst, abs(err) / sr * 1000)
                let beats = cut.delay / p
                XCTAssertEqual(beats * 2, (beats * 2).rounded(), accuracy: 0.03, "cuts go back whole or half beats")
                // in the middle of each cut you hear exactly what played one delay earlier
                let mid = Int(cut.at + cut.length / 2)
                let d = Int(cut.delay.rounded())
                for i in stride(from: mid - 150, to: mid + 150, by: 7) {
                    XCTAssertEqual(l[i], x[i - d], accuracy: 1e-6, "repeat is the real earlier audio")
                }
            }
            // and it comes back to the song right after
            let after = Int(chop.start + chop.length) + 600
            if after < x.count { XCTAssertEqual(l[after], x[after], accuracy: 1e-6) }
        }
        let kinds = Set(c.history.map(\.move))
        metric("screw.chops count=\(c.count)/min kinds=\(kinds.count) worst_offbeat=\(String(format: "%.1f", worst))ms")
        XCTAssertGreaterThanOrEqual(kinds.count, 4, "a mix of moves, not the same one over and over")
        XCTAssertLessThan(worst, 15, "every cut lands within 15 ms of the beat grid")
        let first = c.history.first.map { $0.start / sr } ?? 0
        XCTAssertGreaterThan(first, 4, "no chops until the beat is found")
        let (light, _, _) = run(x, amount: .light)
        metric("screw.chops light=\(light.count)/min")
        XCTAssertGreaterThanOrEqual(light.count, 6, "light still chops every few bars")
        XCTAssertLessThan(light.count, c.count)
    }

    /// Memphis / trap: long sliding 808s that blur the kick, rolling hats, snare on 3 (half-time feel).
    func testFindsTheBeatUnder808s() {
        let bpm = 70.0, seconds = 30.0, n = Int(seconds * sr), p = 60 / bpm
        var x = [Float](repeating: 0, count: n)
        var rng: UInt64 = 99
        func noise() -> Float { rng = rng &* 6364136223846793005 &+ 1442695040888963407; return Float(Int64(bitPattern: rng >> 1) % 2000) / 2000 - 0.5 }
        var k = 0
        while 0.3 + Double(k) * p < seconds {
            let t0 = 0.3 + Double(k) * p, st = Int(t0 * sr)
            if k % 2 == 0 {
                let f0 = [43.6, 49, 36.7, 41.2][(k / 2) % 4]
                for i in 0..<Int(1.5 * p * sr) where st + i < n {
                    let t = Double(i) / sr
                    x[st + i] += Float(0.85 * sin(2 * .pi * (f0 * (1 + 0.6 * exp(-t * 18))) * t) * exp(-t * 1.4))
                }
            }
            if k % 4 == 2 { for i in 0..<Int(0.2 * sr) where st + i < n { x[st + i] += noise() * Float(0.5 * exp(-Double(i) / sr * 18)) } }
            let rolls = k % 8 == 7 ? 8 : 4
            for h in 0..<rolls {
                let hs = Int((t0 + Double(h) * p / Double(rolls)) * sr)
                for i in 0..<Int(0.025 * sr) where hs + i < n { x[hs + i] += noise() * Float(0.12 * exp(-Double(i) / sr * 140)) }
            }
            k += 1
        }
        let (c, _, _) = run(x, amount: .heavy)
        let ratio = c.tracker.bpm / bpm
        metric("screw.808 found=\(String(format: "%.1f", c.tracker.bpm)) confidence=\(String(format: "%.2f", c.tracker.confidence)) chops=\(c.count)")
        XCTAssertTrue([1.0, 0.5, 2.0].contains { abs(ratio - $0) < 0.02 }, "70 BPM 808 song -> \(c.tracker.bpm)")
        XCTAssertGreaterThan(c.count, 3, "it chops 808-heavy songs too")
        for chop in c.history {
            var err = (chop.start / sr - 0.3).truncatingRemainder(dividingBy: p)
            if err > p / 2 { err -= p }
            XCTAssertLessThan(abs(err) * 1000, 20, "on the beat")
        }
    }

    func testCutsDontClick() {
        let x = beat(bpm: 90, seconds: 40)
        let (c, l, _) = run(x, amount: .heavy, seed: 9)
        var inputMax: Float = 0
        for i in 1..<x.count { inputMax = max(inputMax, abs(x[i] - x[i - 1])) }
        var cutMax: Float = 0
        for chop in c.history {
            for edge in chop.cuts.map({ Int($0.at) }) + [Int(chop.start + chop.length)] {
                for i in (edge - 400)..<(edge + 400) where i > 0 && i < l.count { cutMax = max(cutMax, abs(l[i] - l[i - 1])) }
            }
        }
        metric("screw.click jump_at_cuts=\(String(format: "%.3f", cutMax)) normal_max=\(String(format: "%.3f", inputMax))")
        XCTAssertFalse(c.history.isEmpty)
        XCTAssertLessThanOrEqual(cutMax, inputMax * 1.2, "no jump at a cut bigger than the music makes by itself")
    }

    func testOffLeavesTheSongAlone() {
        let x = beat(bpm: 90, seconds: 20)
        let (c, l, r) = run(x, amount: .off)
        XCTAssertTrue(c.history.isEmpty)
        XCTAssertEqual(l, x)
        XCTAssertEqual(r, x)
    }

    func testScrubbingStartsOver() {
        let x = beat(bpm: 90, seconds: 30)
        var before = 0
        let (c, _, _) = run(x, amount: .heavy) { c, i in
            if i == 512 * 1200 { before = c.history.count; c.reset() }     // a jump around 14 s
        }
        XCTAssertGreaterThan(before, 0, "it was chopping before the jump")
        // counting starts over at the jump: nothing in the first 4 seconds after it, then it finds the beat again
        XCTAssertTrue(c.history.allSatisfy { $0.start > 4 * sr }, "no chops right after a jump")
        XCTAssertGreaterThan(c.history.count, 0, "chops come back once the beat is found again")
    }

    func testNoBeatNoLock() {
        let n = Int(30 * sr)
        var rng: UInt64 = 3
        func noise() -> Float { rng = rng &* 6364136223846793005 &+ 1442695040888963407; return Float(Int64(bitPattern: rng >> 1) % 2000) / 2000 - 0.5 }
        let hiss = (0..<n).map { _ in noise() * 0.3 }
        var chord = [Float](repeating: 0, count: n)
        let w = 2 * Double.pi
        for i in 0..<n {
            let t = Double(i) / sr
            let tones: Double = sin(w * 220 * t) + sin(w * 277 * t) + sin(w * 330 * t)
            let swell: Double = 0.7 + 0.3 * sin(t * 0.5)
            chord[i] = Float(0.2 * tones * swell)
        }
        for (name, x) in [("noise", hiss), ("held chord", chord)] {
            var maxConf = 0.0
            let (c, _, _) = run(x, amount: .heavy) { c, i in if i > Int(4 * self.sr) { maxConf = max(maxConf, c.tracker.confidence) } }
            metric("screw.nobeat \(name) max_confidence=\(String(format: "%.2f", maxConf)) chops=\(c.count)")
            XCTAssertLessThan(maxConf, 0.15, "\(name) has no beat, so it never locks")
            XCTAssertEqual(c.count, 0)
        }
    }

    func testTempoAt48kHz() {
        // iPhones usually run at 48 kHz, where 120 BPM falls between two analysis steps
        let rate = 48000.0, n = Int(20 * rate)
        var x = [Float](repeating: 0, count: n)
        var rng: UInt64 = 11
        for i in 0..<n {
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            let r = Float(Int64(bitPattern: rng >> 1) % 2000) / 2000 - 0.5
            let t = Double(i) / rate, beat = (t * 2).truncatingRemainder(dividingBy: 1)
            let tone: Double = 0.25 * sin(2 * Double.pi * 130.8 * t)
            let kick: Double = 0.35 * sin(2 * Double.pi * 55 * t) * exp(-beat * 9)
            let hatEnv: Double = 0.08 * exp(-(t * 4).truncatingRemainder(dividingBy: 1) * 20)
            x[i] = Float(tone + kick) + r * Float(hatEnv)
        }
        let t = BeatTracker(sampleRate: rate)
        x.withUnsafeBufferPointer { p in var i = 0; while i < n { t.feed(p.baseAddress! + i, count: min(512, n - i)); i += 512 } }
        metric("screw.48k found=\(String(format: "%.1f", t.bpm)) confidence=\(String(format: "%.2f", t.confidence))")
        XCTAssertEqual(t.bpm, 120, accuracy: 2)
        XCTAssertGreaterThan(t.confidence, 0.15)
    }

    // MARK: live chops

    func testLiveNeverChopsOnItsOwnAndWaitsForTheBeat() {
        let x = beat(bpm: 84, seconds: 20, offset: 0.21)
        var early = true
        let (c, l, _) = run(x, amount: .live) { c, i in if i == 512 * 80 { early = c.trigger(.repeatBeat) } }   // ~0.9 s in
        XCTAssertFalse(early, "a tap before the beat is found does nothing")
        XCTAssertTrue(c.history.isEmpty, "live never chops by itself")
        XCTAssertEqual(l, x)
    }

    func testLiveTapsCutBackRightAwayAndInTime() {
        let bpm = 84.0, x = beat(bpm: bpm, seconds: 40, offset: 0.21), p = 60 / bpm * sr
        let moves: [ChopMove] = [.repeatBeat, .stutter, .runBack, .doubleUp, .backItUp]
        var tapped: [Int] = [], ok: [Bool] = []
        let tapBlocks = moves.indices.map { Int((8 + Double($0) * 4.37) * sr) / 512 }
        let (c, l, _) = run(x, amount: .live) { c, i in
            if let k = tapBlocks.firstIndex(of: i / 512) { tapped.append(i + 512); ok.append(c.trigger(moves[k])) }
        }
        XCTAssertEqual(ok, Array(repeating: true, count: moves.count))
        XCTAssertEqual(c.history.count, moves.count)
        var worstWait = 0.0
        for (k, chop) in c.history.enumerated() {
            worstWait = max(worstWait, (chop.start - Double(tapped[k])) / sr * 1000)
            for cut in chop.cuts {
                let beats = cut.delay / p
                XCTAssertEqual(beats * 2, (beats * 2).rounded(), accuracy: 0.03, "goes back whole or half beats")
                let mid = Int(cut.at + cut.length / 2), d = Int(cut.delay.rounded())
                for i in stride(from: mid - 100, to: mid + 100, by: 7) { XCTAssertEqual(l[i], x[i - d], accuracy: 1e-6) }
            }
            let after = Int(chop.start + chop.length) + 600
            XCTAssertEqual(l[after], x[after], accuracy: 1e-6, "back to the song after")
        }
        metric("screw.live tap_to_cut_worst=\(Int(worstWait))ms")
        XCTAssertLessThanOrEqual(worstWait, 125, "starts right away, or on a beat that's about to land")
    }

    func testLiveTapsDuringAChopChainAndHoldLoops() {
        let bpm = 84.0, x = beat(bpm: bpm, seconds: 30, offset: 0.21), p = 60 / bpm * sr
        let (c, _, _) = run(x, amount: .live) { c, i in
            if i == 512 * 860 { c.trigger(.stutter) }          // ~10 s
            if i == 512 * 878 { c.trigger(.repeatBeat) }       // during the stutter
        }
        XCTAssertEqual(c.history.count, 1)
        XCTAssertEqual(c.history.first?.cuts.count, 4, "the tap lined up right after the stutter")

        let (h, l, _) = run(x, amount: .live) { c, i in
            if i == 512 * 1034 { c.trigger(.loop, hold: true) }   // ~12 s
            if i == 512 * 1292 { c.release() }                    // held ~3 s
        }
        guard let loop = h.history.first else { return XCTFail("no loop") }
        let passes = loop.cuts.count
        metric("screw.live loop_passes=\(passes) in 3s")
        XCTAssertGreaterThanOrEqual(passes, Int(3 * sr / p))
        XCTAssertLessThanOrEqual(passes, Int((3 * sr / p).rounded(.up)) + 2)
        let src = loop.cuts[0].at - loop.cuts[0].delay
        for cut in loop.cuts {
            XCTAssertEqual(cut.at - cut.delay, src, accuracy: 2, "every pass is the same beat")
            let mid = Int(cut.at + cut.length / 2)
            XCTAssertEqual(l[mid], x[mid - Int(cut.delay.rounded())], accuracy: 1e-6)
        }
        let (q, _, _) = run(x, amount: .live) { c, i in
            if i == 512 * 1034 { c.trigger(.loop, hold: true) }
            if i == 512 * 1038 { c.release() }
        }
        XCTAssertEqual(q.history.first?.cuts.count, 1, "a quick tap on Repeat is one repeat")
    }

    func testLiveTapsGoThroughTheSharedSettings() {
        let s = ScrewSettings()
        s.tap(.loop, hold: true)
        s.release()
        let t = s.takeTaps()
        XCTAssertEqual(t.move, .loop); XCTAssertTrue(t.hold); XCTAssertTrue(t.release)
        let again = s.takeTaps()
        XCTAssertNil(again.move); XCTAssertFalse(again.release, "each tap is picked up once")
    }

    func testFastEnoughForTheAudioThread() {
        let x = beat(bpm: 90, seconds: 60)
        let t0 = CFAbsoluteTimeGetCurrent()
        _ = run(x, amount: .heavy)
        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        metric("screw.cpu 60s_stereo=\(Int(ms))ms realtime_x=\(Int(60000 / ms))")
        // tests run as an unoptimized debug build; the real app is several times faster still
        XCTAssertLessThan(ms, 6000, "at least 10x faster than real time even unoptimized")
    }

    @MainActor func testSpeedSettings() {
        let p = Player()
        p.setScrew(speed: .screwed, chops: .light)
        XCTAssertEqual(ScrewSettings.shared.speed.rate, 0.80)
        XCTAssertEqual(ScrewSheet.label(.screwed, .light), "Screwed & Chopped")
        XCTAssertEqual(ScrewSheet.label(.slowed, .off), "Slowed")
        XCTAssertEqual(ScrewSheet.label(.off, .heavy), "Chopped")
        p.setScrew(speed: .off, chops: .off)
        XCTAssertFalse(ScrewSettings.shared.isOn)
    }
}
