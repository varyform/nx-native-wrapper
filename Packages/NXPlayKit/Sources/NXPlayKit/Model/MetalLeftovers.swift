import Darwin
import Foundation

/// Metal's compiler state that games leave behind (Free Up Space). nxnative's pipeline archive captures through a
/// Metal serializer, and Metal gives each one a `gpuarchiver-*` folder of its own (its LMDB state and the compiled
/// libraries, about 45 MB) in the user cache folder's `com.apple.gpuarchiver`, and never removes it: a run starts a
/// new one. nxnative leaves them too, as other programs share the parent folder and it can't tell which are its own.
/// After weeks of play they came to 89 GB. Only folders untouched for a day go, and none while a game runs.
enum MetalLeftovers {
    /// `<user cache folder>/com.apple.gpuarchiver`.
    static var folder: URL? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard confstr(_CS_DARWIN_USER_CACHE_DIR, &buffer, buffer.count) > 0 else { return nil }
        let cache = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        return URL(filePath: cache, directoryHint: .isDirectory).appending(
            path: "com.apple.gpuarchiver", directoryHint: .isDirectory)
    }

    /// A folder written in the last day may belong to a program still running, NX Play's or another's.
    static let minimumAge: TimeInterval = 24 * 60 * 60

    /// The `gpuarchiver-*` folders untouched for `minimumAge`: the folder's own date (a file added) and its
    /// `PersistentState` file's (written as pipelines are captured).
    static func finished(in parent: URL, now: Date = .now) -> [URL] {
        GameScanner.children(of: parent).filter { folder in
            guard folder.lastPathComponent.hasPrefix("gpuarchiver-"), GameScanner.isDirectory(folder) else {
                return false
            }
            let dates = [folder, folder.appending(path: "PersistentState")].compactMap {
                (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            }
            return dates.max().map { now.timeIntervalSince($0) >= minimumAge } ?? false
        }
    }

    static func size(in parent: URL, now: Date = .now) -> Int64 {
        finished(in: parent, now: now).reduce(0) { $0 + CleanupScanner.size(of: $1) }
    }

    /// Free Up Space's row for them, listed unmeasured; nil when there are none.
    static func file(in parent: URL?, gameRunning: Bool, now: Date = .now) -> CleanupFile? {
        guard let parent, !finished(in: parent, now: now).isEmpty else { return nil }
        return CleanupFile(
            url: parent, size: 0, measuring: true, role: .metalState,
            blocked: gameRunning || hostRunning() ? "A game is running: wait until it quits." : nil)
    }

    /// The folders finished by now: those that became recent meanwhile stay.
    static func delete(in parent: URL) throws {
        for folder in finished(in: parent) { try FileManager.default.removeItem(at: folder) }
    }

    /// A game nxnative's host runs (`dmhost`), also one started outside NX Play, from a terminal. A game's Mac app
    /// runs under its own name: the age keeps its folders.
    static func hostRunning() -> Bool {
        var pids = [pid_t](repeating: 0, count: 4096)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return false }
        var name = [CChar](repeating: 0, count: 256)
        return pids.prefix(Int(count)).contains { pid in
            proc_name(pid, &name, UInt32(name.count)) > 0
                && name.withUnsafeBufferPointer { String(cString: $0.baseAddress!) } == "dmhost"
        }
    }
}
