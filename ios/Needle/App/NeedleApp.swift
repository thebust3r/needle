import Observation
import SwiftUI

@main
struct NeedleApp: App {
    @State private var app = AppModel()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .environment(app.player)
                .environment(app.equalizer)
                .environment(app.downloads)
                .environment(app.local)
                .environment(app.settings)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                .task { await app.local.scanInbox() }
                .onChange(of: phase) { _, p in
                    if p == .active { Task { await app.local.scanInbox() } }
                }
        }
    }
}

@Observable @MainActor
final class AppModel {
    let settings = AppSettings()
    let player = Player()
    let equalizer = Equalizer()
    let downloads = Downloads()
    let local = LocalLibrary()
    let lyrics = LyricsStore()

    var client: SubsonicClient { SubsonicClient(config: settings.config) }
    var helper: HelperClient { HelperClient(config: settings.config, address: settings.helperAddress) }

    init() {
        warmUpBlur()
        let settings = self.settings, downloads = self.downloads, local = self.local
        player.client = { SubsonicClient(config: settings.config) }
        player.quality = { settings.quality }
        player.localFile = { track in local.fileURL(for: track) ?? downloads.fileURL(for: track.id) }
        downloads.client = { SubsonicClient(config: settings.config) }
        refreshArtworkClient()
    }

    func refreshArtworkClient() {
        let c = client
        Task { await ArtworkStore.shared.setClient(c) }
    }
}
