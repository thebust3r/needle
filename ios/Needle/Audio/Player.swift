import AVFoundation
import MediaPlayer
import Observation
import SwiftUI
import UIKit

@Observable @MainActor
final class Player {
    enum Repeat { case off, all, one }

    private(set) var queue: [Track] = []
    private(set) var index = 0
    private(set) var isPlaying = false
    private(set) var isBuffering = false
    private(set) var duration: Double = 0
    private(set) var repeatMode: Repeat = .off
    private(set) var shuffled = false
    var currentTime: Double = 0
    var errorMessage: String?

    var current: Track? { queue[safe: index] }
    var upNext: [Track] { index + 1 < queue.count ? Array(queue[(index + 1)...]) : [] }
    var progress: Double { duration > 0 ? min(1, currentTime / duration) : 0 }

    // wiring, set up by AppModel
    @ObservationIgnored var client: () -> SubsonicClient = { SubsonicClient(config: ServerConfig()) }
    @ObservationIgnored var quality: () -> StreamQuality = { .original }
    @ObservationIgnored var localFile: (Track) -> URL? = { _ in nil }

    @ObservationIgnored private let av = AVQueuePlayer()
    @ObservationIgnored private var originalQueue: [Track] = []
    @ObservationIgnored private var preloaded: (item: AVPlayerItem, index: Int)?
    @ObservationIgnored private var loadToken = 0
    @ObservationIgnored private var preloadToken = 0
    @ObservationIgnored private var seeking = false
    @ObservationIgnored private var scrobbledCurrent = false
    @ObservationIgnored private var kvo: [NSKeyValueObservation] = []
    @ObservationIgnored private var itemKVO: NSKeyValueObservation?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var nowPlayingArt: MPMediaItemArtwork?

