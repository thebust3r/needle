import MetalKit
import Observation
import QuartzCore
import SwiftUI
import UIKit

/// Visualizer settings, remembered between launches, plus the one shared engine.
@Observable @MainActor
final class VizSettings {
    static let shared = VizSettings()

    @ObservationIgnored let engine = VizEngine()

    /// Now Playing always opens on the album art; tap it to flip to the visualizer.
    var on = false
    var mode: VizEngine.Mode {
        didSet {
            engine.mode = mode
            UserDefaults.standard.set(mode.rawValue, forKey: "viz.mode")
        }
    }
    var auto: Bool {
        didSet {
            engine.auto = auto
            UserDefaults.standard.set(auto, forKey: "viz.auto")
        }
    }
    var look: VizLook {
        didSet {
            engine.look = look
            if let d = try? JSONEncoder().encode(look) { UserDefaults.standard.set(d, forKey: "viz.look") }
        }
    }

    var label: String { auto ? "Auto · \(mode.name)" : mode.name }

    init() {
        let d = UserDefaults.standard
        mode = VizEngine.Mode(rawValue: d.integer(forKey: "viz.mode")) ?? .tunnel
        auto = d.object(forKey: "viz.auto") as? Bool ?? true
        look = d.data(forKey: "viz.look").flatMap { try? JSONDecoder().decode(VizLook.self, from: $0) } ?? VizLook()
        engine.mode = mode
        engine.auto = auto
        engine.look = look
        engine.onModeChange = { [weak self] m in
            Task { @MainActor in if self?.mode != m { self?.mode = m } }
        }
    }

    /// Taps cycle: Auto → each style → back to Auto.
    func cycle() {
        if auto {
            auto = false
            mode = .tunnel
        } else if mode == VizEngine.Mode.allCases.last {
            auto = true
        } else {
            mode = VizEngine.Mode(rawValue: mode.rawValue + 1) ?? .tunnel
        }
    }

    func step(_ delta: Int) {
        auto = false
        let all = VizEngine.Mode.allCases
        mode = all[((mode.rawValue + delta) % all.count + all.count) % all.count]
    }
}

/// Shows the visualizer, drawn by the graphics chip at the screen's full resolution.
final class VizUIView: MTKView, MTKViewDelegate {
    var isPlaying: () -> Bool = { false }
    var active = false { didSet { updateRunning() } }

    private let renderer: VizRenderer?
    private let flashLayer = CALayer()
    private var last: CFTimeInterval = 0
    private var quality: CGFloat = 1
    private var slowSince: CFTimeInterval = 0
    private var fastSince: CFTimeInterval = 0
    private var recentDt: [Double] = []

    init() {
        let r = VizRenderer(outputFormat: .bgra8Unorm)
        renderer = r
        super.init(frame: .zero, device: r?.device)
        colorPixelFormat = .bgra8Unorm
        framebufferOnly = true
        isPaused = true
        enableSetNeedsDisplay = false
        preferredFramesPerSecond = 60          // smooth without burning battery on 120 Hz screens
        autoResizeDrawable = true
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        backgroundColor = .black
        delegate = self
        flashLayer.opacity = 0
        flashLayer.compositingFilter = "screenBlendMode"
        layer.addSublayer(flashLayer)
        isUserInteractionEnabled = false
    }

