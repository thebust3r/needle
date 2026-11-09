import SwiftUI

/// Settings > Appearance: pick a look, or make your own. Everything changes live as you tap.
struct AppearanceView: View {
    @State private var look = Look.shared
    @State private var naming = false
    @State private var newName = ""

    var body: some View {
        let s = look.style
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                LookPreview()
                    .padding(.horizontal, 20)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("look-preview")

                group("Looks") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(look.saved) { l in swatch(l).contextMenu { Button("Delete", role: .destructive) { look.delete(l) } } }
                            ForEach(LookStyle.presets) { l in swatch(l) }
                        }
                        .padding(.horizontal, 20)
                    }
                    .padding(.horizontal, -20)
                }

                group("Colors") {
                    VStack(spacing: 0) {
                        ColorPicker(selection: Binding(get: { s.accent.color }, set: { c in look.edit { $0.accent = RGBA(c); $0.followArt = false } }),
                                    supportsOpacity: false) { Label("Accent", systemImage: "paintpalette") }
                            .padding(.vertical, 10)
                        Divider().overlay(Theme.line)
                        Toggle(isOn: Binding(get: { s.followArt }, set: { v in look.edit { $0.followArt = v } })) {
                            Label("Match the album art", systemImage: "photo")
                        }
                        .tint(Theme.accent)
                        .padding(.vertical, 10)
                        Divider().overlay(Theme.line)
                        ColorPicker(selection: Binding(get: { s.background.color }, set: { c in look.edit { $0.background = RGBA(c) } }),
                                    supportsOpacity: false) { Label("Background", systemImage: "square.fill") }
                            .padding(.vertical, 10)
                    }
                    .padding(.horizontal, 16)
                    .finish(Theme.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: Theme.corner(16), style: .continuous), finish: .flat)
                }

                group("Background") {
                    chips(LookBackdrop.allCases, selected: s.backdrop, label: \.label) { v in look.edit { $0.backdrop = v } }
                }

                group("Font") {
                    chips(LookFont.allCases, selected: s.font, label: \.label, font: { f in f.title(15) }) { v in look.edit { $0.font = v } }
                }

                group("Corners") {
                    HStack(spacing: 14) {
                        Image(systemName: "square").foregroundStyle(Theme.secondary)
                        Slider(value: Binding(get: { s.roundness }, set: { v in look.edit { $0.roundness = (v * 20).rounded() / 20 } }), in: 0...2)
                            .tint(Theme.accent)
                            .accessibilityLabel("Corner roundness")
                        Image(systemName: "circle").foregroundStyle(Theme.secondary)
                    }
                }

                group("Buttons") {
                    chips(LookFinish.allCases, selected: s.finish, label: \.label) { v in look.edit { $0.finish = v } }
                }

                group("Tab Bar") {
                    chips(LookTabBar.allCases, selected: s.tabBar, label: \.label) { v in look.edit { $0.tabBar = v } }
                }

                group("Mini Player") {
                    chips(LookMini.allCases, selected: s.mini, label: \.label) { v in look.edit { $0.mini = v } }
                }

                group("Now Playing") {
                    chips(NowPlayingStyle.allCases, selected: s.nowPlaying, label: \.label, icon: \.icon) { v in look.edit { $0.nowPlaying = v } }
                }

                VStack(spacing: 12) {
                    Button { newName = s.custom ? s.name : "My Look"; naming = true } label: {
                        Label(s.custom && look.saved.contains(where: { $0.id == s.id }) ? "Save Changes" : "Save as My Look",
                              systemImage: "square.and.arrow.down")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(FilledPill(fill: Theme.accent, text: readableText(on: Theme.accent)))
                    .accessibilityIdentifier("look-save")
                    Button { withAnimation(.snappy) { look.use(.chrome) } } label: {
                        Text("Back to the Default Look").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.secondary)
                    }
                }
                .padding(.horizontal, 20)
            }
            .padding(.vertical, 16)
            .padding(.bottom, 40)
        }
        .themedBackground()
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
        .animation(.snappy(duration: 0.3), value: s)
        .sensoryFeedback(.selection, trigger: s)
        .alert("Name your look", isPresented: $naming) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Save") { look.saveCurrent(named: newName) }
        }
    }

    private func group<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased()).font(.caption.weight(.bold)).tracking(1).foregroundStyle(Theme.secondary)
            content()
        }
        .padding(.horizontal, 20)
    }

    /// A tappable preview of a whole look.
    private func swatch(_ l: LookStyle) -> some View {
        let on = look.style.id == l.id
        return Button { withAnimation(.snappy(duration: 0.35)) { look.use(l) } } label: {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .bottomLeading) {
                    RoundedRectangle(cornerRadius: 10 * l.roundness, style: .continuous).fill(l.safeBackground.color)
                    Circle().fill(l.accent.color).frame(width: 30, height: 30).offset(x: 46, y: -36)
                    FinishedShape(color: l.accent.color, shape: Capsule(), finish: l.finish)
                        .frame(width: 54, height: 16)
                        .padding(10)
                }
                .frame(width: 96, height: 76)
                .overlay(RoundedRectangle(cornerRadius: 10 * l.roundness, style: .continuous)
                    .stroke(on ? Theme.accent : Color.white.opacity(0.12), lineWidth: on ? 2.5 : 1))
                Text(l.name).font(l.font.title(12)).lineLimit(1).foregroundStyle(on ? .white : Theme.secondary)
                    .frame(width: 96, alignment: .leading)
            }
        }
        .buttonStyle(PressScale())
        .accessibilityIdentifier("look-\(l.id)")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func chips<T: Hashable & Identifiable>(_ all: [T], selected: T, label: KeyPath<T, String>, icon: KeyPath<T, String>? = nil,
                                                   font: ((T) -> Font)? = nil, pick: @escaping (T) -> Void) -> some View {
        FlowLayout(spacing: 8) {
            ForEach(all) { v in
                let on = v == selected
                Button { pick(v) } label: {
                    HStack(spacing: 6) {
                        if let icon { Image(systemName: v[keyPath: icon]) }
                        Text(v[keyPath: label])
                    }
                    .font(font?(v) ?? .subheadline.weight(.semibold))
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .foregroundStyle(on ? readableText(on: Theme.accent) : .white)
                    .finish(on ? Theme.accent : Color.white.opacity(0.08), in: Capsule(), finish: on ? nil : LookFinish.flat)
                }
                .buttonStyle(PressScale())
                .accessibilityAddTraits(on ? .isSelected : [])
                .accessibilityIdentifier("chip-\(v[keyPath: label])")
            }
        }
    }
}

