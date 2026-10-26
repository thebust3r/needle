import SwiftUI

/// The server form, shared by Settings and first-run setup.
struct ServerForm: View {
    @Binding var config: ServerConfig
    @State private var testing = false
    @State private var result: (ok: Bool, text: String)?

    var body: some View {
        Section {
            TextField("music.yourdomain.com", text: $config.url)
                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField("Username", text: $config.username)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            SecureField("Password", text: $config.password)
        } header: {
            Text("Navidrome server")
        }

        Section {
            TextField("Client ID", text: $config.accessClientId)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            SecureField("Client Secret", text: $config.accessClientSecret)
        } header: {
            Text("Cloudflare Access")
        } footer: {
            Text("The service token from Cloudflare Zero Trust. Leave blank if you connect another way.")
        }

        Section {
            Button {
                Task { await test() }
            } label: {
                HStack {
                    Text("Test Connection")
                    Spacer()
                    if testing { ProgressView() }
                    else if let result {
                        Image(systemName: result.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(result.ok ? .green : .red)
                    }
                }
            }
            .disabled(!config.isComplete || testing)
        } footer: {
            if let result { Text(result.text).foregroundStyle(result.ok ? Color.green : Color.red) }
        }
    }

    private func test() async {
        testing = true
        defer { testing = false }
        do {
            let c = SubsonicClient(config: config)
            try await c.ping()
            let albums = try await c.albums("newest", size: 1)
            result = (true, albums.isEmpty ? "Connected. Your library looks empty, so check the music folder." : "Connected. Your music is ready.")
        } catch {
            result = (false, error.localizedDescription)
        }
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(AppSettings.self) private var settings
    @Environment(Downloads.self) private var downloads
    @Environment(LocalLibrary.self) private var local
    @State private var draft = ServerConfig()
    @State private var cleared = false

    var body: some View {
        @Bindable var settings = settings
        Form {
            ServerForm(config: $draft)
            if draft != settings.config {
                Section {
                    Button("Save Server Settings") {
                        settings.config = draft
                        app.refreshArtworkClient()
                    }
                    .fontWeight(.semibold)
                    .disabled(!draft.isComplete)
                }
            }

            Section {
                Picker("Streaming quality", selection: $settings.quality) {
                    ForEach(StreamQuality.allCases) { Text($0.label).tag($0) }
                }
            } header: {
                Text("Playback")
            } footer: {
                Text("Original plays your files exactly as they are. Lower quality uses less data on cellular. Downloads always save the original.")
            }

            Section {
                TextField(HelperClient.baseURL(address: "", config: settings.config)?.absoluteString ?? "http://192.168.1.168:8795",
                          text: $settings.helperAddress)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
            } header: {
                Text("Needle web address")
            } footer: {
                Text("Used for importing Spotify playlists. Leave blank to use your server on port 8795.")
            }

            Section("Storage") {
                LabeledContent("Downloaded", value: "\(downloads.saved.count) songs · \(ByteCountFormatter.string(fromByteCount: downloads.totalBytes, countStyle: .file))")
                LabeledContent("On this iPhone", value: "\(local.tracks.count) songs")
                Button(cleared ? "Artwork Cache Cleared" : "Clear Artwork Cache") {
                    Task { await ArtworkStore.shared.clearDisk(); cleared = true }
                }
                .disabled(cleared)
            }

            Section {
                LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
            } footer: {
                Text("Plays your own music from your NAS and this iPhone.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Settings")
        .onAppear { draft = settings.config }
    }
}

struct OnboardingView: View {
    @Environment(AppModel.self) private var app
    @Environment(AppSettings.self) private var settings
    @Binding var skipped: Bool
    @State private var draft = ServerConfig()
    @State private var showForm = false

    var body: some View {
        if showForm {
            NavigationStack {
                Form {
                    ServerForm(config: $draft)
                    Section {
                        Button("Continue") {
                            settings.config = draft
                            app.refreshArtworkClient()
                        }
                        .fontWeight(.semibold)
                        .disabled(!draft.isComplete)
                    }
                }
                .scrollContentBackground(.hidden)
                .background(Theme.background)
                .navigationTitle("Your Server")
                .toolbar { Button("Back") { showForm = false } }
            }
        } else {
            ZStack {
                Theme.background.ignoresSafeArea()
                VStack(alignment: .leading, spacing: 18) {
                    Spacer()
                    Image(systemName: "waveform")
                        .font(.system(size: 54, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                    Text("All your music.\nYour sound.")
                        .font(Theme.title(38))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Stream everything on your NAS, play the songs saved on this iPhone, and tune it all with a real 10-band equalizer.")
                        .font(.body).foregroundStyle(Theme.secondary)
                    Spacer()
                    Button { showForm = true } label: { Text("Connect My Server").frame(maxWidth: .infinity) }
                        .buttonStyle(FilledPill(fill: Theme.accent, text: .black))
                        .font(.headline)
                    Button { skipped = true } label: { Text("Just use music on this iPhone").frame(maxWidth: .infinity) }
                        .buttonStyle(FilledPill(fill: Color.white.opacity(0.08), text: .white))
                        .font(.headline)
                }
                .padding(28)
            }
        }
    }
}