    required init(coder: NSCoder) { fatalError("not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        flashLayer.frame = bounds
        CATransaction.commit()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        quality = 1                             // each time it appears, start sharp
        updateRunning()
    }

    private func updateRunning() {
        let run = active && window != nil && renderer != nil
        isPaused = !run
        if run {
            last = 0
            EQProcessor.shared.spectrumEnabled = true
        } else {
            flashLayer.opacity = 0
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let renderer, let drawable = currentDrawable else { return }
        let engine = VizSettings.shared.engine
        engine.reducedMotion = UIAccessibility.isReduceMotionEnabled
        let now = CACurrentMediaTime()
        let dt = last == 0 ? 1.0 / 60 : now - last
        last = now
        engine.update(time: now, dt: dt, input: EQProcessor.shared.vizInput(playing: isPlaying()))
        let w = Int(drawableSize.width * quality), h = Int(drawableSize.height * quality)
        renderer.draw(engine: engine, width: w, height: h, output: drawable.texture, present: { $0.present(drawable) })

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let o = engine.flash > 0.02 ? engine.flash * 0.18 : 0
        if o > 0 && flashLayer.opacity == 0 { flashLayer.backgroundColor = engine.flashColor() }
        flashLayer.opacity = o
        CATransaction.commit()
        governor(now, dt: dt, gpu: renderer.recentGpuMs().suffix(20))
    }

    /// Keeps it smooth: draws the trails a little smaller if the phone can't keep up (or is hot), back to full when it can.
    private func governor(_ t: CFTimeInterval, dt: Double, gpu: ArraySlice<Double>) {
        recentDt.append(dt); if recentDt.count > 30 { recentDt.removeFirst() }
        let avgDt = recentDt.reduce(0, +) / Double(recentDt.count)
        let avgGpu = gpu.isEmpty ? 0 : gpu.reduce(0, +) / Double(gpu.count)
        let hot = ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
        if avgDt > 0.021 || avgGpu > 12 || hot {
            fastSince = 0
            if slowSince == 0 { slowSince = t }
            if t - slowSince > 1, quality > 0.5 { quality = max(0.5, quality - 0.1); slowSince = t }
        } else if avgDt < 0.0175 && avgGpu < 7 {
            slowSince = 0
            if fastSince == 0 { fastSince = t }
            if t - fastSince > 3, quality < 1 { quality = min(1, quality + 0.1); fastSince = t }
        } else {
            slowSince = 0; fastSince = 0
        }
    }
}

struct VisualizerView: UIViewRepresentable {
    @Environment(Player.self) private var player
    var active: Bool

    func makeUIView(context: Context) -> VizUIView { VizUIView() }

    func updateUIView(_ view: VizUIView, context: Context) {
        let p = player
        view.isPlaying = { MainActor.assumeIsolated { p.isPlaying } }
        view.active = active
    }

    static func dismantleUIView(_ view: VizUIView, coordinator: ()) { view.active = false }
}

/// The small style button shown on the visualizer.
struct VizChip: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.black.opacity(0.45), in: Capsule())
            .background(.ultraThinMaterial.opacity(0.4), in: Capsule())
    }
}

private struct RoundIcon: View {
    let name: String
    var body: some View {
        Image(systemName: name).font(.headline).frame(width: 38, height: 38)
            .background(.black.opacity(0.45), in: Circle())
    }
}

struct VizFullScreen: View {
    @Environment(Player.self) private var player
    @Environment(\.dismiss) private var dismiss
    @State private var viz = VizSettings.shared
    @State private var showControls = true
    @State private var showTip = true
    @State private var customize = false
    @State private var hideTask: Task<Void, Never>?
    @State private var lastDrag: CGPoint?
    @State private var dragDistance: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()
                VisualizerView(active: true).ignoresSafeArea()
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
                        .onChanged { v in
                            wake()
                            let size = geo.size
                            if let l = lastDrag {
                                let d = hypot(v.location.x - l.x, v.location.y - l.y)
                                dragDistance += d
                                viz.engine.drag(to: Float(v.location.x / size.width), Float(v.location.y / size.height), moved: Float(d / size.width))
                            }
                            lastDrag = v.location
                        }
                        .onEnded { v in
                            if dragDistance < 10 {
                                viz.engine.tap(at: Float(v.location.x / geo.size.width), Float(v.location.y / geo.size.height))
                            } else if v.translation.height > 160 && abs(v.translation.width) < 80 {
                                dismiss()                     // a long swipe down closes it
                            }
                            lastDrag = nil
                            dragDistance = 0
                        })
                VStack {
                    HStack(spacing: 10) {
                        Button { dismiss() } label: { RoundIcon(name: "xmark") }
                        Spacer()
                        Button { viz.step(-1); wake() } label: { RoundIcon(name: "chevron.left") }
                        Button { viz.cycle(); wake() } label: { VizChip(text: viz.label) }
                        Button { viz.step(1); wake() } label: { RoundIcon(name: "chevron.right") }
                        Spacer()
                        Button { customize = true } label: { RoundIcon(name: "slider.horizontal.3") }
                    }
                    Spacer()
                    if showTip {
                        Text("Drag to swirl · tap for a burst")
                            .font(.subheadline).foregroundStyle(.white.opacity(0.75))
                            .padding(.bottom, 24)
                            .transition(.opacity)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(player.current?.title ?? "").font(Theme.title(20))
                        Text(player.current?.artist ?? "").foregroundStyle(.white.opacity(0.75))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .shadow(color: .black, radius: 8)
                }
                .padding(20)
                .opacity(showControls ? 1 : 0)
                .animation(.easeInOut(duration: 0.4), value: showControls)
            }
        }
        .foregroundStyle(.white)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .sheet(isPresented: $customize) {
            VizCustomizeSheet()
                .presentationDetents([.fraction(0.55), .large])
                .presentationBackground(.ultraThinMaterial)
                .presentationBackgroundInteraction(.enabled(upThrough: .fraction(0.55)))
        }
        .onAppear {
            wake()
            Task { try? await Task.sleep(for: .seconds(3.5)); withAnimation { showTip = false } }
        }
        .onDisappear { hideTask?.cancel() }
    }

    private func wake() {
        showControls = true
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            if !Task.isCancelled && !customize { showControls = false }
        }
    }
}

