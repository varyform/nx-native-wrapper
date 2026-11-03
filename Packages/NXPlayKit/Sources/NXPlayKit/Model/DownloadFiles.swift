import Foundation

/// Where a download's files go, and how they get there safely. Each download streams into its own staging folder in
/// the games folder (`.nxplay-downloads/<id>`, hidden, so the library doesn't see a half-written game, and on the same
/// volume, so publishing is a rename). A file is published only once its size and checksum match the catalog: renamed
/// into the game's folder, never over a file that's already there. Folders are opened without following symbolic
/// links, so a link planted in the games folder can't send a file anywhere else.
enum DownloadFiles {
    static let stagingName = ".nxplay-downloads"

    struct Failure: Error, LocalizedError, Equatable {
        let message: String
        var errorDescription: String? { message }
    }

    /// A folder name for a game inside the games folder: its name with only letters, digits, spaces and a few marks
    /// kept (no dots or slashes), then its title ID, as `Example Game [0100000000010000]`.
    static func folderName(name: String, titleID: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_,'()&+!"))
        let kept = String(
            String.UnicodeScalarView(
                name.unicodeScalars.map { allowed.contains($0) ? $0 : " " }))
        let cleaned = String(kept.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(80))
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? titleID.uppercased() : "\(cleaned) [\(titleID.uppercased())]"
    }

