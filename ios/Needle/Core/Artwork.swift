import CoreImage
import SwiftUI
import UIKit

/// Loads album art (with the Cloudflare headers), keeps it in memory and on disk,
/// and works out each cover's colors for the Now Playing backdrop.
actor ArtworkStore {
    static let shared = ArtworkStore()

    private var client: SubsonicClient?
    private let memory = NSCache<NSString, UIImage>()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]
    private var palettes: [String: Palette] = [:]
    private let folder: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("art")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    init() { memory.countLimit = 300 }

    func setClient(_ c: SubsonicClient) { client = c }

    func image(for track: Track, size: Int) async -> UIImage? {
        if let file = track.localArtwork {
            return await localImage(file)
        }
        guard let id = track.coverArt else { return nil }
        return await image(coverArt: id, size: size)
    }

    func localImage(_ file: String) async -> UIImage? {
        let key = "local-\(file)" as NSString
        if let img = memory.object(forKey: key) { return img }
        let url = LocalLibrary.folder.appendingPathComponent(file)
        guard let img = UIImage(contentsOfFile: url.path) else { return nil }
        memory.setObject(img, forKey: key)
        return img
    }

    func image(coverArt id: String, size: Int) async -> UIImage? {
        let px = size <= 160 ? 160 : (size <= 400 ? 400 : 900)   // a few fixed sizes = better caching
        let key = "\(id)-\(px)"
        if let img = memory.object(forKey: key as NSString) { return img }
        if let task = inFlight[key] { return await task.value }
        let disk = folder.appendingPathComponent(key.replacingOccurrences(of: "/", with: "_") + ".jpg")
        let client = self.client
        let task = Task<UIImage?, Never> {
            if let data = try? Data(contentsOf: disk), let img = UIImage(data: data) { return img }
            guard let client, let url = client.coverURL(id, size: px) else { return nil }
            guard let result = try? await client.session.data(for: client.request(for: url)),
                  (try? SubsonicClient.check(result.1)) != nil,
                  let img = UIImage(data: result.0) else { return nil }
            let data = result.0
            try? data.write(to: disk)
            return img
        }
        inFlight[key] = task
        let img = await task.value
        inFlight[key] = nil
        if let img { memory.setObject(img, forKey: key as NSString) }
        return img
    }

    func palette(for track: Track) async -> Palette {
        if let p = palettes[track.artworkKey] { return p }
        guard let img = await image(for: track, size: 160) else { return .fallback }
        let p = Palette(image: img)
        palettes[track.artworkKey] = p
        return p
    }

    func clearDisk() {
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        memory.removeAllObjects()
    }
}

/// Two colors pulled from a cover: one from the top, one from the bottom.
struct Palette: Equatable {
    var top: Color
    var bottom: Color
    var accent: Color

    static let fallback = Palette(top: Color(red: 0.20, green: 0.16, blue: 0.30),
                                  bottom: Color(red: 0.07, green: 0.06, blue: 0.10),
                                  accent: Color(red: 0.95, green: 0.55, blue: 0.40))

    init(top: Color, bottom: Color, accent: Color) {
        self.top = top; self.bottom = bottom; self.accent = accent
    }

    init(image: UIImage) {
        guard let cg = image.cgImage else { self = .fallback; return }
        let ci = CIImage(cgImage: cg)
        let e = ci.extent
        let topRGB = Palette.average(ci, CGRect(x: e.minX, y: e.midY, width: e.width, height: e.height / 2))
        let botRGB = Palette.average(ci, CGRect(x: e.minX, y: e.minY, width: e.width, height: e.height / 2))
        let vivid = Palette.mostVivid(ci)
        top = Palette.tone(topRGB, maxBrightness: 0.55)
        bottom = Palette.tone(botRGB, maxBrightness: 0.25)
        accent = Palette.tone(vivid, minBrightness: 0.75, minSaturation: 0.45)
    }

    private static let context = CIContext(options: [.workingColorSpace: NSNull()])

    private static func average(_ img: CIImage, _ rect: CGRect) -> UIColor {
        let filter = CIFilter(name: "CIAreaAverage",
                              parameters: [kCIInputImageKey: img, kCIInputExtentKey: CIVector(cgRect: rect)])
        var px = [UInt8](repeating: 0, count: 4)
        if let out = filter?.outputImage {
            context.render(out, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                           format: .RGBA8, colorSpace: nil)
        }
        return UIColor(red: CGFloat(px[0]) / 255, green: CGFloat(px[1]) / 255, blue: CGFloat(px[2]) / 255, alpha: 1)
    }

    /// Shrinks the cover to 8x8 and picks the most colorful pixel.
    private static func mostVivid(_ img: CIImage) -> UIColor {
        let scale = 8 / max(img.extent.width, 1)
        let small = img.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        var px = [UInt8](repeating: 0, count: 8 * 8 * 4)
        context.render(small, toBitmap: &px, rowBytes: 32, bounds: CGRect(x: 0, y: 0, width: 8, height: 8),
                       format: .RGBA8, colorSpace: nil)
        var best = UIColor.white, bestScore: CGFloat = -1
        for i in stride(from: 0, to: px.count, by: 4) {
            let c = UIColor(red: CGFloat(px[i]) / 255, green: CGFloat(px[i + 1]) / 255, blue: CGFloat(px[i + 2]) / 255, alpha: 1)
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
            let score = s * (0.4 + b)
            if score > bestScore { bestScore = score; best = c }
        }
        return best
    }

    private static func tone(_ c: UIColor, minBrightness: CGFloat = 0, maxBrightness: CGFloat = 1,
                             minSaturation: CGFloat = 0) -> Color {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return Color(hue: Double(h),
                     saturation: Double(max(s, minSaturation)),
                     brightness: Double(min(max(b, minBrightness), maxBrightness)))
    }
}

/// Square album art that loads itself.
struct ArtworkView: View {
    let track: Track?
    var coverArt: String? = nil
    var size: CGFloat
    var corner: CGFloat = 8

    @State private var image: UIImage?

    private var key: String { track?.artworkKey ?? coverArt ?? "none" }

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
                    .transition(.opacity)
            } else {
                LinearGradient(colors: [Color(white: 0.18), Color(white: 0.10)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.3, weight: .light))
                    .foregroundStyle(.white.opacity(0.25))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .task(id: key) {
            let px = Int(size * UIScreen.main.scale)
            let img: UIImage?
            if let track {
                img = await ArtworkStore.shared.image(for: track, size: px)
            } else if let coverArt {
                img = await ArtworkStore.shared.image(coverArt: coverArt, size: px)
            } else {
                img = nil
            }
            withAnimation(.easeOut(duration: 0.25)) { image = img }
        }
    }
}
