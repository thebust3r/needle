import SwiftUI

enum AppTab: String, CaseIterable {
    case home, library, search, settings
    var label: String { rawValue.capitalized }
    func icon(selected: Bool) -> String {
        switch self {
        case .home: return selected ? "house.fill" : "house"
        case .library: return selected ? "square.stack.fill" : "square.stack"
        case .search: return "magnifyingglass"
        case .settings: return "slider.horizontal.3"
        }
    }
}

/// Lets screens outside the tabs (Now Playing) open a page in the current tab.
@Observable final class Navigator {
    static let shared = Navigator()
    private(set) var request: ArtistRoute?
    private(set) var token = 0
    func open(_ route: ArtistRoute) { request = route; token += 1 }
}

struct RootView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(Player.self) private var player
    @Environment(LocalLibrary.self) private var local
    @AppStorage("skippedSetup") private var skippedSetup = false
    @State private var tab: AppTab = .home
    @State private var showNowPlaying = false
    @State private var paths: [AppTab: NavigationPath] = [:]
    @State private var nav = Navigator.shared
    @State private var picker = PlaylistPicker.shared
    @Namespace private var zoom

    var body: some View {
        if !settings.config.isComplete && !skippedSetup && local.tracks.isEmpty {
            OnboardingView(skipped: $skippedSetup)
        } else {
            main
        }
    }

    private var main: some View {
        ZStack(alignment: .bottom) {
            ThemeBackdrop()
            ZStack {
                tabContent(.home) { HomeView(openTab: { tab = $0 }) }
                tabContent(.library) { LibraryView() }
                tabContent(.search) { SearchView() }
                tabContent(.settings) { SettingsView() }
            }
            .safeAreaInset(edge: .bottom) {
                Color.clear.frame(height: (Look.shared.style.tabBar == .classic ? 58 : 66) + (player.current == nil ? 0 : 70))
            }

            VStack(spacing: 8) {
                if player.current != nil {
                    MiniPlayer(open: { VizSettings.shared.on = false; showNowPlaying = true })
                        .zoomSource("nowplaying")
                        .padding(.horizontal, 10)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                TabBar(tab: $tab) { t in
                    // tapping the tab you're on goes all the way back to its first page
                    if !(paths[t]?.isEmpty ?? true) {
                        withAnimation(.snappy(duration: 0.3)) { paths[t] = NavigationPath() }
                    } else {
                        TabReselect.shared.fire(t)
                    }
                }
                .sensoryFeedback(.selection, trigger: tab)
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: player.current == nil)
        }
        .lookFonts()
        .fullScreenCover(isPresented: $showNowPlaying) {
            NowPlayingView().zoomDestination("nowplaying").environment(\.zoomNamespace, zoom).lookFonts()
        }
        .environment(\.zoomNamespace, zoom)
        .overlay(alignment: .top) { ErrorToast() }
        .modifier(DeleteConfirm(enabled: !showNowPlaying))
        .sheet(item: Binding(get: { showNowPlaying ? nil : picker.request }, set: { picker.request = $0 })) { r in
            PlaylistPickerSheet(tracks: r.tracks)
        }
        .onChange(of: nav.token) { _, _ in
            guard let route = nav.request else { return }
            // close Now Playing, then open the page in the tab you're on (Settings has no pages: use Home)
            showNowPlaying = false
            if tab == .settings { tab = .home }
            let t = tab
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(350))
                paths[t, default: NavigationPath()].append(route)
            }
        }
    }

    private func tabContent<V: View>(_ t: AppTab, @ViewBuilder _ content: () -> V) -> some View {
        NavigationStack(path: Binding(get: { paths[t] ?? NavigationPath() }, set: { paths[t] = $0 })) { content() }
            .opacity(tab == t ? 1 : 0)
            .allowsHitTesting(tab == t)
            .accessibilityHidden(tab != t)
    }
}

/// "You tapped the tab you're already on, at its first page": screens scroll back to the top.
@Observable final class TabReselect {
    static let shared = TabReselect()
    private(set) var tab: AppTab?
    private(set) var count = 0
    func fire(_ t: AppTab) { tab = t; count += 1 }
}

