import Observation
import QuartzCore
import SwiftUI
import UIKit

/// Visualizer settings, remembered between launches, plus the one shared engine.
@Observable @MainActor
final class VizSettings {
    static let shared = VizSettings()

    @ObservationIgnored let engine = VizEngine()

    var on: Bool { didSet { UserDefaults.standard.set(on, forKey: "viz.on") } }
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

    var label: String { auto ? "Auto · \(mode.name)" : mode.name }

    init() {
        let d = UserDefaults.standard
        on = d.bool(forKey: "viz.on")
        mode = VizEngine.Mode(rawValue: d.integer(forKey: "viz.mode")) ?? .tunnel
        auto = d.object(forKey: "viz.auto") as? Bool ?? true
        engine.mode = mode
        engine.auto = auto
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

/// Shows the engine's frames, drawn in step with the screen refresh.
final class VizUIView: UIView {
    var isPlaying: () -> Bool = { false }
    var active = false { didSet { updateLink() } }

    private var link: CADisplayLink?
    private let flashLayer = CALayer()
    private var last: CFTimeInterval = 0
    private var quality: CGFloat = 1
    private var slowSince: CFTimeInterval = 0
    private var fastSince: CFTimeInterval = 0
    private var recentDt: [Double] = []
    private var recentMs: [Double] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        layer.contentsGravity = .resizeAspectFill
        layer.magnificationFilter = .linear
        flashLayer.opacity = 0
        flashLayer.compositingFilter = "screenBlendMode"
        layer.addSublayer(flashLayer)
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        flashLayer.frame = bounds
        CATransaction.commit()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateLink()
    }

    private func updateLink() {
        let should = active && window != nil
        if should, link == nil {
            let l = CADisplayLink(target: self, selector: #selector(tick(_:)))
            l.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
            l.add(to: .main, forMode: .common)
            link = l
            last = 0
            EQProcessor.shared.spectrumEnabled = true
        } else if !should, let l = link {
            l.invalidate()
            link = nil
            flashLayer.opacity = 0
        }
    }

    @objc private func tick(_ l: CADisplayLink) {
        guard bounds.width > 1 else { return }
        let engine = VizSettings.shared.engine
        engine.reducedMotion = UIAccessibility.isReduceMotionEnabled
        let scale = min(window?.screen.scale ?? 2, 2) * quality
        let w = Int(min(bounds.width * scale, 900))
        let h = Int(min(bounds.height * scale, 900 * bounds.height / bounds.width))
        engine.resize(width: w, height: h)

        let now = l.timestamp
        let dt = last == 0 ? 1.0 / 60 : now - last
        last = now
        let t0 = CACurrentMediaTime()
        let input = EQProcessor.shared.vizInput(playing: isPlaying())
        guard let image = engine.render(time: now, dt: dt, input: input) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contents = image
        let o = engine.flash > 0.02 ? engine.flash * 0.18 : 0
        if o > 0 && flashLayer.opacity == 0 { flashLayer.backgroundColor = engine.flashColor() }
        flashLayer.opacity = o
        CATransaction.commit()
        governor(now, ms: (CACurrentMediaTime() - t0) * 1000, dt: dt)
    }

    /// Keeps it smooth: lowers resolution if frames get slow, raises it again when there's headroom.
    private func governor(_ t: CFTimeInterval, ms: Double, dt: Double) {
        recentDt.append(dt); if recentDt.count > 30 { recentDt.removeFirst() }
        recentMs.append(ms); if recentMs.count > 30 { recentMs.removeFirst() }
        let avgDt = recentDt.reduce(0, +) / Double(recentDt.count)
        let avgMs = recentMs.reduce(0, +) / Double(recentMs.count)
        if avgDt > 0.020 || avgMs > 8 {
            fastSince = 0
            if slowSince == 0 { slowSince = t }
            if t - slowSince > 0.8, quality > 0.4 { quality = max(0.4, quality - 0.15); slowSince = t }
        } else if avgDt < 0.0175 && avgMs < 4 {
            slowSince = 0
            if fastSince == 0 { fastSince = t }
            if t - fastSince > 4, quality < 1 { quality = min(1, quality + 0.15); fastSince = t }
        } else {
            slowSince = 0; fastSince = 0
        }
    }
}

struct VisualizerView: UIViewRepresentable {
    @Environment(Player.self) private var player
    var active: Bool

    func makeUIView(context: Context) -> VizUIView { VizUIView(frame: .zero) }

    func updateUIView(_ view: VizUIView, context: Context) {
        let p = player
        view.isPlaying = { MainActor.assumeIsolated { p.isPlaying } }
        view.active = active
    }

    static func dismantleUIView(_ view: VizUIView, coordinator: ()) { view.active = false }
}

/// The small style button and full-screen button shown on the visualizer.
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

struct VizFullScreen: View {
    @Environment(Player.self) private var player
    @Environment(\.dismiss) private var dismiss
    @State private var viz = VizSettings.shared
    @State private var showControls = true
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VisualizerView(active: true).ignoresSafeArea()
            VStack {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.headline).frame(width: 36, height: 36)
                            .background(.black.opacity(0.45), in: Circle())
                    }
                    Spacer()
                    Button { viz.cycle(); wake() } label: { VizChip(text: viz.label) }
                }
                Spacer()
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
        .foregroundStyle(.white)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .contentShape(Rectangle())
        .onTapGesture { wake() }
        .gesture(DragGesture(minimumDistance: 30).onEnded { v in
            if abs(v.translation.width) > abs(v.translation.height) {
                viz.step(v.translation.width < 0 ? 1 : -1)
            } else if v.translation.height > 120 {
                dismiss()
            }
            wake()
        })
        .onAppear { wake() }
        .onDisappear { hideTask?.cancel() }
    }

    private func wake() {
        showControls = true
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            if !Task.isCancelled { showControls = false }
        }
    }
}
