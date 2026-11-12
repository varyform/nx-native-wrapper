import CoreServices
import Foundation

/// Changes under a folder, from FSEvents, as one element each time some arrive (half a second apart at most). It
/// watches `root` and passes on only the changes in `folder` or under it, so a folder that doesn't exist yet is seen
/// when it's made; changes to the `ignoring` files in `folder` are left out. Ends its watch when the stream's consumer
/// stops, as a view's task does when it goes.
enum FolderWatch {
    static func changes(in folder: URL, root: URL, ignoring ignored: Set<String> = []) -> AsyncStream<Void> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            // FSEvents names real paths, /private/var and not /var, which resolvingSymlinksInPath takes off: the
            // root's real path, the folder under it as given (it may not exist yet)
            let base = root.standardizedFileURL.path
            let real = realpath(base, nil).map { pointer in
                defer { free(pointer) }
                return String(cString: pointer)
            } ?? base
            let inner = folder.standardizedFileURL.path
            let watched = inner.hasPrefix(base + "/") ? real + inner.dropFirst(base.count) : inner
            let filter = Filter(
                folder: watched, ignored: Set(ignored.map { watched + "/" + $0 }), yield: { continuation.yield() })
            guard let stream = Stream(root: real, filter: filter) else {
                continuation.finish()
                return
            }
            continuation.onTermination = { _ in stream.stop() }
        }
    }

    private final class Filter: @unchecked Sendable {
        let folder: String
        let ignored: Set<String>
        let yield: @Sendable () -> Void

        init(folder: String, ignored: Set<String>, yield: @escaping @Sendable () -> Void) {
            self.folder = folder
            self.ignored = ignored
            self.yield = yield
        }

        func take(_ paths: [String]) {
            let inside = paths.contains { path in
                let path = path.hasSuffix("/") ? String(path.dropLast()) : path
                // an ignored file, and the temporary file an atomic write of it makes beside it (order.txt.sb-…)
                let ignore = ignored.contains { path == $0 || path.hasPrefix($0 + ".") }
                return (path == folder || path.hasPrefix(folder + "/")) && !ignore
            }
            if inside { yield() }
        }
    }

    /// The FSEvents stream, stopped once: FSEventStreamRef isn't Sendable, and onTermination's closure must be.
    private final class Stream: @unchecked Sendable {
        private let stream: FSEventStreamRef
        private let lock = NSLock()
        private var stopped = false

        init?(root: String, filter: Filter) {
            var context = FSEventStreamContext(
                version: 0, info: Unmanaged.passRetained(filter).toOpaque(), retain: nil,
                release: { info in info.map { Unmanaged<Filter>.fromOpaque($0).release() } },
                copyDescription: nil)
            let callback: FSEventStreamCallback = { _, info, _, paths, _, _ in
                guard let info, let paths = unsafeBitCast(paths, to: NSArray.self) as? [String] else { return }
                Unmanaged<Filter>.fromOpaque(info).takeUnretainedValue().take(paths)
            }
            let flags = kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
            guard
                let stream = FSEventStreamCreate(
                    nil, callback, &context, [root] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                    0.5, FSEventStreamCreateFlags(flags))
            else { return nil }
            self.stream = stream
            FSEventStreamSetDispatchQueue(stream, DispatchQueue(label: "com.varyform.nxplay.folder-watch"))
            FSEventStreamStart(stream)
        }

        func stop() {
            lock.lock()
            defer { lock.unlock() }
            guard !stopped else { return }
            stopped = true
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}
