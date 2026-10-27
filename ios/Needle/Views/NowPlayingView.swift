import AVKit
import MediaPlayer
import SwiftUI

struct NowPlayingView: View {
    @Environment(Player.self) private var player
    @Environment(Equalizer.self) private var eq
    @Environment(\.dismiss) private var dismiss

    @State private var palette = Palette.fallback
    @State private var backdrop: UIImage?
    @State private var showEQ = false
    @State private var showQueue = false
    @State private var artDrag: CGFloat = 0
    @State private var sheetDrag: CGFloat = 0
    @State private var viz = VizSettings.shared
    @State private var showVizFull = false
    @AppStorage("lyrics.on") private var lyricsOn = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        GeometryReader { geo in
            let artSize = min(geo.size.width - 48, geo.size.height * 0.42)
            ZStack {
                background
                VStack(spacing: 0) {
                    topBar
                    Spacer(minLength: 12)
                    if lyricsOn {
                        LyricsView()
                            .frame(maxWidth: .infinity)
                            .frame(height: artSize + 24)
                            .padding(.horizontal, 28)
                            .transition(.opacity)
                    } else {
                        artwork(artSize)
                    }
                    Spacer(minLength: 20)
                    VStack(spacing: 22) {
                        titleRow
                        scrubber
                        controls
                        VolumeSlider().frame(height: 34).padding(.horizontal, 2)
                        bottomRow
                    }
                    .padding(.horizontal, 28)
                    .padding(.bottom, max(geo.safeAreaInsets.bottom, 12))
                }
                .padding(.top, geo.safeAreaInsets.top)
            }
            .ignoresSafeArea()
            .modifier(SwipeDownToClose(drag: $sheetDrag, close: { dismiss() }))
        }
        .foregroundStyle(.white)
        .statusBarHidden(false)
        .sheet(isPresented: $showEQ) {
            EqualizerView(tint: palette.accent)
                .presentationDetents([.large])
                .presentationBackground(.ultraThinMaterial)
        }
        .fullScreenCover(isPresented: $showVizFull) { VizFullScreen() }
        .sheet(isPresented: $showQueue) {
            QueueView()
                .presentationDetents([.medium, .large])
                .presentationBackground(.ultraThinMaterial)
        }
        .task(id: player.current?.artworkKey) {
            guard let t = player.current else { return }
            async let p = ArtworkStore.shared.palette(for: t)
            async let img = ArtworkStore.shared.image(for: t, size: 160)
            let (pp, raw) = await (p, img)
            var ii: UIImage?
            if let raw { ii = await Task.detached(priority: .userInitiated) { softBlur(raw) }.value }
            withAnimation(.easeInOut(duration: 0.8)) {
                palette = pp
                backdrop = ii
            }
            VizSettings.shared.engine.setColor(UIColor(pp.accent))
        }
        .onAppear { EQProcessor.shared.spectrumEnabled = true }
        .onDisappear { if !showEQ { EQProcessor.shared.spectrumEnabled = false } }
    }

    // MARK: pieces

    /// The cover itself, blown up and blurred, drifting slowly, tinted with its own colors.
    private var background: some View {
        ZStack {
            palette.bottom
            if let backdrop {
                NowPlayingBackdrop(image: backdrop, paused: !player.isPlaying || vizShowing)
            }
            LinearGradient(colors: [palette.top.opacity(0.35), .clear, palette.bottom.opacity(0.85), .black.opacity(0.8)],
                           startPoint: .top, endPoint: .bottom)
            SpectrumGlow(color: palette.accent, running: player.isPlaying && !vizShowing && !lyricsOn)
                .frame(height: 220)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .opacity(player.isPlaying && !vizShowing && !lyricsOn ? 0.55 : 0)
                .animation(.easeInOut(duration: 0.6), value: player.isPlaying)
        }
        .ignoresSafeArea()
    }

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.down").font(.title3.weight(.semibold)).frame(width: 44, height: 44)
            }
            Spacer()
            VStack(spacing: 1) {
                Text("Playing from").font(.caption2).foregroundStyle(.white.opacity(0.6))
                Text(player.current?.album ?? "").font(.footnote.weight(.semibold)).lineLimit(1)
            }
            Spacer()
            Menu {
                if let t = player.current { TrackMenu(tracks: [t]) }
            } label: {
                Image(systemName: "ellipsis").font(.title3.weight(.semibold)).frame(width: 44, height: 44)
            }
        }
        .padding(.horizontal, 12)
    }

    private var vizShowing: Bool { viz.on && !lyricsOn }

    /// Album art. Tap it to flip to the visualizer and back; swipe sideways to skip.
    private func artwork(_ size: CGFloat) -> some View {
        ZStack {
            ArtworkView(track: player.current, size: size, corner: 16)
                .opacity(viz.on ? 0 : 1)
                .rotation3DEffect(.degrees(viz.on ? -70 : 0), axis: (x: 0, y: 1, z: 0))
            if viz.on {
                VisualizerView(active: vizShowing && !showVizFull && scenePhase == .active)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(alignment: .bottom) {
                        HStack {
                            Button { viz.cycle() } label: { VizChip(text: viz.label) }
                            Spacer()
                            Button { showVizFull = true } label: {
                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                                    .font(.footnote.weight(.semibold)).frame(width: 34, height: 34)
                                    .background(.black.opacity(0.45), in: Circle())
                            }
                            .accessibilityLabel("Full-screen visualizer")
                        }
                        .padding(10)
                    }
                    .transition(.asymmetric(insertion: .scale(scale: 0.94).combined(with: .opacity), removal: .opacity))
            }
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(player.isPlaying ? 0.55 : 0.3), radius: player.isPlaying ? 36 : 18, y: player.isPlaying ? 20 : 10)
        .scaleEffect(player.isPlaying ? 1 : 0.86)
        .animation(.spring(response: 0.5, dampingFraction: 0.72), value: player.isPlaying)
        .offset(x: artDrag)
        .rotationEffect(.degrees(Double(artDrag) / 40))
        .gesture(DragGesture(minimumDistance: 12)
            .onChanged { v in if abs(v.translation.width) > abs(v.translation.height) { artDrag = v.translation.width } }
            .onEnded { v in
                if v.translation.width < -90 { player.next() } else if v.translation.width > 90 { player.previous() }
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { artDrag = 0 }
            })
        .contentShape(Rectangle())   // the whole square takes taps, even while the art is hidden behind the visualizer
        .onTapGesture { withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { viz.on.toggle() } }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(viz.on ? "Visualizer. Double-tap to show the album art" : "Album art. Double-tap to show the visualizer")
    }

    private var titleRow: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(player.current?.title ?? "Not Playing")
                    .font(Theme.title(22)).lineLimit(1).minimumScaleFactor(0.75)
                Text(player.current?.artist ?? "")
                    .font(.title3).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
            }
            Spacer()
            if let t = player.current, !t.isLocal {
                Button { player.setStarred(!t.starred) } label: {
                    Image(systemName: t.starred ? "heart.fill" : "heart")
                        .font(.title2)
                        .foregroundStyle(t.starred ? palette.accent : .white.opacity(0.8))
                        .symbolEffect(.bounce, value: t.starred)
                        .frame(width: 44, height: 44)
                }
                .sensoryFeedback(t.starred ? .success : .impact(weight: .light), trigger: t.starred)
            }
        }
    }

    private var scrubber: some View { ScrubberView() }

    private var controls: some View {
        HStack {
            Button { player.toggleShuffle() } label: {
                Image(systemName: "shuffle").font(.title3)
                    .foregroundStyle(player.shuffled ? palette.accent : .white.opacity(0.7))
            }
            Spacer()
            Button { player.previous() } label: { Image(systemName: "backward.fill").font(.system(size: 30)) }
                .buttonStyle(PressScale())
                .sensoryFeedback(.impact(weight: .light), trigger: player.current?.id)
            Spacer()
            Button { player.togglePlay() } label: {
                ZStack {
                    Circle().fill(.white).frame(width: 78, height: 78)
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(.black)
                        .offset(x: player.isPlaying ? 0 : 3)
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .buttonStyle(PressScale())
            Spacer()
            Button { player.next() } label: { Image(systemName: "forward.fill").font(.system(size: 30)) }
                .buttonStyle(PressScale())
            Spacer()
            Button { player.cycleRepeat() } label: {
                Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat").font(.title3)
                    .foregroundStyle(player.repeatMode == .off ? .white.opacity(0.7) : palette.accent)
            }
        }
    }

    private var bottomRow: some View {
        HStack {
            Button { showEQ = true } label: {
                HStack(spacing: 6) {
                    Image(systemName: "slider.vertical.3")
                    Text(eq.enabled ? eq.presetName : "EQ Off").font(.footnote.weight(.semibold)).lineLimit(1)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(.white.opacity(eq.enabled ? 0.16 : 0.08), in: Capsule())
            }
            Spacer()
            AirPlayButton().frame(width: 40, height: 40)
            Spacer()
            Button { withAnimation(.easeInOut(duration: 0.3)) { lyricsOn.toggle() } } label: {
                Image(systemName: lyricsOn ? "quote.bubble.fill" : "quote.bubble")
                    .font(.title3).frame(width: 40, height: 40)
                    .background(.white.opacity(lyricsOn ? 0.18 : 0), in: Circle())
            }
            .accessibilityLabel("Lyrics")
            .accessibilityAddTraits(lyricsOn ? .isSelected : [])
            Button { showQueue = true } label: {
                Image(systemName: "list.bullet").font(.title3).frame(width: 40, height: 40)
            }
        }
        .foregroundStyle(.white.opacity(0.9))
    }
}

/// Soft bars of the live spectrum glowing at the bottom of Now Playing.
struct SpectrumGlow: View {
    let color: Color
    var running = true
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !running)) { _ in
            let bins = running ? EQProcessor.shared.spectrum(bins: 48) : [Float](repeating: 0, count: 48)
            Canvas { ctx, size in
                let w = size.width / CGFloat(bins.count)
                for (i, v) in bins.enumerated() where v > 0.01 {
                    let h = CGFloat(v) * size.height
                    let rect = CGRect(x: CGFloat(i) * w + 1, y: size.height - h, width: w - 2, height: h)
                    ctx.fill(Path(roundedRect: rect, cornerRadius: 2),
                             with: .linearGradient(Gradient(colors: [color.opacity(0.0), color.opacity(0.9)]),
                                                   startPoint: CGPoint(x: 0, y: size.height - h), endPoint: CGPoint(x: 0, y: size.height)))
                }
            }
            .blur(radius: 6)
            .drawingGroup()
        }
        .allowsHitTesting(false)
    }
}

