import SwiftUI

struct EqualizerView: View {
    @Environment(Equalizer.self) private var eq
    @Environment(\.dismiss) private var dismiss
    var tint: Color = Theme.accent

    @State private var activeBand: Int?
    @State private var naming = false
    @State private var newName = ""

    var body: some View {
        @Bindable var eq = eq
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    EQGraph(tint: tint, activeBand: $activeBand)
                        .frame(height: 290)
                        .opacity(eq.enabled ? 1 : 0.4)
                        .allowsHitTesting(eq.enabled)
                        .padding(.horizontal, 16)

                    bandValues

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Presets").font(.system(size: 18, weight: .bold).width(.expanded))
                            .padding(.horizontal, 20)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(eq.allPresets) { p in
                                    Button { withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { eq.apply(p) } } label: {
                                        Text(p.name)
                                            .font(.subheadline.weight(.medium))
                                            .padding(.horizontal, 14).padding(.vertical, 9)
                                            .background(eq.presetName == p.name ? tint : Color.white.opacity(0.1), in: Capsule())
                                            .foregroundStyle(eq.presetName == p.name ? Color.black : Color.white)
                                    }
                                    .contextMenu {
                                        if !p.builtIn {
                                            Button(role: .destructive) { eq.delete(p) } label: { Label("Delete Preset", systemImage: "trash") }
                                        }
                                    }
                                }
                                Button { newName = ""; naming = true } label: {
                                    Label("Save", systemImage: "plus")
                                        .font(.subheadline.weight(.medium))
                                        .padding(.horizontal, 14).padding(.vertical, 9)
                                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                                }
                            }
                            .padding(.horizontal, 20)
                        }
                        .disabled(!eq.enabled)
                    }

                    VStack(alignment: .leading, spacing: 18) {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Preamp").font(.headline)
                                Spacer()
                                Text(String(format: "%+.1f dB", eq.preamp)).font(.subheadline.monospacedDigit()).foregroundStyle(Theme.secondary)
                            }
                            Slider(value: $eq.preamp, in: -12...6, step: 0.5).tint(tint)
                        }
                        Toggle(isOn: $eq.clipGuard) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Prevent distortion").font(.headline)
                                Text("Lowers the volume a little when you boost, so loud parts don't crackle.")
                                    .font(.caption).foregroundStyle(Theme.secondary)
                            }
                        }
                        .tint(tint)
                    }
                    .padding(18)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .padding(.horizontal, 16)
                    .disabled(!eq.enabled)
                }
                .padding(.vertical, 12)
            }
            .navigationTitle("Equalizer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Toggle("On", isOn: $eq.enabled).labelsHidden().tint(tint)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.fontWeight(.semibold)
                }
            }
            .alert("Save Preset", isPresented: $naming) {
                TextField("Name", text: $newName)
                Button("Save") { eq.saveCurrent(as: newName) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Give this sound a name.")
            }
        }
        .onAppear { EQProcessor.shared.spectrumEnabled = true }
    }

    private var bandValues: some View {
        HStack(spacing: 0) {
            ForEach(0..<10, id: \.self) { i in
                VStack(spacing: 3) {
                    Text(String(format: "%+.0f", eq.gains[i]))
                        .font(.caption2.monospacedDigit().weight(activeBand == i ? .bold : .regular))
                        .foregroundStyle(activeBand == i ? tint : (eq.gains[i] == 0 ? Theme.tertiary : .white))
                    Text(Equalizer.labels[i]).font(.system(size: 9, weight: .medium)).foregroundStyle(Theme.tertiary)
                }
                .frame(maxWidth: .infinity)
                .onTapGesture(count: 2) { withAnimation(.spring) { eq.setGain(0, band: i) } }
            }
        }
        .padding(.horizontal, 16)
    }
}

/// The frequency graph: live spectrum behind, the EQ curve on top, and a knob for each band.
/// Drag anywhere to grab the nearest band and pull it up or down.
struct EQGraph: View {
    @Environment(Equalizer.self) private var eq
    let tint: Color
    @Binding var activeBand: Int?

    private let minF = 20.0, maxF = 20000.0, maxDB: Float = 12

