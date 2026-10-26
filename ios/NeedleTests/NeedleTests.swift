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
        run(e, seconds: 10, make: { self.input($0, bpm: 240) })     // 4 beats a second: tries to flash too often
        let worst = maxPerSecond(e.stats.flashLog)
        metric("viz.max_flashes_per_second=\(worst) (limit 3), beats=\(e.stats.beats), flashes=\(e.stats.flashes)")
        XCTAssertGreaterThan(e.stats.beats, 35, "the test really does beat ~4 times a second")
        XCTAssertLessThanOrEqual(worst, 3)
        XCTAssertLessThan(e.stats.flashes, e.stats.beats, "some flashes were held back")
        XCTAssertGreaterThan(e.stats.flashes, 20)
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
        for size in [360, 440] {
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
                // 440px is the most the phone ever draws (see VizUIView). 60 fps = 16.7 ms per frame:
                // average under half of that, and 95% of frames inside one frame
                XCTAssertLessThan(avg, 8.3, "\(mode.name) at \(size)px: average frame leaves room for 60 fps")
                XCTAssertLessThan(p95, 16.7, "\(mode.name) at \(size)px: 95% of frames fit in one 60 fps frame")
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