struct VolumeSlider: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let v = MPVolumeView(frame: .zero)
        v.tintColor = .white
        return v
    }
    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}

struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.tintColor = UIColor.white.withAlphaComponent(0.9)
        v.activeTintColor = .white
        v.prioritizesVideoDevices = false
        return v
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

/// The blurred, drifting cover behind Now Playing. It's drawn as an overlay on an empty view, so the
/// image (which fills a tall screen by growing much wider than it) can never change the page's size.
struct NowPlayingBackdrop: View {
    let image: UIImage
    var paused = false
    @State private var drift = false

    var body: some View {
        Color.clear
            .overlay {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .scaleEffect(drift ? 1.98 : 1.82)
                    .rotationEffect(.degrees(drift ? 6 : -6))
                    .offset(x: drift ? 30 : -30, y: drift ? 40 : -40)
                    .opacity(0.85)
            }
            .clipped()
            .allowsHitTesting(false)
            .onAppear { setDrift(!paused) }
            .onChange(of: paused) { _, p in setDrift(!p) }
    }

    private func setDrift(_ on: Bool) {
        guard on else { return }   // when paused it simply finishes the current sway
        withAnimation(.easeInOut(duration: 14).repeatForever(autoreverses: true)) { drift.toggle() }
    }

    /// Kept for tests and older callers.
    static func blurred(_ image: UIImage) -> UIImage { softBlur(image) }
}