    var body: some View {
        GeometryReader { g in
            let size = g.size
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.black.opacity(0.35))
                grid(size)
                TimelineView(.animation(minimumInterval: 1 / 30)) { _ in
                    spectrum(size, EQProcessor.shared.spectrum(bins: 72))
                }
                curve(size)
                ForEach(0..<10, id: \.self) { i in knob(i, size) }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    let band = activeBand ?? nearestBand(v.startLocation.x, size.width)
                    if activeBand == nil { activeBand = band }
                    eq.setGain(gain(forY: v.location.y, size.height), band: band)
                }
                .onEnded { _ in withAnimation(.easeOut(duration: 0.3)) { activeBand = nil } })
            .sensoryFeedback(.selection, trigger: activeBand)
        }
    }

    private func x(_ f: Double, _ w: CGFloat) -> CGFloat {
        CGFloat(log(f / minF) / log(maxF / minF)) * w
    }

    private func y(_ db: Float, _ h: CGFloat) -> CGFloat {
        let pad: CGFloat = 26
        return h / 2 - CGFloat(db / maxDB) * (h / 2 - pad)
    }

    private func gain(forY yy: CGFloat, _ h: CGFloat) -> Float {
        let pad: CGFloat = 26
        let v = Float((h / 2 - yy) / (h / 2 - pad)) * maxDB
        let snapped = (v * 2).rounded() / 2
        return abs(snapped) < 0.6 ? 0 : snapped          // a little magnet at 0 dB
    }

    private func nearestBand(_ xx: CGFloat, _ w: CGFloat) -> Int {
        var best = 0, dist = CGFloat.infinity
        for (i, f) in Equalizer.frequencies.enumerated() {
            let d = abs(x(Double(f), w) - xx)
            if d < dist { dist = d; best = i }
        }
        return best
    }

    private func grid(_ s: CGSize) -> some View {
        Canvas { ctx, size in
            for db in [-12, -6, 0, 6, 12] as [Float] {
                let yy = y(db, size.height)
                var p = Path(); p.move(to: CGPoint(x: 0, y: yy)); p.addLine(to: CGPoint(x: size.width, y: yy))
                ctx.stroke(p, with: .color(.white.opacity(db == 0 ? 0.22 : 0.07)), style: StrokeStyle(lineWidth: 1, dash: db == 0 ? [] : [3, 4]))
                if db != 0 {
                    ctx.draw(Text("\(db > 0 ? "+" : "")\(Int(db))").font(.system(size: 9)).foregroundColor(.white.opacity(0.3)),
                             at: CGPoint(x: 14, y: yy - 7))
                }
            }
            for f in Equalizer.frequencies {
                let xx = x(Double(f), size.width)
                var p = Path(); p.move(to: CGPoint(x: xx, y: 10)); p.addLine(to: CGPoint(x: xx, y: size.height - 10))
                ctx.stroke(p, with: .color(.white.opacity(0.04)), lineWidth: 1)
            }
        }
    }

    private func spectrum(_ s: CGSize, _ bins: [Float]) -> some View {
        Canvas { ctx, size in
            let w = size.width / CGFloat(bins.count)
            for (i, v) in bins.enumerated() where v > 0.01 {
                let h = CGFloat(v) * (size.height - 20)
                let rect = CGRect(x: CGFloat(i) * w + 0.75, y: size.height - 10 - h, width: max(1, w - 1.5), height: h)
                ctx.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(.white.opacity(0.07 + Double(v) * 0.1)))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func curvePath(_ size: CGSize) -> Path {
        var p = Path()
        let steps = 140
        for i in 0...steps {
            let f = minF * pow(maxF / minF, Double(i) / Double(steps))
            let db = Float(Equalizer.response(at: f, gains: eq.gains))
            let pt = CGPoint(x: x(f, size.width), y: y(max(-maxDB * 1.3, min(maxDB * 1.3, db)), size.height))
            i == 0 ? p.move(to: pt) : p.addLine(to: pt)
        }
        return p
    }

    private func curve(_ s: CGSize) -> some View {
        let line = curvePath(s)
        var fill = line
        fill.addLine(to: CGPoint(x: s.width, y: s.height / 2))
        fill.addLine(to: CGPoint(x: 0, y: s.height / 2))
        fill.closeSubpath()
        return ZStack {
            fill.fill(LinearGradient(colors: [tint.opacity(0.35), tint.opacity(0.02), tint.opacity(0.35)],
                                     startPoint: .top, endPoint: .bottom))
            line.stroke(tint, style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round)).blur(radius: 8).opacity(0.8)
            line.stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: eq.gains)
    }

    private func knob(_ i: Int, _ s: CGSize) -> some View {
        let active = activeBand == i
        return Circle()
            .fill(active ? tint : Color.white)
            .frame(width: active ? 22 : 14, height: active ? 22 : 14)
            .shadow(color: tint.opacity(active ? 0.9 : 0.4), radius: active ? 12 : 5)
            .overlay(Circle().strokeBorder(Color.black.opacity(0.25), lineWidth: 1))
            .position(x: x(Double(Equalizer.frequencies[i]), s.width), y: y(eq.gains[i], s.height))
            .animation(.spring(response: 0.3, dampingFraction: 0.75), value: active)
            .allowsHitTesting(false)
    }
}