/// Put `ScrollTopAnchor()` first inside a tab's main scroll view; tapping that tab again scrolls back up to it.
struct ScrollTopAnchor: View {
    var body: some View { Color.clear.frame(height: 0).id("scroll-top") }
}

extension View {
    func scrollsToTopOnReselect(_ tab: AppTab) -> some View {
        ScrollViewReader { proxy in
            self.onChange(of: TabReselect.shared.count) { _, _ in
                if TabReselect.shared.tab == tab {
                    withAnimation(.snappy(duration: 0.35)) { proxy.scrollTo("scroll-top", anchor: .top) }
                }
            }
        }
    }
}

struct TabBar: View {
    @Binding var tab: AppTab
    var reselect: (AppTab) -> Void = { _ in }
    @Namespace private var bubble

    var body: some View {
        let style = Look.shared.style.tabBar
        HStack(spacing: style == .classic ? 0 : 2) {
            ForEach(AppTab.allCases, id: \.self) { t in
                Button {
                    if tab == t { reselect(t) } else { withAnimation(.snappy(duration: 0.28)) { tab = t } }
                } label: { item(t, style) }
                .buttonStyle(PressScale())
                .accessibilityIdentifier("tab-\(t.rawValue)")
                .accessibilityLabel(t.label)
                .accessibilityAddTraits(tab == t ? .isSelected : [])
            }
        }
        .modifier(TabBarShell(style: style))
    }

    @ViewBuilder
    private func item(_ t: AppTab, _ style: LookTabBar) -> some View {
        let on = tab == t
        VStack(spacing: 4) {
            Image(systemName: t.icon(selected: on))
                .font(.system(size: style == .dock ? 18 : 19, weight: on ? .semibold : .regular))
                .symbolRenderingMode(.monochrome)
                .frame(width: 44, height: style == .classic ? 24 : 30)
                .background {
                    if on && style != .classic {
                        FinishedShape(color: Theme.accent.opacity(style == .dock ? 1 : 0.9), shape: Capsule())
                            .matchedGeometryEffect(id: "bubble", in: bubble)
                    }
                }
                .foregroundStyle(on && style != .classic ? readableText(on: Theme.accent) : (on ? .white : Theme.tertiary))
            if style != .floating {
                Text(t.label).font(.system(size: 10, weight: .medium))
                    .foregroundStyle(on ? .white : Theme.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, style == .floating ? 8 : 0)
        .contentShape(Rectangle())
    }
}

/// The bar behind the tabs: a fade (Classic), a pill hovering over the screen (Floating), or a glossy dock (Dock).
struct TabBarShell: ViewModifier {
    let style: LookTabBar
    func body(content: Content) -> some View {
        switch style {
        case .classic:
            content
                .padding(.top, 8)
                .padding(.bottom, 2)
                .background(
                    LinearGradient(colors: [Theme.background.opacity(0), Theme.background.opacity(0.92), Theme.background],
                                   startPoint: .top, endPoint: .center)
                        .ignoresSafeArea(edges: .bottom)
                )
        case .floating:
            content
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .finish(Theme.surface, in: Capsule())
                .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
                .padding(.horizontal, 28)
                .padding(.bottom, 4)
                .background(fade)
        case .dock:
            content
                .padding(.horizontal, 8)
                .padding(.top, 8)
                .padding(.bottom, 6)
                .finish(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.corner(22), style: .continuous))
                .shadow(color: .black.opacity(0.4), radius: 14, y: 6)
                .padding(.horizontal, 10)
                .padding(.bottom, 2)
                .background(fade)
        }
    }

    /// Fades the screen out under the bar so what scrolls behind it doesn't clash.
    private var fade: some View {
        LinearGradient(colors: [Theme.background.opacity(0), Theme.background.opacity(0.85), Theme.background],
                       startPoint: .top, endPoint: .bottom)
            .padding(.top, -30)
            .ignoresSafeArea(edges: .bottom)
    }
}

struct MiniPlayer: View {
    @Environment(Player.self) private var player
    let open: () -> Void
    @State private var palette = Palette.fallback
    @State private var drag: CGFloat = 0
    @State private var skips = 0