/// Styles, colors, reactivity, trails, speed, mirror. Changes show live behind the sheet.
struct VizCustomizeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var viz = VizSettings.shared

    var body: some View {
        @Bindable var viz = viz
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Visualizer").font(Theme.title(22))
                    Spacer()
                    Button("Done") { dismiss() }.fontWeight(.bold)
                }
                header("STYLE")
                FlowChips(items: ["Auto"] + VizEngine.Mode.allCases.map(\.name),
                          selected: viz.auto ? "Auto" : viz.mode.name) { name in
                    if name == "Auto" { viz.auto = true } else if let m = VizEngine.Mode.allCases.first(where: { $0.name == name }) {
                        viz.auto = false; viz.mode = m
                    }
                }
                header("COLORS")
                FlowChips(items: VizTheme.allCases.map(\.name), selected: viz.look.theme.name, swatches: Dictionary(uniqueKeysWithValues: VizTheme.allCases.map { t in
                    (t.name, t.colors.map { $0.map { Color(red: Double($0.x), green: Double($0.y), blue: Double($0.z)) } } ?? [Theme.accent, .pink, .blue])
                })) { name in
                    if let t = VizTheme.allCases.first(where: { $0.name == name }) { viz.look.theme = t }
                }
                slider("Reactivity", value: $viz.look.intensity, range: 0.4...2) { $0 < 0.8 ? "Chill" : $0 < 1.3 ? "Normal" : $0 < 1.7 ? "Hype" : "Max" }
                slider("Trails", value: $viz.look.trails, range: 0...1) { $0 < 0.3 ? "Short" : $0 < 0.75 ? "Medium" : "Long" }
                slider("Speed", value: $viz.look.speed, range: 0.4...2) { $0 < 0.8 ? "Slow" : $0 < 1.3 ? "Normal" : "Fast" }
                Toggle("Kaleidoscope mirror", isOn: $viz.look.mirror).font(.headline).tint(Theme.accent)
                Button("Reset to Defaults") { viz.look = VizLook() }
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.secondary)
                    .padding(.top, 4)
            }
            .padding(20)
        }
        .foregroundStyle(.white)
        .sensoryFeedback(.selection, trigger: "\(viz.mode)\(viz.auto)\(viz.look.theme)\(viz.look.mirror)")
    }

    private func header(_ t: String) -> some View {
        Text(t).font(.caption.weight(.bold)).tracking(1).foregroundStyle(Theme.secondary).padding(.top, 4)
    }

    private func slider(_ title: String, value: Binding<Float>, range: ClosedRange<Float>, words: @escaping (Float) -> String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Text(words(value.wrappedValue)).foregroundStyle(Theme.secondary)
            }
            Slider(value: value, in: range).tint(Theme.accent)
        }
    }
}

/// Wrapping row of pill buttons.
struct FlowChips: View {
    let items: [String]
    let selected: String
    var swatches: [String: [Color]] = [:]
    let pick: (String) -> Void

    var body: some View {
        WrapLayout(spacing: 8) {
            ForEach(items, id: \.self) { item in
                Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { pick(item) } } label: {
                    HStack(spacing: 7) {
                        if let colors = swatches[item] {
                            Capsule().fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)).frame(width: 22, height: 12)
                        }
                        Text(item).font(.subheadline.weight(.semibold))
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(item == selected ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.white.opacity(0.1)), in: Capsule())
                    .foregroundStyle(item == selected ? .black : .white)
                }
                .buttonStyle(PressScale())
            }
        }
    }
}

/// Lays children out left to right, wrapping onto new lines.
struct WrapLayout: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, maxX: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > 0 && x + sz.width > width { x = 0; y += row + spacing; row = 0 }
            x += sz.width + spacing
            maxX = max(maxX, x - spacing)
            row = max(row, sz.height)
        }
        return CGSize(width: min(width, maxX), height: y + row)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > bounds.minX && x + sz.width > bounds.maxX { x = bounds.minX; y += row + spacing; row = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing
            row = max(row, sz.height)
        }
    }
}
