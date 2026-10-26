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

struct RootView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(Player.self) private var player
    @Environment(LocalLibrary.self) private var local
    @AppStorage("skippedSetup") private var skippedSetup = false
    @State private var tab: AppTab = .home
    @State private var showNowPlaying = false

    var body: some View {
        if !settings.config.isComplete && !skippedSetup && local.tracks.isEmpty {
            OnboardingView(skipped: $skippedSetup)
        } else {
            main
        }
    }

    private var main: some View {
        ZStack(alignment: .bottom) {
            Theme.background.ignoresSafeArea()
            ZStack {
                tabContent(.home) { HomeView(openTab: { tab = $0 }) }
                tabContent(.library) { LibraryView() }
                tabContent(.search) { SearchView() }
                tabContent(.settings) { SettingsView() }
            }
            .safeAreaInset(edge: .bottom) {
                Color.clear.frame(height: player.current == nil ? 58 : 128)
            }

            VStack(spacing: 8) {
                if player.current != nil {
                    MiniPlayer(open: { VizSettings.shared.on = false; showNowPlaying = true })
                        .padding(.horizontal, 10)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                TabBar(tab: $tab)
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: player.current == nil)
        }
        .fullScreenCover(isPresented: $showNowPlaying) { NowPlayingView() }
        .overlay(alignment: .top) { ErrorToast() }
    }

    private func tabContent<V: View>(_ t: AppTab, @ViewBuilder _ content: () -> V) -> some View {
        NavigationStack { content() }
            .opacity(tab == t ? 1 : 0)
            .allowsHitTesting(tab == t)
            .accessibilityHidden(tab != t)
    }
}

struct TabBar: View {
    @Binding var tab: AppTab
    var body: some View {
        HStack {
            ForEach(AppTab.allCases, id: \.self) { t in
                Button {
                    tab = t
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: t.icon(selected: tab == t))
                            .font(.system(size: 19, weight: tab == t ? .semibold : .regular))
                            .symbolRenderingMode(.monochrome)
                        Text(t.label).font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(tab == t ? .white : Theme.tertiary)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 2)
        .background(
            LinearGradient(colors: [Theme.background.opacity(0), Theme.background.opacity(0.92), Theme.background],
                           startPoint: .top, endPoint: .center)
                .ignoresSafeArea(edges: .bottom)
        )
    }
}

struct MiniPlayer: View {
    @Environment(Player.self) private var player
    let open: () -> Void
    @State private var palette = Palette.fallback

    var body: some View {
        if let t = player.current {
            HStack(spacing: 12) {
                ArtworkView(track: t, size: 44, corner: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text(t.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(t.artist).font(.caption).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                }
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
                }
                Button { player.next() } label: {
                    Image(systemName: "forward.fill").font(.body).frame(width: 34, height: 36)
                }
                .buttonStyle(PressScale())
            }
            .foregroundStyle(.white)
            .padding(8)
            .padding(.trailing, 4)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(LinearGradient(colors: [palette.top, palette.bottom], startPoint: .leading, endPoint: .trailing))
                    .overlay(alignment: .bottom) {
                        GeometryReader { g in
                            Capsule().fill(.white.opacity(0.85))
                                .frame(width: max(0, g.size.width - 32) * player.progress, height: 2)
                                .padding(.leading, 16)
                        }
                        .frame(height: 2)
                        .padding(.bottom, 2)
                    }
                    .shadow(color: .black.opacity(0.4), radius: 14, y: 6)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: open)
            .gesture(DragGesture(minimumDistance: 20).onEnded { v in
                if v.translation.height < -30 { open() }
                else if v.translation.width < -60 { player.next() }
                else if v.translation.width > 60 { player.previous() }
            })
            .task(id: t.artworkKey) {
                let p = await ArtworkStore.shared.palette(for: t)
                withAnimation(.easeInOut(duration: 0.6)) { palette = p }
            }
        }
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
