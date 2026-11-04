import Foundation
import Security

/// The control API's credential and where clients find it. A new token each start: 32 bytes from the system's random
/// generator, 64 hex characters. It is written only to `endpoint.json` in a folder only this user can open (0700), in
/// a file only this user can read (0600), and is never logged or answered with. It has nothing to do with the iOS
/// app's pairing code: that one is typed on phones on the local network and opens only the iOS app's API.
enum ControlCredential {
    static func newToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "No system randomness for the control API token")
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Whether `given` is `token`, in time that doesn't depend on where they differ.
    static func matches(_ given: String?, _ token: String) -> Bool {
        guard let given else { return false }
        let a = Array(given.utf8)
        let b = Array(token.utf8)
        guard a.count == b.count, !b.isEmpty else { return false }
        var difference: UInt8 = 0
        for index in 0..<a.count { difference |= a[index] ^ b[index] }
        return difference == 0
    }
}

/// `<folder>/endpoint.json` and the `enabled` switch beside it. The folder is NX Play's own
/// (`~/Library/Application Support/NX Play/control-api`); `NXPLAY_CONTROL_DIR` moves it for a test instance.
struct ControlEndpointFile: Sendable {
    static let schema = "nxplay-control-api/1"
    let folder: URL

    var file: URL { folder.appending(path: "endpoint.json") }
    var enabledFile: URL { folder.appending(path: "enabled") }

    static func standard(environment: [String: String] = ProcessInfo.processInfo.environment) -> ControlEndpointFile {
        if let dir = environment["NXPLAY_CONTROL_DIR"], dir.hasPrefix("/") {
            return ControlEndpointFile(folder: URL(filePath: dir, directoryHint: .isDirectory))
        }
        return ControlEndpointFile(folder: AppHome.folder.appending(path: "control-api", directoryHint: .isDirectory))
    }

    enum Failure: Error, LocalizedError {
        case unsafeFolder(String)
        case io(String)
        var errorDescription: String? {
            switch self {
            case .unsafeFolder(let why): "The control API's folder isn't private: \(why)"
            case .io(let why): why
            }
        }
    }

    /// Makes the folder (0700) or checks the one there: a real folder, not a link, owned by this user, then 0700.
    func prepareFolder() throws {
        let path = folder.path
        try FileManager.default.createDirectory(
            at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
        if mkdir(path, 0o700) != 0, errno != EEXIST {
            throw Failure.io("Can't make \(path): \(String(cString: strerror(errno)))")
        }
        var info = stat()
        guard lstat(path, &info) == 0 else { throw Failure.io("Can't read \(path)") }
        guard (info.st_mode & S_IFMT) == S_IFDIR else { throw Failure.unsafeFolder("\(path) isn't a folder") }
        guard info.st_uid == getuid() else { throw Failure.unsafeFolder("\(path) belongs to another user") }
        if (info.st_mode & 0o077) != 0, chmod(path, 0o700) != 0 {
            throw Failure.unsafeFolder("can't make \(path) private")
        }
    }

    /// Writes the descriptor: a new file only this user can read (0600, never through a link), renamed over the old
    /// one, so a reader sees the old file or the whole new one.
    func write(_ descriptor: [String: Any]) throws {
        try prepareFolder()
        let data = ControlJSON.data(descriptor)
        let temp = folder.appending(path: ".endpoint-\(getpid())-\(UUID().uuidString).tmp")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.io("Can't write the control API's endpoint file") }
        var ok = fchmod(fd, 0o600) == 0
        ok =
            ok
            && data.withUnsafeBytes { buffer in
                Darwin.write(fd, buffer.baseAddress, buffer.count) == buffer.count
            }
        ok = ok && fsync(fd) == 0
        close(fd)
        guard ok, rename(temp.path, file.path) == 0 else {
            unlink(temp.path)
            throw Failure.io("Can't write the control API's endpoint file")
        }
    }

    /// Removes the descriptor if it is still this run's (another instance may have written its own since).
    func remove(token: String) {
        guard let data = try? Data(contentsOf: file),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            ControlCredential.matches(json["token"] as? String, token)
        else { return }
        unlink(file.path)
    }

    /// Whether NX Play turns the API on at launch. Off unless asked: `NXPLAY_CONTROL_API=1` (or on/true/yes), the
    /// `--control-api` argument, or the `enabled` file. `NXPLAY_CONTROL_API=0` (or off/false/no) keeps it off
    /// whatever else asks.
    static func isEnabled(environment: [String: String], arguments: [String], enabledFile: URL) -> Bool {
        if let value = environment["NXPLAY_CONTROL_API"]?.lowercased() {
            if ["0", "off", "false", "no"].contains(value) { return false }
            if ["1", "on", "true", "yes"].contains(value) { return true }
        }
        if arguments.contains("--control-api") { return true }
        return FileManager.default.fileExists(atPath: enabledFile.path)
    }

    /// `NXPLAY_CONTROL_PORT`: a fixed port (1024–65535, still on 127.0.0.1 only); 0, any free one, otherwise.
    static func port(environment: [String: String]) -> UInt16 {
        guard let text = environment["NXPLAY_CONTROL_PORT"], let value = Int(text), (1024...65535).contains(value)
        else { return 0 }
        return UInt16(value)
    }
}
