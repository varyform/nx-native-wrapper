import Foundation

/// An app on a device whose data container this Mac can reach (installed with a development signature).
public struct DeviceApp: Hashable, Identifiable, Sendable {
    public let bundleID: String
    public let name: String
    public let version: String
    public var id: String { bundleID }
    /// The title ID that ends nxnative's bundle IDs.
    public var titleID: String { String(bundleID.suffix(16)).uppercased() }
}

/// The parts of `xcrun devicectl` the save transfer uses. Paths on the device are inside the app's data container.
public enum DeviceCtl {
    public struct Failure: LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// The copies of a game on a device: nxnative names its bundle IDs after the title ID
    /// (org.nxnative.<title ID>, or with the team in it when installed from NX Play).
    public static func apps(on device: Device, titleID: String) async throws -> [DeviceApp] {
        parseApps(
            try await run(["device", "info", "apps", "--device", device.id]), titleID: titleID)
    }

    /// Every nxnative game on a device: the apps whose bundle IDs end in a title ID (16 hex digits).
    public static func games(on device: Device) async throws -> [DeviceApp] {
        parseApps(try await run(["device", "info", "apps", "--device", device.id]), titleID: nil)
    }

    /// The files of the app's save (Documents/save, the iOS app's DM_SAVE).
    public static func saveFiles(on device: Device, bundleID: String) async throws -> [SaveFile] {
        parseSaveFiles(
            try await run(
                ["device", "info", "files", "--device", device.id] + container(bundleID) + [
                    "--subdirectory", "Documents",
                ]))
    }

    /// The device's save into a folder on this Mac, created first (devicectl copies an empty save as nothing).
    public static func pullSave(from device: Device, bundleID: String, to folder: URL) async throws
    {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = try await run(
            ["device", "copy", "from", "--device", device.id] + container(bundleID)
                + ["--source", "Documents/save", "--destination", folder.path])
    }

    /// A save folder on this Mac onto the device, mirrored: files the Mac's save lacks are removed there.
    public static func pushSave(_ folder: URL, to device: Device, bundleID: String) async throws {
        _ = try await run(
            ["device", "copy", "to", "--device", device.id] + container(bundleID)
                + [
                    "--source", folder.path, "--destination", "Documents/save",
                    "--remove-existing-content", "true",
                ])
    }

    private static func container(_ bundleID: String) -> [String] {
        ["--domain-type", "appDataContainer", "--domain-identifier", bundleID]
    }

    // MARK: - Output

    /// nil `titleID`: any nxnative game.
    static func parseApps(_ json: Data, titleID: String?) -> [DeviceApp] {
        let suffix = titleID?.lowercased()
        return (result(json)?["apps"] as? [[String: Any]] ?? []).compactMap { app in
            guard let bundleID = app["bundleIdentifier"] as? String,
                isGame(bundleID, suffix: suffix),
                app["containerAccessible"] as? Bool != false
            else { return nil }
            return DeviceApp(
                bundleID: bundleID, name: app["name"] as? String ?? bundleID,
                version: app["version"] as? String ?? "")
        }
    }

    /// The game's bundle ID, or with no title ID any that ends in one (16 hex digits).
    private static func isGame(_ bundleID: String, suffix: String?) -> Bool {
        if let suffix { return bundleID.lowercased().hasSuffix(suffix) }
        return bundleID.wholeMatch(of: /.*[^0-9A-Fa-f][0-9A-Fa-f]{16}/) != nil
    }

    /// `info files` lists Documents recursively; the save is what is under save/.
    static func parseSaveFiles(_ json: Data) -> [SaveFile] {
        let dates = ISO8601DateFormatter()
        dates.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return (result(json)?["files"] as? [[String: Any]] ?? []).compactMap { file in
            guard let path = file["relativePath"] as? String, path.hasPrefix("save/"),
                (file["resources"] as? [String: Any])?["isDirectory"] as? Bool == false,
                let metadata = file["metadata"] as? [String: Any]
            else { return nil }
            let modified =
                (metadata["lastModDate"] as? String).flatMap(dates.date(from:)) ?? .distantPast
            return SaveFile(
                path: String(path.dropFirst("save/".count)), size: metadata["size"] as? Int ?? 0,
                modified: modified)
        }
        .sorted { $0.path < $1.path }
    }

    private static func result(_ json: Data) -> [String: Any]? {
        ((try? JSONSerialization.jsonObject(with: json)) as? [String: Any])?["result"]
            as? [String: Any]
    }

    static func errorMessage(_ json: Data?) -> String? {
        guard let json,
            let root = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any],
            let info = (root["error"] as? [String: Any])?["userInfo"] as? [String: Any]
        else { return nil }
        return ["NSLocalizedDescription", "NSLocalizedFailureReason", "NSDebugDescription"].lazy
            .compactMap { (info[$0] as? [String: Any])?["string"] as? String }.first
    }

    /// devicectl with its JSON output; throws its error message when it fails.
    static func run(_ arguments: [String]) async throws -> Data {
        try await Task.detached {
            let output = FileManager.default.temporaryDirectory.appending(
                path: "nxplay-devicectl-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: output) }
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/xcrun")
            process.arguments = ["devicectl"] + arguments + ["--json-output", output.path, "-q"]
            let errors = Pipe()
            process.standardError = errors
            process.standardOutput = FileHandle.nullDevice
            try process.run()
            let stderr = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let json = try? Data(contentsOf: output)
            guard process.terminationStatus == 0 else {
                let text = String(decoding: stderr, as: UTF8.self).split(separator: "\n").first.map(
                    String.init)
                throw Failure(
                    message: errorMessage(json) ?? text
                        ?? "devicectl failed (exit \(process.terminationStatus))")
            }
            return json ?? Data()
        }.value
    }
}