/// A little mock of the app wearing the current look.
struct LookPreview: View {
    var body: some View {
        let s = Look.shared.style
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Good evening").font(Theme.title(22))
                Spacer()
                Image(systemName: "shuffle")
                    .font(.footnote.weight(.bold))
                    .frame(width: 34, height: 34)
                    .foregroundStyle(readableText(on: Theme.accent))
                    .finish(Theme.accent, in: Circle())
            }
            HStack(spacing: 10) {
                ForEach(0..<3) { i in
                    RoundedRectangle(cornerRadius: Theme.corner(10), style: .continuous)
                        .fill(LinearGradient(colors: [Theme.accent.opacity(0.9 - Double(i) * 0.25), Theme.accent.darker(0.6)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(height: 70)
                }
            }
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: Theme.corner(6), style: .continuous).fill(Theme.accent.opacity(0.7)).frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Song Title").font(.subheadline.weight(.semibold))
                    Text("Artist").font(.caption).foregroundStyle(Theme.secondary)
                }
                Spacer()
                Image(systemName: "play.fill")
            }
            .padding(8)
            .background {
                switch s.mini {
                case .album: FinishedShape(color: Theme.accent.darker(0.55), shape: RoundedRectangle(cornerRadius: Theme.corner(14), style: .continuous))
                case .glass: FinishedShape(color: Theme.accent.darker(0.5), shape: RoundedRectangle(cornerRadius: Theme.corner(14), style: .continuous), finish: .glass)
                case .accent: FinishedShape(color: Theme.accent.darker(0.45), shape: RoundedRectangle(cornerRadius: Theme.corner(14), style: .continuous))
                }
            }
            HStack {
                Text("Play").font(.subheadline.weight(.bold)).padding(.horizontal, 22).padding(.vertical, 9)
                    .foregroundStyle(readableText(on: Theme.accent))
                    .finish(Theme.accent, in: Capsule())
                Spacer()
                Label(s.nowPlaying.label, systemImage: s.nowPlaying.icon).font(.caption.weight(.semibold)).foregroundStyle(Theme.secondary)
            }
        }
        .padding(16)
        .background(ThemeBackdrop().clipShape(RoundedRectangle(cornerRadius: Theme.corner(20), style: .continuous)))
        .overlay(RoundedRectangle(cornerRadius: Theme.corner(20), style: .continuous).stroke(Color.white.opacity(0.12)))
        .lookFonts()
    }
}

/// Lays chips out in rows, wrapping to the next line when they don't fit.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let natural = sizes.reduce(0) { $0 + $1.width } + spacing * CGFloat(max(0, sizes.count - 1))
        // no width given (or "as wide as you like"): one row; otherwise wrap exactly like placeSubviews does
        guard let width = proposal.width, width.isFinite else {
            return CGSize(width: natural, height: sizes.map(\.height).max() ?? 0)
        }
        var x: CGFloat = 0
        var y: CGFloat = 0
        var row: CGFloat = 0
        for s in sizes {
            if x > 0 && x + s.width > width {
                x = 0
                y += row + spacing
                row = 0
            }
            x += s.width + spacing
            row = max(row, s.height)
        }
        return CGSize(width: width, height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var row: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX {
                x = bounds.minX
                y += row + spacing
                row = 0
            }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            row = max(row, s.height)
        }
    }
}

/// Settings > Home Layout: drag sections into the order you like, switch off the ones you don't want.
struct HomeLayoutView: View {
    @State private var layout = HomeLayout.shared

    var body: some View {
        List {
            Section {
                ForEach(layout.order) { s in
                    HStack(spacing: 14) {
                        Image(systemName: s.icon).foregroundStyle(Theme.accent).frame(width: 26)
                        Text(s.label)
                        Spacer()
                        Toggle("", isOn: Binding(get: { !layout.hidden.contains(s) }, set: { layout.setShown(s, $0) }))
                            .labelsHidden()
                            .tint(Theme.accent)
                            .accessibilityLabel("Show \(s.label)")
                    }
                    .listRowBackground(Theme.surface.opacity(0.6))
                }
                .onMove { layout.move(from: $0, to: $1) }
            } footer: {
                Text("Drag the handles to reorder. Switched-off sections are hidden from Home.")
            }
            Section {
                Button("Reset to the Usual Order") { withAnimation { layout.reset() } }
                    .listRowBackground(Theme.surface.opacity(0.6))
            }
        }
        .environment(\.editMode, .constant(.active))
        .scrollContentBackground(.hidden)
        .themedBackground()
        .navigationTitle("Home Layout")
        .navigationBarTitleDisplayMode(.inline)
    }
}