    var body: some View {
        if let t = player.current {
            HStack(spacing: 12) {
                ArtworkView(track: t, size: 44, corner: 7)
                    .id(t.id)
                    .transition(.asymmetric(insertion: .scale(scale: 0.6).combined(with: .opacity), removal: .opacity))
                VStack(alignment: .leading, spacing: 1) {
                    Text(t.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(t.artist).font(.caption).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                }
                .id("meta-" + t.id)
                .transition(.push(from: drag > 0 ? .leading : .trailing).combined(with: .opacity))
                Spacer()
                if player.isBuffering && player.isPlaying {
                    ProgressView().tint(.white).frame(width: 36)
                } else {
                    Button { player.togglePlay() } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title3).frame(width: 36, height: 36)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(PressScale())
                    .sensoryFeedback(.impact(weight: .light), trigger: player.isPlaying)
                }
                Button { skip(+1) } label: {
                    Image(systemName: "forward.fill").font(.body).frame(width: 34, height: 36)
                }
                .buttonStyle(PressScale())
            }
            .foregroundStyle(.white)
            .padding(8)
            .padding(.trailing, 4)
            .background {
                miniBackground
                    .overlay(alignment: .bottom) { MiniProgress().padding(.bottom, 2) }
                    .shadow(color: .black.opacity(0.4), radius: 14, y: 6)
            }
            .offset(x: drag * 0.35)
            .contentShape(Rectangle())
            .onTapGesture(perform: open)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("mini-player")
            .gesture(DragGesture(minimumDistance: 14)
                .onChanged { v in if abs(v.translation.width) > abs(v.translation.height) { drag = v.translation.width } }
                .onEnded { v in
                    if v.translation.height < -30 && abs(v.translation.height) > abs(v.translation.width) { open() }
                    else if v.translation.width < -60 { skip(+1) }
                    else if v.translation.width > 60 { skip(-1) }
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { drag = 0 }
                })
            .sensoryFeedback(.impact(weight: .medium), trigger: skips)
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: t.id)
            .task(id: t.artworkKey) {
                let p = await ArtworkStore.shared.palette(for: t)
                withAnimation(.easeInOut(duration: 0.6)) {
                    palette = p
                    AccentStore.shared.albumColor = p.accent
                }
            }
        }
    }

    /// The bar's look: the album's colors, frosted glass tinted by the album, or your accent.
    @ViewBuilder private var miniBackground: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.corner(16), style: .continuous)
        switch Look.shared.style.mini {
        case .album:
            FinishedShape(color: palette.bottom, shape: shape)
                .overlay(shape.fill(LinearGradient(colors: [palette.top.opacity(0.9), palette.bottom.opacity(0)],
                                                   startPoint: .leading, endPoint: .trailing)))
                .clipShape(shape)
        case .glass:
            FinishedShape(color: palette.bottom, shape: shape, finish: .glass)
        case .accent:
            FinishedShape(color: Theme.accent.darker(0.45), shape: shape)
        }
    }

    private func skip(_ dir: Int) {
        skips += 1
        dir > 0 ? player.next() : player.previous()
    }
}

/// The thin progress line on the mini player; its own view so only it redraws as the song plays.
struct MiniProgress: View {
    @Environment(Player.self) private var player
    var body: some View {
        GeometryReader { g in
            Capsule().fill(.white.opacity(0.85))
                .frame(width: max(0, g.size.width - 32) * player.progress, height: 2)
                .padding(.leading, 16)
        }
        .frame(height: 2)
    }
}

struct ErrorToast: View {
    @Environment(Player.self) private var player
    var body: some View {
        if let msg = player.errorMessage {
            Text(msg)
                .font(.footnote.weight(.medium))
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.horizontal, 20)
                .padding(.top, 6)
                .transition(.move(edge: .top).combined(with: .opacity))
                .task(id: msg) {
                    try? await Task.sleep(for: .seconds(4))
                    withAnimation { player.errorMessage = nil }
                }
                .onTapGesture { player.errorMessage = nil }
        }
    }
}