    init() {
        av.actionAtItemEnd = .advance
        av.automaticallyWaitsToMinimizeStalling = true
        timeObserver = av.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { [weak self] t in
            MainActor.assumeIsolated { self?.tick(t.seconds) }
        }
        kvo.append(av.observe(\.currentItem, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.currentItemChanged() }
        })
        kvo.append(av.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
            let status = p.timeControlStatus
            Task { @MainActor in
                guard let self else { return }
                self.isBuffering = status == .waitingToPlayAtSpecifiedRate
                if status == .playing { self.isPlaying = true }
                if status == .paused, !self.seeking, self.av.currentItem != nil { self.isPlaying = false }
                self.updateNowPlayingTime()
            }
        })
        NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated { self?.itemEnded(note.object as? AVPlayerItem) }
        }
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated { self?.interrupted(note) }
        }
        setupRemoteCommands()
    }

    // MARK: - Starting music

    func play(_ tracks: [Track], startAt start: Int = 0, shuffle: Bool = false) {
        guard !tracks.isEmpty else { return }
        originalQueue = tracks
        if shuffle {
            var rest = tracks
            let first = rest.remove(at: shuffle && start == 0 ? Int.random(in: 0..<rest.count) : start)
            queue = [first] + rest.shuffled()
            index = 0
        } else {
            queue = tracks
            index = min(max(0, start), tracks.count - 1)
        }
        shuffled = shuffle
        startCurrent(autoplay: true)
    }

    func playNext(_ tracks: [Track]) {
        guard !queue.isEmpty else { return play(tracks) }
        queue.insert(contentsOf: tracks, at: index + 1)
        originalQueue.append(contentsOf: tracks)
        refreshPreload()
    }

    func addToQueue(_ tracks: [Track]) {
        guard !queue.isEmpty else { return play(tracks) }
        queue.append(contentsOf: tracks)
        originalQueue.append(contentsOf: tracks)
        refreshPreload()
    }

    func jump(toUpNext offset: Int) {
        let target = index + 1 + offset
        guard queue.indices.contains(target) else { return }
        index = target
        startCurrent(autoplay: true)
    }

    func removeUpNext(at offsets: IndexSet) {
        let absolute = IndexSet(offsets.map { $0 + index + 1 })
        for i in absolute.sorted(by: >) where queue.indices.contains(i) { queue.remove(at: i) }
        refreshPreload()
    }

    func moveUpNext(from: IndexSet, to: Int) {
        var up = upNext
        up.move(fromOffsets: from, toOffset: to)
        queue = Array(queue[...index]) + up
        refreshPreload()
    }

    // MARK: - Controls

    func togglePlay() { isPlaying ? pause() : resume() }

    func resume() {
        guard current != nil else { return }
        if av.currentItem == nil {
            startCurrent(autoplay: true, at: currentTime >= duration - 1 ? 0 : currentTime)
            return
        }
        activateSession()
        av.play()
        isPlaying = true
        updateNowPlayingTime()
    }

    func pause() {
        av.pause()
        isPlaying = false
        updateNowPlayingTime()
    }

    func next() {
        guard let ni = nextIndex(wrap: true) else { return }
        if let p = preloaded, p.index == ni, av.items().count > 1 {
            av.advanceToNextItem()          // already buffered: instant
        } else {
            index = ni
            startCurrent(autoplay: true)
        }
    }

    func previous() {
        if currentTime > 3 || index == 0 {
            seek(to: 0)
        } else {
            index -= 1
            startCurrent(autoplay: true)
        }
    }

    func seek(to seconds: Double) {
        let s = max(0, min(seconds, max(duration - 0.5, 0)))
        currentTime = s
        guard av.currentItem != nil else { return }
        seeking = true
        av.seek(to: CMTime(seconds: s, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                self?.seeking = false
                self?.updateNowPlayingTime()
            }
        }
    }

    func toggleShuffle() {
        guard let cur = current else { shuffled.toggle(); return }
        if shuffled {
            queue = originalQueue
            index = originalQueue.firstIndex(of: cur) ?? 0
        } else {
            originalQueue = queue
            var rest = queue
            rest.remove(at: index)
            queue = [cur] + rest.shuffled()
            index = 0
        }
        shuffled.toggle()
        refreshPreload()
    }

    func cycleRepeat() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
        av.actionAtItemEnd = repeatMode == .one ? .pause : .advance
        refreshPreload()
    }

    func setStarred(_ on: Bool) {
        guard queue.indices.contains(index), !queue[index].isLocal else { return }
        queue[index].starred = on
        let id = queue[index].id, c = client()
        Task.detached { try? await c.setStarred(id, on) }
    }

    // MARK: - Loading songs into AVPlayer

    private func startCurrent(autoplay: Bool, at seconds: Double = 0) {
        guard let track = current else { return }
        loadToken += 1
        let token = loadToken
        av.removeAllItems()
        preloaded = nil
        itemKVO = nil
        duration = track.duration
        currentTime = seconds
        scrobbledCurrent = false
        isBuffering = true
        if autoplay { isPlaying = true }
        errorMessage = nil
        updateNowPlaying(for: track)

        Task {
            do {
                let item = try await makeItem(for: track)
                guard token == loadToken else { return }
                av.insert(item, after: nil)
                watch(item)
                if seconds > 0 { await av.seek(to: CMTime(seconds: seconds, preferredTimescale: 600)) }
                if autoplay {
                    activateSession()
                    av.play()
                }
                refreshPreload()
            } catch {
                guard token == loadToken else { return }
                failed(track, error)
            }
        }
    }

    private func makeItem(for track: Track) async throws -> AVPlayerItem {
        let url: URL
        var options: [String: Any] = [:]
        if let file = localFile(track) {
            url = file
        } else {
            guard case .remote(let suffix) = track.source else { throw ServerProblem.unreadable }
            let c = client()
            guard let streamURL = c.streamURL(id: track.id, quality: quality(), suffix: suffix).0 else {
                throw ServerProblem.notConfigured
            }
            url = streamURL
            let headers = c.request(for: url).allHTTPHeaderFields ?? [:]
            if !headers.isEmpty { options["AVURLAssetHTTPHeaderFieldsKey"] = headers }
        }
        let asset = AVURLAsset(url: url, options: options)
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 30
        if let audio = try await asset.loadTracks(withMediaType: .audio).first {
            AudioTap.attach(to: item, track: audio)
        }
        return item
    }

    private func nextIndex(wrap: Bool) -> Int? {
        if index + 1 < queue.count { return index + 1 }
        return (repeatMode == .all || (wrap && repeatMode != .off)) && !queue.isEmpty ? 0 : nil
    }

    /// Buffers the next song behind the current one so it starts without a gap.
    private func refreshPreload() {
        preloadToken += 1
        let token = preloadToken
        if let p = preloaded {
            av.remove(p.item)
            preloaded = nil
        }
        guard repeatMode != .one, av.currentItem != nil, let ni = nextIndex(wrap: false) else { return }
        let track = queue[ni]
        Task {
            guard let item = try? await makeItem(for: track), token == preloadToken,
                  let cur = av.currentItem, av.items().count == 1 else { return }
            av.insert(item, after: cur)
            preloaded = (item, ni)
        }
    }

    private func currentItemChanged() {
        guard let item = av.currentItem else { return }
        if let p = preloaded, p.item === item {
            index = p.index
            preloaded = nil
            duration = current?.duration ?? 0
            currentTime = 0
            scrobbledCurrent = false
            watch(item)
            if let t = current { updateNowPlaying(for: t) }
            refreshPreload()
        }
    }

    private func itemEnded(_ item: AVPlayerItem?) {
        guard let item, av.currentItem == nil || av.currentItem === item else { return }
        if repeatMode == .one {
            av.seek(to: .zero)
            av.play()
            scrobbledCurrent = false
            return
        }
        if preloaded == nil && nextIndex(wrap: false) == nil {
            // end of the queue
            isPlaying = false
            currentTime = 0
            av.removeAllItems()
            updateNowPlayingTime()
        }
    }

    private func watch(_ item: AVPlayerItem) {
        itemKVO = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            Task { @MainActor in
                guard let self, let t = self.current else { return }
                self.failed(t, item.error ?? ServerProblem.unreadable)
            }
        }
    }

    private func failed(_ track: Track, _ error: Error) {
        isBuffering = false
        errorMessage = "Couldn't play “\(track.title)”. \(error.localizedDescription)"
        if nextIndex(wrap: false) != nil {
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                if self.current == track { self.next() }
            }
        } else {
            isPlaying = false
        }
    }

    private func tick(_ seconds: Double) {
        guard !seeking, seconds.isFinite else { return }
        currentTime = seconds
        if let d = av.currentItem?.duration.seconds, d.isFinite, d > 0, abs(d - duration) > 1 { duration = d }
        if !scrobbledCurrent, let t = current, !t.isLocal, duration > 0, seconds > min(duration * 0.5, 240) {
            scrobbledCurrent = true
            let c = client()
            Task.detached { await c.scrobble(t.id) }
        }
    }

    private func interrupted(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        if type == .began {
            isPlaying = false
        } else if let o = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt,
                  AVAudioSession.InterruptionOptions(rawValue: o).contains(.shouldResume) {
            resume()
        }
    }

    private func activateSession() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .default, policy: .longFormAudio)
        try? s.setActive(true)
    }

    // MARK: - Lock screen and Control Center

    private func setupRemoteCommands() {
        let cc = MPRemoteCommandCenter.shared()
        cc.playCommand.addTarget { [weak self] _ in self?.resume(); return .success }
        cc.pauseCommand.addTarget { [weak self] _ in self?.pause(); return .success }
        cc.togglePlayPauseCommand.addTarget { [weak self] _ in self?.togglePlay(); return .success }
        cc.nextTrackCommand.addTarget { [weak self] _ in self?.next(); return .success }
        cc.previousTrackCommand.addTarget { [weak self] _ in self?.previous(); return .success }
        cc.changePlaybackPositionCommand.addTarget { [weak self] e in
            guard let e = e as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.seek(to: e.positionTime)
            return .success
        }
    }

    private func updateNowPlaying(for track: Track) {
        nowPlayingArt = nil
        updateNowPlayingTime()
        Task {
            guard let img = await ArtworkStore.shared.image(for: track, size: 900), current == track else { return }
            nowPlayingArt = MPMediaItemArtwork(boundsSize: img.size) { @Sendable _ in img }
            updateNowPlayingTime()
        }
    }

    private func updateNowPlayingTime() {
        guard let t = current else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: t.title,
            MPMediaItemPropertyArtist: t.artist,
            MPMediaItemPropertyAlbumTitle: t.album,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if let art = nowPlayingArt { info[MPMediaItemPropertyArtwork] = art }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
