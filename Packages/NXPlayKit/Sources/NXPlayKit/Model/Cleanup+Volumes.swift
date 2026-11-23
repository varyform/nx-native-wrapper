import Foundation
import Synchronization

/// A volume Free Up Space has files on, for its storage bar: the volume's size and free space, and how much of the
/// used space each kind takes there, as System Settings › Storage draws it.
public struct CleanupVolume: Identifiable, Equatable, Sendable {
    public struct Info: Equatable, Sendable {
        public let id: String
        public let name: String
        public let total: Int64
        public let available: Int64
    }

    public let info: Info
    /// Each kind's size on this volume, in CleanupKind's order, the ones it has none of left out.
    public let kinds: [(kind: CleanupKind, size: Int64)]
    public var id: String { info.id }

    public var used: Int64 { max(0, info.total - info.available) }
    /// Everything else on the volume: the used space the kinds don't account for.
    public var other: Int64 { max(0, used - kinds.reduce(0) { $0 + $1.size }) }

    public static func == (a: CleanupVolume, b: CleanupVolume) -> Bool {
        a.info == b.info && a.kinds.map(\.kind) == b.kinds.map(\.kind) && a.kinds.map(\.size) == b.kinds.map(\.size)
    }
}

extension Cleanup {
    /// The volumes the files are on, and those of `also` (the games folders and the Mac's home, whose bars show before
    /// the scan has found anything): `also`'s in its order, which stays put as sizes come in, then the others with
    /// the most to remove first. `volume` says which volume a file is on; a file it can't place (gone since the scan)
    /// counts on none.
    nonisolated static func volumes(
        of files: [CleanupFile], also: [URL] = [], volume: (URL) -> CleanupVolume.Info? = CleanupVolume.info
    ) -> [CleanupVolume] {
        var infos: [String: CleanupVolume.Info] = [:]
        var sizes: [String: [CleanupKind: Int64]] = [:]
        var order: [String: Int] = [:]
        for url in also {
            guard let info = volume(url) else { continue }
            infos[info.id] = info
            if order[info.id] == nil { order[info.id] = order.count }
        }
        for file in files {
            guard let info = volume(file.url) else { continue }
            infos[info.id] = info
            sizes[info.id, default: [:]][file.kind, default: 0] += file.size
        }
        return infos.values.map { info in
            let bySize = sizes[info.id] ?? [:]
            let kinds = CleanupKind.allCases.compactMap { kind in
                bySize[kind].flatMap { $0 > 0 ? (kind, $0) : nil }
            }
            return CleanupVolume(info: info, kinds: kinds)
        }
        .sorted {
            let a = (order[$0.id] ?? .max, -$0.kinds.reduce(0) { $0 + $1.size }, $0.info.name)
            let b = (order[$1.id] ?? .max, -$1.kinds.reduce(0) { $0 + $1.size }, $1.info.name)
            return a < b
        }
    }
}

extension CleanupVolume {
    /// The volume a file is on, through a linked build folder to the volume it's really on. Which volume each file
    /// is on is remembered: the bars are worked out again each time sizes come in, and a file doesn't move.
    @Sendable static func info(of url: URL) -> Info? {
        if let id = volumeOf.withLock({ $0[url] }) { return info(ofVolume: id) }
        let id = try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.volumeURLKey]).volume?.path
        guard let id else { return nil }
        volumeOf.withLock { $0[url] = id }
        return info(ofVolume: id)
    }

    private static let volumeOf = Mutex<[URL: String]>([:])

    /// A volume's name, size and free space, asked anew: free space changes as builds run and files are deleted.
    private static func info(ofVolume path: String) -> Info? {
        let url = URL(filePath: path, directoryHint: .isDirectory)
        let keys: Set<URLResourceKey> = [
            .volumeURLKey, .volumeLocalizedNameKey, .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey,
        ]
        guard let values = try? url.resourceValues(forKeys: keys),
            let volume = values.volume, let total = values.volumeTotalCapacity
        else { return nil }
        // what System Settings counts as free: purgeable space included
        let available =
            values.volumeAvailableCapacityForImportantUsage ?? values.volumeAvailableCapacity.map(Int64.init) ?? 0
        return Info(
            id: volume.path, name: values.volumeLocalizedName ?? volume.lastPathComponent, total: Int64(total),
            available: available)
    }
}