    /// A single plain name: a folder of the games folder, never a path out of it.
    static func isPlainName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.hasPrefix(".")
            && !name.contains("/") && !name.contains("\0") && name.utf8.count <= 255
    }

    /// Whether `filename` is already in the game's folder (as anything, a link too).
    static func exists(root: URL, folder: String, filename: String) -> Bool {
        guard isPlainName(folder), isPlainName(filename) else { return false }
        var info = stat()
        return lstat(root.appending(path: folder).appending(path: filename).path, &info) == 0
    }

    /// A file a download put in a game's folder: which file it is on its volume, and its size then. Renames keep it;
    /// a file copied or saved over it in the meantime is another.
    struct Published: Sendable, Equatable {
        let device: Int64
        let inode: UInt64
        let bytes: Int64
    }

    /// What is at `<root>/<folder>/<filename>`: nil when nothing is, `.other` for a folder, a link or anything else
    /// that isn't a plain file (looked at without following links).
    enum Found: Equatable {
        case file(Published)
        case other
    }

    static func find(root: URL, folder: String, filename: String) -> Found? {
        guard isPlainName(folder), isPlainName(filename) else { return .other }
        var info = stat()
        guard lstat(root.appending(path: folder).appending(path: filename).path, &info) == 0 else {
            return Darwin.errno == ENOENT ? nil : .other
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else { return .other }
        return .file(Published(device: Int64(info.st_dev), inode: UInt64(info.st_ino), bytes: Int64(info.st_size)))
    }

    /// Re-read published content off the main actor, hashed with the checksum's own algorithm; inode/size alone do
    /// not establish integrity.
    @concurrent static func verifyPublished(root: URL, folder: String, filename: String,
                                           identity: Published, bytes: Int64, checksum: Checksum) async throws {
        guard isPlainName(folder), isPlainName(filename) else { throw Failure(message: "Unsafe download path") }
        let rootFD = open(root.path, O_RDONLY | O_DIRECTORY)
        guard rootFD >= 0 else { throw Failure(message: "The games folder is unavailable") }
        defer { close(rootFD) }
        let folderFD = openat(rootFD, folder, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard folderFD >= 0 else { throw Failure(message: "Published folder is unavailable") }
        defer { close(folderFD) }
        let fd = openat(folderFD, filename, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw Failure(message: "Published file is unavailable: \(filename)") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              Published(device: Int64(info.st_dev), inode: UInt64(info.st_ino), bytes: Int64(info.st_size)) == identity,
              Int64(info.st_size) == bytes else { throw Failure(message: "Published file changed: \(filename)") }
        var hash = Checksum.Hasher(checksum.algorithm)
        var count: Int64 = 0
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            try Task.checkCancellation()
            count += Int64(data.count)
            guard count <= bytes else { throw Failure(message: "Published file changed: \(filename)") }
            hash.update(data: data)
        }
        guard count == bytes, hash.finalize() == checksum else {
            throw Failure(message: "Published file no longer matches its \(checksum.algorithm.label): \(filename). Move it aside before Retry.")
        }
    }

    /// Bytes free for new files on the games folder's volume.
    static func freeSpace(_ root: URL) -> Int64? {
        let values = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// One download's staging folder, open while the download runs.
    final class Staging {
        let root: URL
        let id: String
        private let rootFD: Int32
        private let stagingFD: Int32
        private let jobFD: Int32
        private var closed = false

        /// Creates `.nxplay-downloads/<id>` in `root`, with nothing of an earlier attempt in it.
        init(root: URL, id: String) throws {
            guard DownloadFiles.isPlainName(id) else { throw Failure(message: "Bad download id") }
            self.root = root
            self.id = id
            rootFD = open(root.path, O_RDONLY | O_DIRECTORY)
            guard rootFD >= 0 else {
                throw Failure(message: "The games folder \(root.path) isn't there: \(DownloadFiles.errno())")
            }
            do {
                stagingFD = try DownloadFiles.openFolder(stagingName, in: rootFD, create: 0o700)
            } catch {
                close(rootFD)
                throw error
            }
            DownloadFiles.removeTree(id, in: stagingFD)
            do {
                jobFD = try DownloadFiles.openFolder(id, in: stagingFD, create: 0o700)
            } catch {
                close(stagingFD)
                close(rootFD)
                throw error
            }
        }

        deinit { closeAll() }

        private func closeAll() {
            guard !closed else { return }
            closed = true
            close(jobFD)
            close(stagingFD)
            close(rootFD)
        }

        static func partName(_ index: Int) -> String { "\(index).part" }

        /// A new, empty file for the index'th package: never one that's there already, never through a link.
        func create(_ index: Int) throws -> FileHandle {
            let fd = openat(
                jobFD, Self.partName(index), O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
            guard fd >= 0 else {
                throw Failure(message: "Couldn't create the download's file: \(DownloadFiles.errno())")
            }
            return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        }

        /// The size of a finished part, as it is on disk.
        func size(_ index: Int) -> Int64? {
            var info = stat()
            guard fstatat(jobFD, Self.partName(index), &info, AT_SYMLINK_NOFOLLOW) == 0,
                (info.st_mode & S_IFMT) == S_IFREG
            else { return nil }
            return Int64(info.st_size)
        }

        /// Moves the verified part into `<root>/<folder>/<filename>`, creating the game's folder when it's new. Fails
        /// rather than replace a file, or follow a link where the folder should be. Says which file it published.
        @discardableResult
        func publish(_ index: Int, folder: String, filename: String) throws -> Published {
            guard DownloadFiles.isPlainName(folder) else {
                throw Failure(message: "“\(folder)” can't be a folder in the games folder")
            }
            guard DownloadFiles.isPlainName(filename) else {
                throw Failure(message: "“\(filename)” can't be a file name")
            }
            let folderFD = try DownloadFiles.openFolder(folder, in: rootFD, create: 0o755)
            defer { close(folderFD) }
            guard renameatx_np(jobFD, Self.partName(index), folderFD, filename, UInt32(RENAME_EXCL)) == 0
            else {
                if Darwin.errno == EEXIST {
                    throw Failure(
                        message: "\(folder)/\(filename) is already in the games folder: NX Play doesn't replace files")
                }
                throw Failure(message: "Couldn't move \(filename) into \(folder): \(DownloadFiles.errno())")
            }
            var info = stat()
            guard fstatat(folderFD, filename, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw Failure(message: "Couldn't look at \(filename) in \(folder): \(DownloadFiles.errno())")
            }
            return Published(device: Int64(info.st_dev), inode: UInt64(info.st_ino), bytes: Int64(info.st_size))
        }

        /// Deletes the staging folder and whatever is left in it.
        func remove() {
            guard !closed else { return }
            DownloadFiles.removeTree(id, in: stagingFD)
            closeAll()
        }
    }

    /// Clears what earlier runs left in the staging folder (NX Play quit mid-download): nothing there is kept.
    static func removeStaging(in root: URL) {
        let rootFD = open(root.path, O_RDONLY | O_DIRECTORY)
        guard rootFD >= 0 else { return }
        defer { close(rootFD) }
        removeTree(stagingName, in: rootFD)
    }

    /// `name` in the folder `parent`, opened as a folder, created first when it's missing; a link or a file there
    /// is refused.
    fileprivate static func openFolder(_ name: String, in parent: Int32, create mode: mode_t) throws -> Int32 {
        if mkdirat(parent, name, mode) != 0, Darwin.errno != EEXIST {
            throw Failure(message: "Couldn't create the folder \(name): \(errno())")
        }
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            let code = Darwin.errno
            if code == ELOOP || code == ENOTDIR {
                throw Failure(message: "\(name) in the games folder is a link or a file, not a folder")
            }
            throw Failure(message: "Couldn't open the folder \(name): \(errno())")
        }
        return fd
    }

    /// Deletes `name` in `parent` and everything under it, without following links.
    fileprivate static func removeTree(_ name: String, in parent: Int32) {
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 {
            unlinkat(parent, name, 0)  // a file or a link: itself, not what it points to
            return
        }
        if let dir = fdopendir(dup(fd)) {
            var names: [String] = []
            while let entry = readdir(dir) {
                let child = withUnsafeBytes(of: entry.pointee.d_name) {
                    String(decoding: $0.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
                }
                if child != "." && child != ".." { names.append(child) }
            }
            closedir(dir)
            for child in names { removeTree(child, in: fd) }
        }
        close(fd)
        unlinkat(parent, name, AT_REMOVEDIR)
    }

    fileprivate static func errno() -> String { String(cString: strerror(Darwin.errno)) }
}
