import AppKit
import ImageIO
import SwiftUI

/// The icon.jpg nx_extract saves from the game's control data, or a placeholder before extraction.
struct GameIcon: View {
    let url: URL?
    @State private var loaded: IconThumbnail?

    init(url: URL?) {
        self.url = url
        // a card scrolled back into view has its icon from its first frame
        _loaded = State(initialValue: url.flatMap(IconCache.thumbnail(at:)))
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(.quaternary)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image = loaded?.image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFill()
                } else if url == nil || loaded != nil {
                    Image(systemName: "gamecontroller")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            // with the file's date: a rebuild or newer eShop art replaces the file under the same URL
            .task(id: url.map(IconCache.version(of:))) {
                guard let url else {
                    loaded = nil
                    return
                }
                loaded = await IconCache.loadThumbnail(at: url)
            }
    }
}

/// An icon at the size the library shows it, and the version of the file it came from. A nil image is a file that
/// can't be read.
struct IconThumbnail: Sendable {
    let modified: Date
    let image: CGImage?
}

/// Icons decoded once per file version: the grid redraws on every job update.
@MainActor
enum IconCache {
    struct Version: Hashable {
        let url: URL
        let modified: Date
    }

    /// The widest a card shows an icon, 220 pt, on a 2x display. eShop icons are 1024 px: at full size each one holds
    /// 4 MB and takes several ms to decode, which a row of new cards can't afford on the main thread.
    nonisolated static let thumbnailPixels = 440

    private static var images: [URL: (modified: Date, image: NSImage)] = [:]
    private static var thumbnails: [URL: IconThumbnail] = [:]
    /// The grid's preloading and a card's own load can ask for the same icon at once.
    private static var decoding: [Version: Task<CGImage?, Never>] = [:]

    static func image(at url: URL) -> NSImage? {
        let modified = version(of: url).modified
        if let cached = images[url], cached.modified == modified { return cached.image }
        guard let image = NSImage(contentsOf: url) else { return nil }
        images[url] = (modified, image)
        return image
    }

    static func version(of url: URL) -> Version {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
        return Version(url: url, modified: modified ?? .distantPast)
    }

    /// What was last loaded, without touching the file: it may be an older version until `loadThumbnail` has run.
    static func thumbnail(at url: URL) -> IconThumbnail? { thumbnails[url] }

    /// The current version of an icon, decoded away from the main thread when it isn't cached yet.
    static func loadThumbnail(at url: URL) async -> IconThumbnail {
        let version = version(of: url)
        if let cached = thumbnails[url], cached.modified == version.modified { return cached }
        let task =
            decoding[version]
            ?? Task.detached(priority: .userInitiated) { decodeThumbnail(at: url) }
        decoding[version] = task
        let thumbnail = IconThumbnail(modified: version.modified, image: await task.value)
        decoding[version] = nil
        thumbnails[url] = thumbnail
        return thumbnail
    }

    nonisolated static func decodeThumbnail(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailPixels,
            kCGImageSourceCreateThumbnailWithTransform: true,
            // decoded here, not on the main thread when it's first drawn
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