private let blurCache = NSCache<UIImage, UIImage>()

/// A soft copy of a cover, made once per song: shrunk to 16 pixels, then smoothly scaled back up to 64.
/// Shown stretched across the screen it looks like a big blur, but it costs about a millisecond to make
/// and nothing to draw. Safe to call off the main thread.
func softBlur(_ image: UIImage) -> UIImage {
    if let hit = blurCache.object(forKey: image) { return hit }
    let fmt = UIGraphicsImageRendererFormat()
    fmt.scale = 1
    fmt.opaque = true
    let tiny = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16), format: fmt).image { ctx in
        ctx.cgContext.interpolationQuality = .high
        image.draw(in: CGRect(x: 0, y: 0, width: 16, height: 16))
    }
    let soft = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64), format: fmt).image { ctx in
        ctx.cgContext.interpolationQuality = .high
        tiny.draw(in: CGRect(x: 0, y: 0, width: 64, height: 64))
    }
    blurCache.setObject(soft, forKey: image)
    return soft
}

/// Sets up the blur machinery in the background at launch, so the first Now Playing opens without a hitch.
func warmUpBlur() {
    Task.detached(priority: .utility) {
        let tiny = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { _ in }
        _ = softBlur(tiny)
    }
}

/// The progress bar. It's its own view so only it redraws ten times a second as the song plays,
/// not the whole Now Playing screen.
struct ScrubberView: View {
    @Environment(Player.self) private var player
    @State private var scrubbing: Double?

    var body: some View {
        let shown = scrubbing ?? player.currentTime
        let frac = player.duration > 0 ? min(1, shown / player.duration) : 0
        VStack(spacing: 6) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.2))
                    Capsule().fill(.white).frame(width: g.size.width * frac)
                }
                .frame(height: scrubbing == nil ? 5 : 10)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        withAnimation(.easeOut(duration: 0.15)) {
                            scrubbing = max(0, min(1, v.location.x / g.size.width)) * player.duration
                        }
                    }
                    .onEnded { _ in
                        if let s = scrubbing { player.seek(to: s) }
                        withAnimation(.easeOut(duration: 0.2)) { scrubbing = nil }
                    })
            }
            .frame(height: 22)
            HStack {
                Text(formatTime(shown))
                Spacer()
                if player.isBuffering && player.isPlaying { ProgressView().controlSize(.mini).tint(.white) }
                Spacer()
                Text("-" + formatTime(max(0, player.duration - shown)))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white.opacity(0.6))
        }
        .sensoryFeedback(.selection, trigger: scrubbing == nil)
    }
}

/// Before iOS 18: drag the screen down to close it. On iOS 18 and later the zoom transition
/// already shrinks Now Playing back into the mini player when you swipe down, so we stay out of its way.
struct SwipeDownToClose: ViewModifier {
    @Binding var drag: CGFloat
    let close: () -> Void
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content
        } else {
            content
                .offset(y: max(0, drag))
                .gesture(DragGesture().onChanged { drag = $0.translation.height }
                    .onEnded { v in
                        if v.translation.height > 140 || v.predictedEndTranslation.height > 400 { close() }
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { drag = 0 }
                    })
        }
    }
}
